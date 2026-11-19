// The client (src/netcode/README.md, Client), generic over the game: the verified and predicted frames, rollback, the
// clock and input delay, snapshots for joiners. Driven by client_step from the host's loop; talks to the host
// application through Hooks (all called from client_step).
package netcode

// Used only inside generic procs: @(require) keeps -vet from calling it unused in a program that never instantiates
// them (a game's tests that don't run the netcode).
@(require) import "core:fmt"
@(require) import "core:log"
@(require) import "core:strings"
@(require) import "core:time"

import usim "unified:sim" // the field Client.sim shadows the package name
import "unified:wire"

// What a client of game G asks the relay for and who it says it is (client_create): written as a literal at the call
// (`client_create(&GAME, {slot = -1, profile = {character = .Tank}}, link, hooks)`).
Client_Config :: struct($G: typeid) {
	using local:   Local_Config(G), // local player 0's: its slot, join tick, name and Profile
	compat:        u64, // build/game id the relay checks (0: sim.compat_of(game))
	// On a link that vouches for no account (LAN, direct UDP): what the relay recognizes this person by when they
	// come back (the same member, in any free slot). All zero: none (a new member every time).
	token:         Token,
	// The most finalized ticks one client_step verifies while it holds more (a joiner's backlog, a long hitch); 0: the
	// prediction cap, so a step that catches up costs what a full-depth rollback costs, which the game's benchmark
	// bounds. The channel, the clock and own inputs are served between the steps.
	catchup_ticks: u32,
	// Attach a sim.Dev to every sim the client makes or restores (debug draws, zones timed on the netcode's clock): a
	// dev UI build, the headless session modes.
	dev:           bool,
}

// Where a client stands (Client.status), reported through Hooks.status.
Status :: enum u8 {
	Idle,
	Connecting,
	Connected, // welcomed and simulating (a late joiner: once its snapshot is restored and checked)
	Failed, // rejected, a protocol error, another protocol version, or the relay never answered
	Disconnected, // left, the session ended, refused, or the connection was lost and could not be opened again
	// The connection to the relay was lost after it worked: the client keeps its sim and asks to come back on a new
	// connection (RECONNECT_US at most), resuming from its own verified tick while the relay still holds the ticks
	// after it, else as a late joiner with a snapshot. Connected again once it is back at the live tick.
	Reconnecting,
	// In the session, the state being replaced: the relay sends a majority player's snapshot to resync it (it diverged,
	// or fell behind the relay's ring). The view holds; the player's inputs still count. Then Connected again.
	Recovering,
}

RECONNECT_US :: 30_000_000 // how long after losing its relay a client keeps asking to come back

// What changed in a step, for the view.
Frame_Info :: struct {
	tick:       u32, // the latest predicted tick (the sim's current tick)
	verified:   u32, // the latest verified tick
	resim_from: u32, // ticks resim_from..tick were computed in this step: their events are new
}

// How a client talks to the host application (src/netcode/README.md, Hooks): every hook is called from client_step, on
// its caller's thread, and gets `user` back.
Hooks :: struct($G: typeid) {
	user:           rawptr,
	// Local player `local`'s input for `tick` (it holds `slot`), sampled when the client's clock reaches it, once per
	// seated local player. `state` is the latest predicted state (nil before the sim exists).
	sample:         proc(
		user: rawptr,
		local, slot: int,
		tick: u32,
		state: ^usim.part(G, usim.GAME_STATE),
	) -> usim.part(G, usim.GAME_INPUT),
	// Optional: local player `local`'s commands for `tick`, called right after its `sample` for every tick the
	// client generates. usim.send_command(out, command) returns false once COMMAND_QUEUE commands wait.
	commands:       proc(
		user: rawptr,
		local, slot: int,
		tick: u32,
		state: ^usim.part(G, usim.GAME_STATE),
		out: ^usim.Command_Out(usim.part(G, usim.GAME_CMD)),
	),
	// Optional: local player `local` was seated (Welcome, Seated) or refused (`why`; Reject of its Join).
	seat:           proc(user: rawptr, local: int, seated: bool, why: Reject_Reason),
	// After a step that computed new predicted ticks: the view reads simulation.state (frame.tick's) and
	// usim.events_at for ticks frame.resim_from..frame.tick.
	frame:          proc(user: rawptr, simulation: ^usim.Sim(G), frame: Frame_Info),
	// Each newly verified tick, in order, with its final inputs and the events it emitted under them.
	verified:       proc(
		user: rawptr,
		simulation: ^usim.Sim(G),
		tick: u32,
		inputs: ^usim.Inputs(G),
		events: []usim.Raw_Event,
	),
	// Each change of the client's status, with why ("" when there is nothing to say).
	status:         proc(user: rawptr, status: Status, detail: string),
	// Optional: the relay found the players' checksums of a tick differ (report.detail is valid during the call).
	desync:         proc(user: rawptr, report: Desync_Report),
	// Optional: the sim stands on the newest verified tick (simulation.tick; simulation.state and world are that
	// tick's), called at most once per step: after the step's verified ticks were stepped (a rollback or a catch-up)
	// and before predicted ticks are stepped again, or when the prediction was right up to exactly that tick. The Godot
	// host reads which views a final tick has there (appear-on-verified).
	verified_state: proc(user: rawptr, simulation: ^usim.Sim(G)),
	// Optional: the client's state was replaced by a snapshot of `tick` (a late joiner's first, or a snapshot that
	// replaced the sim a reconnecting client had): what it predicted before is gone, and `verified` goes on from
	// tick + 1, never naming the ticks it skipped. A resume does not call it (the same sim goes on).
	restored:       proc(user: rawptr, simulation: ^usim.Sim(G), tick: u32),
}

// An own command the client holds until a verified tick carries it.
@(private)
Own_Command :: struct {
	seq:  u32,
	want: u32, // the tick it was sent for (W)
	cmd:  usim.Raw_Command,
}

// Where one of the client's local players stands (client_local).
Local_State :: enum u8 {
	None, // not asked for, refused, or left
	Asked, // in the Hello or a Join, not answered yet
	Seated, // holds a slot from its first tick on
}

// What a local player asks for (client_add_player; local player 0's is Client_Config.local).
Local_Config :: struct($G: typeid) {
	slot:        int, // the slot to ask for; -1: any free one
	join_tick:   u32, // the earliest tick to become present (0: as soon as possible)
	player_name: string, // its display name (sent to the relay, shared with everyone)
	profile:     usim.part(G, usim.GAME_PROFILE), // what it chose before joining: on its join tick, everywhere
}

// A local player as client_local reports it.
Local_Info :: struct {
	state:      Local_State,
	slot:       int, // -1 until seated
	member:     u16,
	first_tick: u32, // the first tick it is present
}

// One of the client's local players (Client.locals): what it asked for, the seat it holds, its own inputs and its
// commands until a verified tick carries them. Each is its own member, joining, leaving and coming back on its own.
@(private)
Local_Seat :: struct($G: typeid) {
	state:      Local_State,
	asked:      bool, // its Hello or Join went out
	want_slot:  int,
	join_tick:  u32,
	name:       Player_Name,
	profile:    usim.part(G, usim.GAME_PROFILE),
	slot:       int,
	member:     u16, // its member id (the relay's): its join record's
	first_tick: u32, // J: the first tick it is present
	own:        [OWN_RING]usim.part(G, usim.GAME_INPUT),
	own_last:   u32,
	own_acked:  u32,
	own_sends:  [OWN_RING]u8, // how many Inputs messages carried each own input (send_inputs)
	own_cmds:   [dynamic]Own_Command, // sent (until acked) and predicted until a verified tick carries them, seq order
	cmd_seq:    u32, // the last seq given
	cmd_acked:  u32, // the relay has every seq up to this one
	cmd_final:  u32, // the newest seq a verified tick carries (the relay places them in seq order, without gaps)
}

// A joiner waiting for our snapshot: of the first checksum tick >= min_tick we verify.
@(private)
Snap_Req :: struct {
	joiner:   int,
	min_tick: u32,
}

#assert(DESYNC_IMAGES <= usim.KEEP_SLOTS) // a kept checksum tick is a sim keep slot

// Finalized ticks a client holds ahead of its verified tick (a joiner: of its snapshot's). A joiner accepts them only
// up to FIN_RING - 64 past its snapshot until it plays, so it must be in within that plus RELAY_RING ticks of the
// snapshot (64 s at 64 Hz) or be refused as too far behind: the time a large world's snapshot may take to arrive.
FIN_RING :: 2048
#assert(CATCHUP_TICKS <= FIN_RING - 64) // a relay never streams ticks the ring would refuse
OWN_RING :: 512
PRED_RING :: 64
// The checksums of verified checksum ticks, until reported: the ticks a client verifies before its reports go out (a
// step's, at most catchup_ticks), and a joiner's snapshot tick's.
CHK_RING :: FIN_RING / CHECKSUM_EVERY
#assert(CHK_RING * CHECKSUM_EVERY >= FIN_RING)
CHECKSUMS_KEPT :: 64 // an endless session's client keeps its last this many checksums (Client.checksums)
// Predicted ticks are saved every 2nd tick (and a checksum tick a snapshot is wanted of): a rollback restores the
// nearest saved tick at or before its target, at most one tick back, which the ring still holds at the prediction cap
// (P - V <= ring - 2). Checksum ticks are multiples of it, so always saved.
@(private)
PREDICTED_SAVE_EVERY :: 2
#assert(CHECKSUM_EVERY % PREDICTED_SAVE_EVERY == 0)

// What a stepped tick was: verified for the first time, re-simulated after a rollback (with final or predicted
// inputs), or newly predicted.
Step_Kind :: enum u8 {
	Verified,
	Resim,
	Predicted,
}

// A client's counters (cumulative: the dev UI takes differences) and its live estimates, copied whole by
// client_stats.
Client_Stats :: struct {
	rollbacks:      int,
	depth_sum:      int, // rollback depths summed (their average: depth_sum / rollbacks)
	depth_max:      int,
	stall_ticks:    int, // clock ticks the prediction cap held the sim back
	resim_ticks:    int,
	delay_changes:  int,
	desyncs:        int, // desync reports from the relay
	reconnects:     int, // times the connection was lost and a new one asked to come back
	resumes:        int, // ... and the relay took our own verified tick (no snapshot)
	resyncs:        int, // times the relay replaced our state (a desync, or fell behind its ring)
	own_replaced:   int, // finalized ticks where the relay replaced our input (it arrived too late)
	steps:          [Step_Kind]int, // ticks stepped, by kind
	step_us:        [Step_Kind]i64, // time spent stepping them (saves included), µs
	// The client_steps that stepped the sim, restored a snapshot (a joiner) or encoded a kept tick (a desync report):
	// each one's whole time, receiving (the restore, the image) included, verifying (rolling back, re-simulating, the
	// checksums, the snapshots joiners wait for, the verified hook), advancing the clock and predicting. What the
	// frame budget is about.
	client_steps:   Durations,
	snapshot_bytes: int, // a joiner: the snapshot it restored
	snapshot_us:    i64, // ... from its Snap_Begin to its last chunk
	last_msg_us:    i64, // when the relay's last message arrived (now_us; 0: none yet)
	slow_changes:   int, // times `slow` changed
	// live, filled by client_stats
	rtt_ms:         f64, // the round trip the clock and input delay use
	ceiling_ms:     f64, // the round trip this game plays smoothly at (round_trip_ceiling_us)
	// The round trip's high end (RTT + 4 × its mean deviation, what the input delay is computed from) is past the
	// ceiling: the client stalls. Judged once SLOW_SAMPLES round trips were measured; cleared after SLOW_CLEAR_US
	// below SLOW_CLEAR of the ceiling. A game that refuses a slow player does it in its own words.
	slow:           bool,
	delay:          u32, // the input delay, ticks
	net:            Channel_Stats,
}

// A client of one session (client_create): its sim's verified and predicted frames, its clock, its own inputs and
// commands, the snapshots it sends joiners, and the roster. Driven by client_step.
Client :: struct($G: typeid) {
	game:           ^G,
	cfg:            Client_Config(G),
	hooks:          Hooks(G),
	tm:             Timing,
	ch:             ^Channel,
	relay:          Peer,
	w:              wire.Writer,
	poll_us:        i64, // how often client_step wants to run between deadlines (a host's own client: never)
	sim:            ^usim.Sim(G), // nil until welcomed (a late joiner: until its snapshot lands)
	status:         Status,
	detail:         string,
	hello_sent:     bool,
	link_index:     int, // the relay's link in the channel (a reconnect opens a new connection on it)
	reconnect_us:   i64, // when the connection was lost (0: not reconnecting)
	rehello:        bool, // a resumed Welcome this client could not take: reconnect without resume after the poll
	resync_tick:    u32, // the relay is sending a snapshot of this tick to replace our state (Resync; 0: none)
	resync_placed:  [LOCAL_MAX]u32, // each local player's newest command that tick holds (Resync)
	// from Welcome
	welcomed:       bool,
	slot:           int, // local player 0's (-1: not seated)
	member:         u16, // local player 0's member id (the relay's): its join record's
	seed:           u64,
	setup:          usim.part(G, usim.GAME_SETUP), // the session's (Welcome)
	ticks:          u32, // session length, 0: endless
	first_tick:     u32, // J: the first tick of the connection's first seat (from its Welcome)
	keep_images:    bool, // Welcome's Keep_Images
	// finalized inputs from the relay
	fin:            [FIN_RING]usim.Inputs(G),
	fin_tick:       [FIN_RING]u32,
	fin_scratch:    usim.Inputs(G), // a finalized tick being decoded
	fin_upto:       u32, // highest contiguous finalized tick held
	// frames
	verified:       u32, // V
	predicted:      u32, // P (the sim's current tick)
	local:          u32, // L (scheduler tick)
	resim_from:     u32,
	pred_inputs:    [PRED_RING]usim.Inputs(G),
	chk:            [CHK_RING]struct {
		tick:  u32,
		value: u64,
	},
	// own players: their inputs and commands
	locals:         [LOCAL_MAX]Local_Seat(G),
	cmd_out:        usim.Command_Out(usim.part(G, usim.GAME_CMD)), // for hooks.commands
	// time sync
	started:        bool,
	offset_us:      f64, // relay time - local time
	have_offset:    bool,
	rtt_us:         f64, // the round trip, averaged over the channel's samples
	rtt_dev_us:     f64, // its mean deviation (jitter)
	rtt_samples:    int, // the channel's samples taken in
	slow:           bool, // Client_Stats.slow
	fast_since_us:  i64, // a slow client's round trip has been below the clearing mark since (0: it isn't)
	delay:          u32, // k: own inputs are sampled for tick local + delay
	delay_eval_us:  i64,
	next_tick_us:   f64,
	last_send_us:   i64,
	// late join
	snap_reqs:      [dynamic]Snap_Req, // joiners waiting for our snapshot
	snap_buf:       [dynamic]u8,
	snap_total:     int,
	snap_tick:      u32,
	snap_begin_us:  i64, // when the snapshot's Snap_Begin came
	checking:       bool, // our restored snapshot waits for the relay's check (Snap_Ok)
	snap_foreign:   bool, // ... and is of another session (load_snapshot): a Snap_Ok for it ends the join
	received_work:  bool, // this step's messages restored a snapshot or encoded a kept tick (client_steps times it)
	// The checksum ticks kept for a desync report (Welcome's Keep_Images), by the sim's keep slot (0: none): a copy
	// of the tick (usim.snapshot_keep), encoded only when the relay asks for it, into image_buf.
	kept_ticks:     [DESYNC_IMAGES]u32,
	image_buf:      [dynamic]u8,
	// end
	done_sent:      bool,
	end_us:         i64, // when End arrived or stop was called (0: not ending)
	leaving:        bool, // client_stop was called
	// results
	// (tick, checksum) of verified ticks divisible by 16, from J on, oldest first: all of a fixed-length session's,
	// the last CHECKSUMS_KEPT of an endless one's.
	checksums:      [dynamic][2]u64,
	stats:          Client_Stats, // the counters (client_stats fills the live fields)
	first_desync:   Desync_Report, // the first desync report (its detail owned by the client)
	// the relay's roster: every member of the session, by member id - 1 (departed ones stay)
	roster:         [dynamic]Roster_Entry,
	roster_changes: u32, // bumped on every roster entry received
}

// The roster entry of member `id` (the relay's id, sim.Player.id; nil: not known yet).
client_member :: proc(client: ^Client($G), id: u16) -> ^Roster_Entry {
	index := int(id) - 1
	if index < 0 || index >= len(client.roster) || client.roster[index].member != id {
		return nil
	}
	return &client.roster[index]
}

// Creates a client talking to a relay over `link` (the client owns it). Nothing is sent until the
// first client_step.
client_create :: proc(game: ^$G, cfg: Client_Config(G), link: Link, hooks: Hooks(G)) -> ^Client(G) {
	Input :: usim.part(G, usim.GAME_INPUT)
	usim.check_wire(Input)
	client := new(Client(G))
	client.game = game
	client.cfg = cfg
	if client.cfg.compat == 0 {
		client.cfg.compat = usim.compat_of(game)
	}
	client.poll_us = POLL_US
	client.hooks = hooks
	client.tm = timing_of(game.tick_hz, game.input_delay_min_ticks)
	client.ch = channel_make()
	client.link_index = channel_add_link(client.ch, link)
	client.relay = channel_peer(client.ch, client.link_index, 0)
	client.w = wire.writer_make(MAX_DATAGRAM)
	for &seat in client.locals {
		seat.slot = -1
		reserve(&seat.own_cmds, COMMAND_QUEUE) // no growing on the session thread
	}
	client.delay = client.tm.min_delay
	client.slot = -1
	client_add_player(client, 0, cfg.local)
	return client
}

// Adds local player `local` (1 ..< LOCAL_MAX; 0 is the Client_Config's): before the first step it goes in the Hello
// (all of the Hello's seats are seated or none), later in a Join once the client is welcomed: it gets a join tick as a
// late joiner's and needs no snapshot. Hooks.seat says how it went. False when `local` is out of range or in use.
client_add_player :: proc(client: ^Client($G), local: int, cfg: Local_Config(G)) -> bool {
	if local < 0 || local >= LOCAL_MAX || client.locals[local].state != .None || client.leaving {
		return false
	}
	seat := &client.locals[local]
	commands := seat.own_cmds
	clear(&commands)
	seat^ = {
		state     = .Asked,
		want_slot = cfg.slot,
		join_tick = cfg.join_tick,
		name      = text_of(NAME_MAX, cfg.player_name),
		profile   = cfg.profile,
		slot      = -1,
		own_cmds  = commands,
	}
	return true
}

// Local player `local` leaves (Leave): its seat empties at once, the slot is absent from the next finalized tick; the
// client and its other local players play on. Removing the last one is client_stop.
client_remove_player :: proc(client: ^Client($G), local: int, now: i64) {
	if local < 0 || local >= LOCAL_MAX || client.locals[local].state == .None {
		return
	}
	others := 0
	for &seat, other in client.locals do others += int(other != local && seat.state != .None)
	if others == 0 {
		client_stop(client, now)
		return
	}
	seat := &client.locals[local]
	if seat.asked && client.hello_sent {
		writer := msg_begin(&client.w, .Leave)
		wire.w_u8(writer, u8(local))
		csend(client, writer, .Reliable, now)
	}
	seat.state = .None
	seat.asked = false
	clear(&seat.own_cmds)
	if local == 0 do client.slot = -1
}

// Where local player `local` stands.
client_local :: proc(client: ^Client($G), local: int) -> Local_Info {
	if local < 0 || local >= LOCAL_MAX do return {slot = -1}
	seat := &client.locals[local]
	return {state = seat.state, slot = seat.slot, member = seat.member, first_tick = seat.first_tick}
}

// Frees the client, its sim and its channel (closing the link it owns). Call client_stop and step until
// client_finished first, so the relay hears the Leave.
client_destroy :: proc(client: ^Client($G)) {
	channel_destroy(client.ch)
	if client.sim != nil {
		usim.destroy(client.sim)
	}
	delete(client.w.buf)
	delete(client.snap_buf)
	delete(client.snap_reqs)
	delete(client.checksums)
	for &seat in client.locals do delete(seat.own_cmds)
	delete(client.cmd_out.list)
	delete(client.image_buf)
	delete(client.first_desync.detail)
	delete(client.roster)
	free(client)
}

// Leaves the session: the relay frees the player at once. Keep stepping until client_finished (at most 2 s, so the
// Leave gets through). A client stopped before its first step never told the relay anything: it sends nothing and is
// finished at once. From the stop on the client finishes Disconnected, "left", whatever ends it (a refusal on its way
// included).
client_stop :: proc(client: ^Client($G), now: i64) {
	if client_finished(client) || client.end_us != 0 {
		return
	}
	client.leaving = true
	client.detail = "left"
	if !client.hello_sent {
		set_status(client, .Disconnected, "left")
		return
	}
	writer := msg_begin(&client.w, .Leave)
	wire.w_u8(writer, ALL_LOCALS)
	csend(client, writer, .Reliable, now)
	client.end_us = now
}

// Whether the client is done: it left, the session ended, the connection was lost, or it failed. The loop stepping
// it stops on it.
client_finished :: proc(client: ^Client($G)) -> bool {
	return client.status == .Disconnected || client.status == .Failed
}

// The latest predicted state (nil before the sim exists).
@(private)
client_state :: proc(client: ^Client($G)) -> ^usim.part(G, usim.GAME_STATE) {
	return &client.sim.state if client.sim != nil else nil
}

// The inputs of `tick`: the finalized ones once the relay finalized it (a verified tick's), else the predicted ones
// while it is predicted; nil for a tick the client doesn't hold (not reached yet, or older than its rings).
client_inputs :: proc(client: ^Client($G), tick: u32) -> ^usim.Inputs(G) {
	if tick != 0 && tick <= client.fin_upto {
		return fin_have(client, tick) ? &client.fin[tick % FIN_RING] : nil
	}
	if tick > client.verified && tick <= client.predicted && tick - client.verified <= PRED_RING {
		return &client.pred_inputs[tick % PRED_RING]
	}
	return nil
}

// The client's own checksum of a checksum tick (every CHECKSUM_EVERY) it stepped, final once the tick is verified
// (what it reports to the relay); false for another tick or one the ring no longer keeps.
client_checksum :: proc(client: ^Client($G), tick: u32) -> (value: u64, ok: bool) {
	entry := client.chk[(tick / CHECKSUM_EVERY) % CHK_RING]
	return entry.value, tick != 0 && tick % CHECKSUM_EVERY == 0 && entry.tick == tick
}

// The client's counters and live estimates (round trip, input delay, the channel's bytes and datagrams).
client_stats :: proc(client: ^Client($G)) -> Client_Stats {
	stats := client.stats
	stats.rtt_ms = client.rtt_us / 1000
	stats.ceiling_ms = round_trip_ceiling_us(client.tm) / 1000
	stats.slow = client.slow
	stats.delay = client.delay
	stats.net = client.ch.stats
	return stats
}

@(private)
set_status :: proc(client: ^Client($G), status: Status, detail: string) {
	status, detail := status, detail
	if client.leaving && (status == .Failed || status == .Disconnected) {
		// The player left first: no error for a join they cancelled (a Reject, another build, a lost connection).
		status, detail = .Disconnected, "left"
	}
	if client.status == status {
		return
	}
	client.status = status
	client.detail = detail
	if status == .Failed || status == .Disconnected {
		log.infof("%v (%s)", status, detail)
	}
	if client.hooks.status != nil {
		client.hooks.status(client.hooks.user, status, detail)
	}
}

@(private)
csend :: proc(client: ^Client($G), writer: ^wire.Writer, delivery: Delivery, now: i64) {
	channel_send(client.ch, client.relay, writer.buf[:], delivery, now)
}

@(private)
on_welcome :: proc(client: ^Client($G), reader: ^wire.Reader) {
	Setup :: usim.part(G, usim.GAME_SETUP)
	PLAYERS :: usim.part(G, usim.GAME_PLAYERS)
	welcome, ok := read_welcome(reader)
	if !ok || client.welcomed {
		return
	}
	first: u32 = max(u32)
	for &grant in welcome.seats[:welcome.seat_count] {
		if grant.local >= LOCAL_MAX ||
		   client.locals[grant.local].state != .Asked ||
		   int(grant.slot) >= PLAYERS ||
		   grant.member == NO_MEMBER ||
		   grant.first_tick == 0 {
			return
		}
		want := client.locals[grant.local].want_slot
		if want >= 0 && int(grant.slot) != want {
			return
		}
		first = min(first, grant.first_tick)
	}
	if welcome.tick_hz != client.game.tick_hz {
		set_status(client, .Failed, "the relay runs another tick rate")
		return
	}
	// The session's Setup: a start client builds tick 0 with it (a joiner's snapshot carries it). One that does not
	// read on this build would play another session than the host's: refused, never zeroed.
	if len(welcome.setup) != size_of(Setup) {
		set_status(client, .Failed, "the host's setup does not read on this build")
		return
	}
	copy(usim.bytes_of(&client.setup), welcome.setup)
	if usim.setup_violation(client.game, &client.setup) != "" {
		set_status(client, .Failed, "the host's setup does not read on this build")
		return
	}
	if client.sim != nil {
		// Back after a lost connection. Resumed: the relay streams the finalized ticks after our verified tick, which
		// the sim goes back to (its predictions were of a session it was absent from). Else a snapshot comes, as for
		// any joiner: the old sim and what it held go.
		// The verified tick holds from the Hello to the Welcome (advance_verified), so a resume names it; one this
		// client still cannot take (another seed, the state no longer held) gets no snapshot from a relay that resumed
		// it: the client says Hello again on a new connection, without the resume pair.
		resumed :=
			welcome.resume_from != 0 &&
			welcome.resume_from == client.verified &&
			welcome.seed == client.seed &&
			restore_to(client, client.verified)
		if resumed {
			client.predicted = client.verified
			client.stats.resumes += 1
		} else {
			usim.destroy(client.sim)
			client.sim = nil
			client.kept_ticks = {}
			client.verified, client.predicted = 0, 0
			client.fin_tick = {}
			client.fin_upto = 0
			client.snap_tick = 0
			if welcome.resume_from != 0 {
				client.rehello = true
				return
			}
		}
	}
	client.welcomed = true
	client.seed = welcome.seed
	client.ticks = welcome.ticks
	client.first_tick = first
	client.keep_images = .Keep_Images in welcome.flags
	for &grant in welcome.seats[:welcome.seat_count] {
		seat_granted(client, grant)
	}
	// No growing on the session thread.
	reserve(&client.checksums, welcome.ticks != 0 ? int(welcome.ticks / CHECKSUM_EVERY) + 1 : CHECKSUMS_KEPT)
	if .Start in welcome.flags {
		client.sim = usim.create(client.game, welcome.seed, client.setup)
		if client.cfg.dev do usim.dev_attach(client.sim, zone_clock)
		if !client.leaving {
			set_status(client, .Connected, "") // a client that left before its Welcome stays leaving ("left")
		}
	}
}

// A local player's seat granted (Welcome, Seated): present from its first tick on, its own inputs from there, or
// from after the ticks already final when the grant arrives late (those inputs were replaced, as for a late Welcome).
@(private)
seat_granted :: proc(client: ^Client($G), grant: Seat_Grant) {
	seat := &client.locals[grant.local]
	seat.state = .Seated
	seat.slot = int(grant.slot)
	seat.member = grant.member
	seat.first_tick = grant.first_tick
	seat.own_last = max(grant.first_tick - 1, client.fin_upto, client.verified)
	seat.own_acked = seat.own_last
	if grant.local == 0 {
		client.slot = seat.slot
		client.member = seat.member
	}
	if client.hooks.seat != nil {
		client.hooks.seat(client.hooks.user, int(grant.local), true, nil)
	}
}

@(private)
fin_have :: #force_inline proc(client: ^Client($G), tick: u32) -> bool {
	return client.fin_tick[tick % FIN_RING] == tick
}

// The base the finalized ring is anchored to: ticks beyond base + FIN_RING are not accepted yet.
@(private)
fin_base :: proc(client: ^Client($G)) -> u32 {
	if client.resync_tick != 0 do return client.resync_tick // its stream starts over there
	return client.sim != nil ? client.verified : client.snap_tick
}

SLOW_SAMPLES :: 8 // round-trip samples before a client judges its link slow (about 8 ticks after its Hello's ack)
SLOW_CLEAR :: 0.9 // a slow link is fast again below this much of the ceiling ...
SLOW_CLEAR_US :: 2_000_000 // ... for this long (the mark and the wait keep it from flapping at the ceiling)

// Takes the channel's new round-trip sample, if there is one, into the average and its deviation, and judges whether
// the link is past the game's round-trip ceiling (Client_Stats.slow).
@(private)
take_rtt :: proc(client: ^Client($G), now: i64) {
	sample, samples := channel_rtt(client.ch, client.relay)
	if samples == client.rtt_samples {
		return
	}
	if client.rtt_samples == 0 {
		client.rtt_us = sample
	} else {
		client.rtt_dev_us += (abs(sample - client.rtt_us) - client.rtt_dev_us) * 0.1
		client.rtt_us += (sample - client.rtt_us) * 0.1
	}
	client.rtt_samples = samples
	high := client.rtt_us + 4 * client.rtt_dev_us
	ceiling := round_trip_ceiling_us(client.tm)
	slow := client.slow
	if samples >= SLOW_SAMPLES && high > ceiling {
		slow = true
		client.fast_since_us = 0
	} else if client.slow && high < SLOW_CLEAR * ceiling {
		if client.fast_since_us == 0 {
			client.fast_since_us = now
		} else if now - client.fast_since_us >= SLOW_CLEAR_US {
			slow = false
		}
	} else {
		client.fast_since_us = 0
	}
	if slow != client.slow {
		client.slow = slow
		client.fast_since_us = 0
		client.stats.slow_changes += 1
		log.infof(
			"link %s: round trip %.0f ms (high end %.0f), ceiling %.0f",
			slow ? "slow" : "fast again",
			client.rtt_us / 1000,
			high / 1000,
			ceiling / 1000,
		)
	}
}

@(private)
on_finalized :: proc(client: ^Client($G), reader: ^wire.Reader, now: i64) {
	relay_time := r_i64(reader)
	first := wire.r_u32(reader)
	count := u32(wire.r_u8(reader))
	seats := int(wire.r_u8(reader))
	if !reader.ok || !client.welcomed || seats > LOCAL_MAX {
		return
	}
	for _ in 0 ..< seats {
		local := wire.r_u8(reader)
		input_ack := wire.r_u32(reader)
		command_ack := wire.r_u32(reader)
		if !reader.ok do return
		if local >= LOCAL_MAX || client.locals[local].state != .Seated do continue
		seat := &client.locals[local]
		seat.cmd_acked = max(seat.cmd_acked, min(command_ack, seat.cmd_seq))
		seat.own_acked = max(seat.own_acked, min(input_ack, seat.own_last))
	}
	// The channel measured the round trip from the Hello's ack on, so the first Finalized already times the clock
	// (a late joiner's inputs for its join tick reach the relay in time).
	take_rtt(client, now)
	if client.rtt_samples > 0 {
		offset := f64(relay_time) + client.rtt_us / 2 - f64(now)
		if !client.have_offset {
			client.offset_us = offset
			client.have_offset = true
		} else if !client.started && offset > client.offset_us && offset - client.offset_us < DISCONNECT_US {
			// Until the clock starts, the fastest Finalized's: one that came late would start the clock late, and the
			// first inputs with it.
			client.offset_us = offset
		} else if abs(offset - client.offset_us) < DISCONNECT_US {
			client.offset_us += (offset - client.offset_us) * 0.05
		} // else not the relay's clock (a mangled time): taken, it would throw the local clock hours off
	}
	limit := fin_base(client) + FIN_RING - 64
	tick_inputs := &client.fin_scratch
	tick_inputs^ = {} // each tick is read as its changes from the one before; the first's from the empty tick
	for k in 0 ..< count {
		tick := first + k
		if !window_read_tick(reader, tick_inputs) {
			break // malformed: the ticks after it can't be found
		}
		// Ticks at or below fin_upto are held or consumed already: a stale datagram must not
		// overwrite the ring slot a newer tick shares with them.
		if tick <= client.fin_upto ||
		   tick > limit ||
		   (client.ticks != 0 && tick > client.ticks) ||
		   fin_have(client, tick) {
			continue
		}
		client.fin[tick % FIN_RING] = tick_inputs^
		client.fin_tick[tick % FIN_RING] = tick
	}
	for fin_have(client, client.fin_upto + 1) {
		client.fin_upto += 1
	}
}

@(private)
on_snap_begin :: proc(client: ^Client($G), reader: ^wire.Reader, now: i64) {
	_ = wire.r_u8(reader)
	tick := wire.r_u32(reader)
	total := int(wire.r_u32(reader))
	if !reader.ok || !client.welcomed || total == 0 || tick == 0 || tick < client.first_tick - 1 {
		return
	}
	if client.sim != nil {
		if !client.checking {
			return
		}
		// Our snapshot failed the relay's check: this one, from another player, replaces it.
		usim.destroy(client.sim)
		client.sim = nil
		client.kept_ticks = {} // they were the old sim's
		client.checking = false
		client.snap_foreign = false
		client.verified, client.predicted = 0, 0
	}
	// The relay streams finalized ticks (again) from the snapshot tick on. Those an earlier snapshot's stream left in
	// the ring are the same facts and stay: the relay forwards no snapshot older than the one before (an ack the
	// relay gets after this Snap_Begin may name them). An older one, from no honest relay, starts the ring over (a
	// held tick past it would leave a gap).
	if tick < client.snap_tick {
		client.fin_tick = {}
	}
	client.snap_tick = tick
	client.snap_total = total
	client.snap_begin_us = now
	clear(&client.snap_buf)
	client.fin_upto = client.snap_tick - 1
	for fin_have(client, client.fin_upto + 1) {
		client.fin_upto += 1
	}
}

@(private)
on_desync :: proc(client: ^Client($G), reader: ^wire.Reader) {
	report := Desync_Report {
		tick     = wire.r_u32(reader),
		diverged = transmute(usim.Slots)wire.r_u32(reader),
	}
	report.detail = string(wire.r_bytes(reader, int(wire.r_u16(reader))))
	if !reader.ok {
		return
	}
	client.stats.desyncs += 1
	if client.stats.desyncs == 1 {
		client.first_desync = report
		client.first_desync.detail = strings.clone(report.detail)
	}
	log.warnf(
		"desync at tick %d: slots %v differ%s%s",
		report.tick,
		report.diverged,
		report.detail != "" ? ": " : "",
		report.detail,
	)
	if client.hooks.desync != nil {
		client.hooks.desync(client.hooks.user, report)
	}
}

@(private)
handle_client_msg :: proc(client: ^Client($G), data: []u8, now: i64) {
	client.stats.last_msg_us = now
	reader := wire.reader_make(data)
	#partial switch Msg(wire.r_u8(&reader)) {
	case .Welcome:
		on_welcome(client, &reader)
	case .Reject:
		why := Reject_Reason(wire.r_u8(&reader))
		local := wire.r_u8(&reader)
		if !reader.ok do return
		if local < LOCAL_MAX {
			// One local player's Join refused: the others play on.
			seat := &client.locals[local]
			if seat.state == .Asked {
				seat.state = .None
				seat.asked = false
				if client.hooks.seat != nil do client.hooks.seat(client.hooks.user, int(local), false, why)
			}
			return
		}
		detail := "rejected"
		#partial switch why {
		case .Full:
			detail = "the session is full"
		case .Slot_Taken:
			detail = "that slot is taken"
		case .Incompatible:
			detail = "a different game build or level"
		case .Not_Started:
			detail = "the session has not started"
		case .No_Snapshot:
			detail = "no player can send this player a snapshot"
		case .Bad_Snapshot:
			detail = "the snapshot differed from the other players' and nobody else could send one"
		case .Too_Far_Behind:
			detail = "fell too far behind the session"
		case .Closed:
			detail = "the session takes no new players"
		case .Newer_Connection:
			detail = "this player is in the session on a newer connection"
		case .Desynced:
			detail = "diverged from the other players and could not be resynced"
		}
		set_status(client, why == .Too_Far_Behind || why == .Desynced ? .Disconnected : .Failed, detail)
	case .Finalized:
		on_finalized(client, &reader, now)
	case .Seated:
		grant: Seat_Grant
		grant.local = wire.r_u8(&reader)
		grant.slot = wire.r_u8(&reader)
		grant.member = wire.r_u16(&reader)
		grant.first_tick = wire.r_u32(&reader)
		if reader.ok &&
		   client.welcomed &&
		   grant.local < LOCAL_MAX &&
		   client.locals[grant.local].state == .Asked &&
		   int(grant.slot) < usim.part(G, usim.GAME_PLAYERS) &&
		   grant.member != NO_MEMBER {
			// A Seated that comes after the finalized ticks past its join tick (a resend after an outage) still
			// seats the player: its first inputs are already final, replaced, as every peer agrees (seat_granted).
			seat_granted(client, grant)
		}
	case .Snap_Request:
		target := wire.r_u8(&reader)
		tick := wire.r_u32(&reader)
		if !reader.ok {
			return
		}
		if target == RELAY_TARGET {
			send_image(client, tick, now)
		} else {
			// One request per joiner's slot: the relay asks a provider again only for a new occupant (the one it
			// asked before left), so a newer request replaces the one it holds.
			known := false
			for &request in client.snap_reqs {
				if request.joiner == int(target) {
					request.min_tick = tick
					known = true
				}
			}
			if !known do append(&client.snap_reqs, Snap_Req{int(target), tick})
		}
	case .Snap_Begin:
		on_snap_begin(client, &reader, now)
	case .Snap_Chunk:
		_ = wire.r_u8(&reader)
		offset := int(wire.r_u32(&reader))
		bytes := reader.data[reader.pos:]
		if !reader.ok ||
		   (client.sim != nil && client.resync_tick == 0) ||
		   client.snap_total == 0 ||
		   offset != len(client.snap_buf) ||
		   len(bytes) > client.snap_total - offset {
			return
		}
		append(&client.snap_buf, ..bytes)
		if len(client.snap_buf) == client.snap_total {
			if client.resync_tick != 0 {
				load_resync(client, now)
			} else {
				load_snapshot(client, now)
			}
		}
	case .Resync:
		tick := wire.r_u32(&reader)
		total := int(wire.r_u32(&reader))
		placed: [LOCAL_MAX]u32 // a local player the relay names not: none of its commands is in the tick
		seats := int(wire.r_u8(&reader))
		for _ in 0 ..< seats {
			local := wire.r_u8(&reader)
			seq := wire.r_u32(&reader)
			if local < LOCAL_MAX do placed[local] = seq
		}
		if !reader.ok || client.sim == nil || client.checking || !client.welcomed || total == 0 || tick == 0 {
			return
		}
		// Frozen until the snapshot is in and checked: nothing verified or predicted, the inputs still sent.
		client.checking = true
		client.resync_tick = tick
		client.resync_placed = placed
		client.snap_total = total
		client.snap_begin_us = now
		clear(&client.snap_buf)
		if !client.leaving {
			set_status(client, .Recovering, "resyncing")
		}
	case .Snap_Ok:
		tick := wire.r_u32(&reader)
		if reader.ok && client.checking && client.sim != nil && tick == client.sim.tick {
			if client.snap_foreign {
				set_status(client, .Failed, "the only snapshot for this player was of another session")
				return
			}
			client.checking = false
			client.reconnect_us = 0
			if !client.leaving {
				set_status(client, .Connected, "")
			}
		}
	case .Desync:
		on_desync(client, &reader)
	case .Roster:
		entry := r_roster_entry(&reader)
		if reader.ok && entry.member != NO_MEMBER {
			for len(client.roster) < int(entry.member) {
				append(&client.roster, Roster_Entry{})
			}
			client.roster[entry.member - 1] = entry
			client.roster_changes += 1
		}
	case .End:
		if client.end_us == 0 {
			client.end_us = now
			client.detail = "session ended"
		}
	}
}

// Restores the received snapshot and sends its checksum: the relay compares it with the other players' checksum of
// that tick (a checksum tick) and says Snap_Ok, or sends a snapshot from someone else. Until then the sim waits. A
// snapshot of another session (its seed or Setup unlike the Welcome's, which the checksum does not cover: a hostile
// provider) is answered with a checksum no honest restore gives, so the relay asks another player; if the relay takes
// it unchecked (nobody else reported the tick), its Snap_Ok ends the join.
@(private)
load_snapshot :: proc(client: ^Client($G), now: i64) {
	client.received_work = true
	sim, err := usim.from_snapshot(client.game, client.snap_buf[:])
	client.snap_total = 0
	if err != .None || sim.tick != client.snap_tick {
		if sim != nil {
			usim.destroy(sim)
		}
		set_status(client, .Failed, fmt.tprintf("received snapshot does not restore: %v", err))
		return
	}
	client.sim = sim
	if client.cfg.dev do usim.dev_attach(client.sim, zone_clock)
	client.stats.snapshot_bytes = len(client.snap_buf)
	client.stats.snapshot_us = now - client.snap_begin_us
	client.verified = client.sim.tick
	client.predicted = client.verified
	for &seat in client.locals {
		if seat.state != .Seated do continue
		seat.own_last = max(seat.own_last, client.verified)
		seat.own_acked = max(seat.own_acked, client.verified) // finalized: nothing of them to send
	}
	client.checking = true
	client.snap_foreign =
		client.sim.seed != client.seed ||
		string(usim.bytes_of(&client.sim.setup)) != string(usim.bytes_of(&client.setup))
	tick := client.sim.tick
	value := usim.checksum(client.sim)
	if client.snap_foreign {
		log.warnf("the snapshot of tick %d is of another session (seed or Setup): refused", tick)
		value = ~value
	}
	client.chk[(tick / CHECKSUM_EVERY) % CHK_RING] = {tick, value}
	writer := msg_begin(&client.w, .Checksum)
	wire.w_u32(writer, tick)
	wire.w_u64(writer, value)
	csend(client, writer, .Reliable, now)
	log.infof("restored snapshot of tick %d (%d bytes)", tick, len(client.snap_buf))
	if client.hooks.restored != nil {
		client.hooks.restored(client.hooks.user, client.sim, tick)
	}
	delete(client.snap_buf) // a snapshot's size, needed again only if this one fails the check
	client.snap_buf = nil
}

// The snapshot the relay resyncs us from is complete (Resync): our state is replaced by it, and what it restores to is
// checked like a joiner's (Snap_Ok). Our commands up to the one the tick holds are final in it; the finalized ticks
// after it are streamed again (those the ring holds already stay).
@(private)
load_resync :: proc(client: ^Client($G), now: i64) {
	client.received_work = true
	base := client.resync_tick
	client.resync_tick = 0
	client.snap_total = 0
	sim, err := usim.from_snapshot(client.game, client.snap_buf[:])
	if err != .None || sim.tick != base {
		if sim != nil {
			usim.destroy(sim)
		}
		set_status(client, .Failed, fmt.tprintf("the resync snapshot does not restore: %v", err))
		return
	}
	for &seat, local in client.locals {
		k := 0
		for k < len(seat.own_cmds) && seat.own_cmds[k].seq <= client.resync_placed[local] {
			k += 1
		}
		remove_range(&seat.own_cmds, 0, k)
		seat.cmd_final = client.resync_placed[local] // the ticks after the base are verified again, counting on from it
		if seat.state != .Seated do continue
		seat.own_last = max(seat.own_last, base)
		seat.own_acked = max(seat.own_acked, base) // finalized: nothing of them to send
	}
	usim.destroy(client.sim)
	client.sim = sim
	if client.cfg.dev do usim.dev_attach(client.sim, zone_clock)
	client.kept_ticks = {} // they were the old sim's
	client.verified, client.predicted = base, base
	client.fin_upto = base
	for fin_have(client, client.fin_upto + 1) {
		client.fin_upto += 1
	}
	for len(client.checksums) > 0 && client.checksums[len(client.checksums) - 1][0] >= u64(base) {
		pop(&client.checksums) // the old state's
	}
	value := usim.checksum(client.sim)
	client.chk[(base / CHECKSUM_EVERY) % CHK_RING] = {base, value}
	writer := msg_begin(&client.w, .Checksum)
	wire.w_u32(writer, base)
	wire.w_u64(writer, value)
	csend(client, writer, .Reliable, now)
	client.stats.resyncs += 1
	log.infof("resynced from the snapshot of tick %d (%d bytes)", base, len(client.snap_buf))
	delete(client.snap_buf)
	client.snap_buf = nil
	if client.hooks.restored != nil {
		client.hooks.restored(client.hooks.user, client.sim, base)
	}
}

// Inputs for predicting `tick`: own input and commands, the others' latest finalized input repeated, or the game's
// guess from it (sim.Game.predict_input); their commands are unknown until finalized: none.
@(private)
predicted_inputs :: proc(client: ^Client($G), tick: u32, out: ^usim.Inputs(G)) {
	out^ = {}
	if client.fin_upto >= 1 && fin_have(client, client.fin_upto) {
		last := &client.fin[client.fin_upto % FIN_RING]
		out.present = last.present
		out.input = last.input
		if predict := client.game.predict_input; predict != nil && tick > client.fin_upto {
			for slot in last.present {
				out.input[slot] = predict(last.input[slot], tick - client.fin_upto) // our own is written over below
			}
		}
	}
	// Own commands where the relay will put them if they reach it in time: each in the tick it was sent for, or the
	// first tick not finalized yet when that one is (a late command moves on), in order, at most COMMANDS_PER_SLOT per
	// tick. A wrong guess is an ordinary misprediction. Commands go in slot order (sim.add_command keeps it).
	for slot in 0 ..< usim.part(G, usim.GAME_PLAYERS) {
		for &seat in client.locals {
			if seat.state != .Seated || seat.slot != slot || tick < seat.first_tick do continue
			out.present += {slot}
			out.input[slot] = seat.own[min(tick, seat.own_last) % OWN_RING]
			if tick == seat.first_tick {
				out.joins[slot] = seat.member // its join record and Profile, as the relay will write them
				out.profiles[slot] = seat.profile
			}
			at, in_tick: u32 = 0, 0
			for &own_command in seat.own_cmds {
				lands_at := max(own_command.want, client.fin_upto + 1, at)
				if lands_at == at && in_tick == usim.COMMANDS_PER_SLOT {
					lands_at += 1
				}
				if lands_at != at {
					at, in_tick = lands_at, 0
				}
				in_tick += 1
				if lands_at > tick {
					break
				}
				if lands_at == tick {
					usim.add_command(out, own_command.cmd)
				}
			}
		}
	}
}

// A verified tick carries the own commands the relay put in it: they are no longer predicted. Dropped by seq, not by
// count: after a resync the ticks past its base are verified a second time, and their commands left own_cmds the
// first time.
@(private)
drop_verified_commands :: proc(client: ^Client($G), tick: u32) {
	for &seat in client.locals {
		if seat.state != .Seated || tick < seat.first_tick do continue
		seat.cmd_final += u32(len(usim.slot_commands(&client.fin[tick % FIN_RING], seat.slot)))
		k := 0
		for k < len(seat.own_cmds) && seat.own_cmds[k].seq <= seat.cmd_final do k += 1
		remove_range(&seat.own_cmds, 0, k)
	}
}

@(private)
record_checksum :: proc(client: ^Client($G)) {
	tick := client.sim.tick
	if tick % CHECKSUM_EVERY == 0 {
		client.chk[(tick / CHECKSUM_EVERY) % CHK_RING] = {tick, usim.checksum(client.sim)}
	}
}

// Steps one tick; `save` false: nothing restores or reads its state (sim.step).
@(private)
step_tick :: proc(client: ^Client($G), inputs: ^usim.Inputs(G), kind: Step_Kind, save: bool) {
	step_start := time.tick_now()
	usim.step(client.sim, inputs, save)
	client.stats.steps[kind] += 1
	client.stats.step_us[kind] += i64(time.duration_microseconds(time.tick_since(step_start)))
	record_checksum(client)
	if client.resim_from == 0 || client.sim.tick < client.resim_from {
		client.resim_from = client.sim.tick
	}
}

// Steps predicted tick `tick` (forward, or re-simulated after a rollback): saved every PREDICTED_SAVE_EVERY ticks, and
// when a snapshot of it may be wanted.
@(private)
step_predicted :: proc(client: ^Client($G), tick: u32, kind: Step_Kind) {
	inputs := &client.pred_inputs[tick % PRED_RING]
	predicted_inputs(client, tick, inputs)
	step_tick(client, inputs, kind, tick % PREDICTED_SAVE_EVERY == 0 || wants_image(client, tick))
}

@(private)
on_tick_verified :: proc(client: ^Client($G), tick: u32) {
	if client.hooks.verified != nil {
		client.hooks.verified(
			client.hooks.user,
			client.sim,
			tick,
			&client.fin[tick % FIN_RING],
			usim.events_at(client.sim, tick),
		)
	}
}

// Whether a verified checksum tick's state must be saved for a snapshot: a joiner waits for one, or the relay
// may ask for it in a desync report.
@(private)
wants_image :: proc(client: ^Client($G), tick: u32) -> bool {
	if tick % CHECKSUM_EVERY != 0 {
		return false
	}
	if client.keep_images {
		return true
	}
	for request in client.snap_reqs {
		if request.min_tick <= tick {
			return true
		}
	}
	return false
}

// A checksum tick just verified, its state in the ring: the snapshots joiners wait for, and the kept image.
@(private)
on_checksum_tick :: proc(client: ^Client($G), tick: u32, now: i64) {
	if !wants_image(client, tick) || usim.state_at(client.sim, tick) == nil {
		return
	}
	// The kept tick replaces the oldest one: a copy, encoded only if the relay asks for it.
	if client.keep_images {
		oldest := 0
		for kept_tick, k in client.kept_ticks {
			if kept_tick < client.kept_ticks[oldest] {
				oldest = k
			}
		}
		if usim.snapshot_keep(client.sim, tick, oldest) {
			client.kept_ticks[oldest] = tick
		}
	}
	due := false
	for request in client.snap_reqs {
		due ||= request.min_tick <= tick
	}
	if !due {
		return
	}
	data := usim.snapshot_encode(client.sim, tick)
	defer delete(data)
	for i := 0; i < len(client.snap_reqs); {
		request := client.snap_reqs[i]
		if request.min_tick > tick {
			i += 1
			continue
		}
		send_snapshot(client, u8(request.joiner), tick, data, now)
		log.infof("sent snapshot of tick %d (%d bytes) for slot %d", tick, len(data), request.joiner)
		ordered_remove(&client.snap_reqs, i)
	}
}

@(private)
send_snapshot :: proc(client: ^Client($G), target: u8, tick: u32, data: []u8, now: i64) {
	writer := msg_begin(&client.w, .Snap_Begin)
	wire.w_u8(writer, target)
	wire.w_u32(writer, tick)
	wire.w_u32(writer, u32(len(data)))
	csend(client, writer, .Reliable, now)
	for offset := 0; offset < len(data); offset += SNAP_CHUNK {
		chunk_writer := msg_begin(&client.w, .Snap_Chunk)
		wire.w_u8(chunk_writer, target)
		wire.w_u32(chunk_writer, u32(offset))
		wire.w_bytes(chunk_writer, data[offset:min(offset + SNAP_CHUNK, len(data))])
		csend(client, chunk_writer, .Reliable, now)
	}
}

// The relay asks for a kept checksum tick's snapshot (a desync report): encoded from its copy now and sent, or an
// empty one when not kept.
@(private)
send_image :: proc(client: ^Client($G), tick: u32, now: i64) {
	for kept_tick, k in client.kept_ticks {
		if kept_tick == tick && tick != 0 && client.sim != nil {
			client.received_work = true
			if bytes, kept, ok := usim.snapshot_encode_kept(client.sim, k, &client.image_buf); ok && kept == tick {
				send_snapshot(client, RELAY_TARGET, tick, bytes, now)
				return
			}
		}
	}
	send_snapshot(client, RELAY_TARGET, tick, nil, now)
}

// Steps tick `tick`, which is final, while verifying up to `newest`. Its state is saved only when something will
// read it: the newest verified tick (the next rollback's target), and a checksum tick a snapshot is wanted of.
@(private)
step_final :: proc(client: ^Client($G), tick, newest: u32, kind: Step_Kind, now: i64) {
	step_tick(client, &client.fin[tick % FIN_RING], kind, tick == newest || wants_image(client, tick))
	on_tick_verified(client, tick)
	if tick % CHECKSUM_EVERY == 0 {
		on_checksum_tick(client, tick, now)
	}
}

// Restores the nearest saved tick at or before `target` and re-steps the final ticks up to `target` (unsaved:
// PREDICTED_SAVE_EVERY leaves at most one). False when none is restorable.
@(private)
restore_to :: proc(client: ^Client($G), target: u32) -> bool {
	from := target
	for usim.state_at(client.sim, from) == nil {
		if from == 0 || target - from >= PREDICTED_SAVE_EVERY {
			return false
		}
		from -= 1
	}
	if !usim.restore(client.sim, from) {
		return false
	}
	for tick in from + 1 ..= target {
		step_tick(client, &client.fin[tick % FIN_RING], .Resim, false)
		client.stats.resim_ticks += 1
	}
	return true
}

// The most finalized ticks one client_step verifies: Client_Config.catchup_ticks, else the prediction cap.
@(private)
catchup_budget :: proc(client: ^Client($G)) -> u32 {
	return client.cfg.catchup_ticks != 0 ? client.cfg.catchup_ticks : client.tm.prediction_cap
}

// Whether the client holds finalized ticks it has not verified after this step's budget: it is catching up (no
// prediction: the final ticks are next). Not while a reconnect's Hello waits for its Welcome: nothing is verified then.
@(private)
catching_up :: #force_inline proc(client: ^Client($G)) -> bool {
	return client.sim != nil && !client.checking && client.fin_upto > client.verified && !awaiting_resume(client)
}

// Whether a reconnect's Hello waits for its Welcome: the Hello named the verified tick it resumes from, which holds
// until the Welcome answers it.
@(private)
awaiting_resume :: #force_inline proc(client: ^Client($G)) -> bool {
	return client.reconnect_us != 0 && !client.welcomed
}

// Advances the verified frame with newly finalized ticks (at most catchup_budget of them), rolling back on a
// misprediction.
@(private)
advance_verified :: proc(client: ^Client($G), now: i64) {
	if client.sim == nil || client.checking || client.fin_upto <= client.verified || awaiting_resume(client) {
		return
	}
	new_verified := min(client.fin_upto, client.verified + catchup_budget(client))
	old_verified := client.verified
	limit := min(new_verified, client.predicted)
	mispredicted: u32 = 0
	for tick in old_verified + 1 ..= new_verified {
		assert(client.fin_tick[tick % FIN_RING] == tick, "finalized ring slot holds another tick")
	}
	for tick in old_verified + 1 ..= limit {
		// Compared as bytes, like the checksum: -0.0 and +0.0 differ, a NaN equals itself.
		if !usim.inputs_same(&client.pred_inputs[tick % PRED_RING], &client.fin[tick % FIN_RING]) {
			mispredicted = tick
			break
		}
	}
	for tick in old_verified + 1 ..= new_verified {
		drop_verified_commands(client, tick)
		for &seat in client.locals {
			if seat.state == .Seated && seat.slot in client.fin[tick % FIN_RING].replaced do client.stats.own_replaced += 1
		}
	}
	for tick in old_verified + 1 ..= (mispredicted != 0 ? mispredicted - 1 : limit) {
		on_tick_verified(client, tick) // predicted right: the ring already holds the verified result
		if tick % CHECKSUM_EVERY == 0 {
			on_checksum_tick(client, tick, now)
		}
	}
	if mispredicted != 0 {
		depth := int(client.predicted - (mispredicted - 1))
		if !restore_to(client, mispredicted - 1) {
			set_status(client, .Failed, "rollback failed: the target tick is not restorable")
			return
		}
		client.stats.rollbacks += 1
		client.stats.depth_sum += depth
		client.stats.depth_max = max(client.stats.depth_max, depth)
		for tick in mispredicted ..= new_verified {
			step_final(client, tick, new_verified, .Resim, now)
			client.stats.resim_ticks += 1
		}
		if client.hooks.verified_state != nil do client.hooks.verified_state(client.hooks.user, client.sim)
		if client.fin_upto > new_verified {
			// Catching up: the ticks past this step's budget are final already and come next; predicting them again
			// from an older tick's inputs would only be rolled back.
			client.predicted = new_verified
		}
		for tick in new_verified + 1 ..= client.predicted {
			step_predicted(client, tick, .Resim)
			client.stats.resim_ticks += 1
		}
		client.predicted = max(client.predicted, new_verified)
	} else if new_verified > client.predicted {
		for tick in client.predicted + 1 ..= new_verified {
			step_final(client, tick, new_verified, .Verified, now)
		}
		client.predicted = new_verified
		if client.hooks.verified_state != nil do client.hooks.verified_state(client.hooks.user, client.sim)
	} else if client.predicted == new_verified &&
	   client.hooks.verified_state != nil &&
	   client.sim.tick == new_verified {
		client.hooks.verified_state(client.hooks.user, client.sim) // predicted right, up to exactly this tick
	}
	client.verified = new_verified
	// Report the checksums of newly verified ticks (every 16th; a joiner from its join tick on).
	first := (old_verified / CHECKSUM_EVERY + 1) * CHECKSUM_EVERY
	for tick := first; tick <= new_verified; tick += CHECKSUM_EVERY {
		entry := client.chk[(tick / CHECKSUM_EVERY) % CHK_RING]
		assert(entry.tick == tick, "missing checksum for a verified tick")
		if tick < client.first_tick {
			continue
		}
		if client.ticks == 0 && len(client.checksums) == CHECKSUMS_KEPT {
			copy(client.checksums[:], client.checksums[1:])
			pop(&client.checksums)
		}
		append(&client.checksums, [2]u64{u64(tick), entry.value})
		writer := msg_begin(&client.w, .Checksum)
		wire.w_u32(writer, tick)
		wire.w_u64(writer, entry.value)
		csend(client, writer, .Reliable, now)
	}
}

// Generates own inputs up to local + delay. A tick skipped because the delay grew repeats the
// last input; when the delay shrinks, the already-sent input for a tick is kept.
@(private)
generate_inputs :: proc(client: ^Client($G)) {
	target := client.local + client.delay
	if client.ticks != 0 {
		target = min(target, client.ticks)
	}
	for &seat, local in client.locals {
		if seat.state == .Seated do generate_seat_inputs(client, &seat, local, target)
	}
}

// generate_inputs for one seated local player.
@(private)
generate_seat_inputs :: proc(client: ^Client($G), seat: ^Local_Seat(G), local: int, target: u32) {
	// A clock far ahead of the inputs (after a long outage; or a relay time that is no relay's, which would cost a
	// step per tick) generates only the ring's worth: the older ticks would be overwritten unsent, and the relay
	// replaced their inputs long ago.
	if target > seat.own_last + OWN_RING {
		seat.own_last = target - OWN_RING
		seat.own_acked = max(seat.own_acked, seat.own_last)
	}
	first_gen := seat.own_last < seat.first_tick
	for tick := seat.own_last + 1; tick <= target; tick += 1 {
		if tick < target && !first_gen {
			seat.own[tick % OWN_RING] = seat.own[(tick - 1) % OWN_RING]
		} else if client.hooks.sample != nil {
			seat.own[tick % OWN_RING] = client.hooks.sample(
				client.hooks.user,
				local,
				seat.slot,
				tick,
				client_state(client),
			)
		} else {
			seat.own[tick % OWN_RING] = {}
		}
		seat.own_last = tick
		seat.own_sends[tick % OWN_RING] = 0
		if client.hooks.commands != nil {
			out := &client.cmd_out
			out.slot = seat.slot
			out.cap = COMMAND_QUEUE - len(seat.own_cmds)
			clear(&out.list)
			client.hooks.commands(client.hooks.user, local, seat.slot, tick, client_state(client), out)
			for command in out.list[:min(len(out.list), max(out.cap, 0))] {
				seat.cmd_seq += 1
				append(&seat.own_cmds, Own_Command{seq = seat.cmd_seq, want = tick, cmd = command})
			}
		}
	}
}

// Sends each seated local player's Inputs: one message per seat.
@(private)
send_inputs :: proc(client: ^Client($G), now: i64) {
	for &seat, local in client.locals {
		if seat.state == .Seated do send_seat_inputs(client, &seat, local, now)
	}
	client.last_send_us = now
}

// send_inputs for one seated local player.
@(private)
send_seat_inputs :: proc(client: ^Client($G), seat: ^Local_Seat(G), local: int, now: i64) {
	Input :: usim.part(G, usim.GAME_INPUT)
	window := inputs_window(Input)
	// The newest unacked inputs, up to the window: each rides in that many consecutive packets whatever the round
	// trip. From the oldest, a round trip longer than the window would hold the newest back until acks move, past
	// their ticks.
	first := max(seat.own_acked + 1, seat.first_tick)
	if seat.own_last >= first + window {
		newest := seat.own_last + 1 - window
		// Unacked inputs the main message has moved past that rode in fewer packets than the window: a step that
		// generated several at once (the clock's first step samples the input delay's ticks; a jump of the delay or
		// the clock; a client stepped late) left the older of them fewer packets, none past the window. They ride in
		// messages of their own beside this one until each has had the window's packets: those that can still be in
		// time, so a starved client with no acks coming sends a bounded few per step. In time: the relay clock is
		// about the stamp lead behind own_last and finalizes a tick without its input `tolerance` after it is due, so
		// an input older than own_last - (stamp lead + tolerance) can no longer count. The reach is never shorter than
		// the window and the delay ceiling, which cover a clock running ahead of its target on a short path.
		from := first
		lead := max(stamp_ahead(client.rtt_us, client.tm), window - 1 + client.tm.max_delay)
		if reach := lead + client.tm.tolerance; seat.own_last > reach {
			from = max(from, seat.own_last - reach)
		}
		for from < newest {
			if seat.own_sends[from % OWN_RING] >= u8(window) {
				from += 1
				continue
			}
			last := from
			for last + 1 < newest && last + 1 < from + window && seat.own_sends[(last + 1) % OWN_RING] < u8(window) {
				last += 1
			}
			inputs_message(client, seat, local, from, last, false, now)
			from = last + 1
		}
		first = newest
	}
	inputs_message(client, seat, local, first, seat.own_last, true, now)
}

// One Inputs message of a local player: its own inputs first..last (none when last < first), and with `commands` its
// unacked commands.
@(private)
inputs_message :: proc(
	client: ^Client($G),
	seat: ^Local_Seat(G),
	local: int,
	first, last: u32,
	commands: bool,
	now: i64,
) {
	Input :: usim.part(G, usim.GAME_INPUT)
	writer := msg_begin(&client.w, .Inputs)
	wire.w_u8(writer, u8(local))
	wire.w_u32(writer, min(client.fin_upto, fin_base(client) + FIN_RING - 64))
	wire.w_u32(writer, first)
	count := last >= first ? last - first + 1 : 0
	assert(len(writer.buf) + 1 == INPUTS_HEAD)
	wire.w_u8(writer, u8(count))
	base: Input // each input as its changes from the one before it, the first from the zero input
	for tick in first ..< first + count {
		window_write_input(writer, &seat.own[tick % OWN_RING], &base)
		base = seat.own[tick % OWN_RING]
		seat.own_sends[tick % OWN_RING] = min(seat.own_sends[tick % OWN_RING] + 1, INPUTS_MAX)
	}
	// Commands the relay hasn't acked, in seq order, as many as fit.
	k := 0
	for k < len(seat.own_cmds) && seat.own_cmds[k].seq <= seat.cmd_acked {
		k += 1
	}
	wire.w_u32(writer, k < len(seat.own_cmds) ? seat.own_cmds[k].seq : seat.cmd_seq + 1)
	command_count_at := len(writer.buf)
	wire.w_u8(writer, 0)
	command_count := 0
	for ; commands && k < len(seat.own_cmds) && command_count < 255; k += 1 {
		own_command := &seat.own_cmds[k]
		if len(writer.buf) + COMMAND_SEND_HEAD + int(own_command.cmd.size) > MAX_MESSAGE {
			break
		}
		wire.w_u32(writer, own_command.want)
		wire.w_u8(writer, own_command.cmd.kind)
		wire.w_u8(writer, own_command.cmd.size)
		wire.w_bytes(writer, own_command.cmd.data[:own_command.cmd.size])
		command_count += 1
	}
	writer.buf[command_count_at] = u8(command_count)
	csend(client, writer, .Unreliable, now)
}

@(private)
at_end :: #force_inline proc(client: ^Client($G), tick: u32) -> bool {
	return client.ticks != 0 && tick >= client.ticks
}

// The local clock's lead over the relay clock, in ticks: own inputs are stamped `stamp_ahead` ahead of the relay
// clock (they reach the relay just in time) and sampled `delay` ticks before their tick, so the clock runs
// stamp_ahead - delay ahead (behind, when negative).
@(private)
clock_lead :: proc(client: ^Client($G), delay: u32) -> f64 {
	return f64(stamp_ahead(client.rtt_us, client.tm)) - f64(delay)
}

// The input delay this round trip wants: the round trip's high end (RTT + 4 × its mean deviation, so jitter
// doesn't push the prediction past the cap) into want_delay.
@(private)
client_want_delay :: proc(client: ^Client($G)) -> u32 {
	return want_delay(client.rtt_us + 4 * client.rtt_dev_us, client.tm, client.tm.min_delay)
}

// One tick of the local clock: own inputs for local + delay go out on it, also while the prediction cap holds the
// sim back (a stall: the view hitches, the inputs still count).
@(private)
clock_tick :: proc(client: ^Client($G)) {
	client.local += 1
	generate_inputs(client)
	if client.sim != nil && !client.checking && client.local > client.verified + client.tm.prediction_cap {
		client.stats.stall_ticks += 1
	}
}

// Scheduler: advances the local tick at the tick rate ± 2% towards relay tick + lead.
@(private)
schedule :: proc(client: ^Client($G), now: i64) -> (advanced: bool) {
	if !client.welcomed || !client.have_offset {
		return
	}
	tick_us := client.tm.tick_us
	relay_tick := (f64(now) + client.offset_us) / tick_us
	if !client.started {
		delay := client_want_delay(client)
		if relay_tick + clock_lead(client, delay) < 0 {
			return // the relay's start lead: wait until the local clock's tick 0 is due
		}
		client.started = true
		client.delay = delay
		client.delay_eval_us = now
		client.local = max(clock_ticks(relay_tick + clock_lead(client, delay)), client.verified)
		client.next_tick_us = f64(now) + tick_us
		generate_inputs(client)
		return true
	}
	// The delay rises at once (a prediction past the cap stalls the view) and falls a tick per second.
	if want := client_want_delay(client); want > client.delay {
		client.delay = want
		client.stats.delay_changes += 1
		client.delay_eval_us = now
	} else if want < client.delay && now - client.delay_eval_us >= 1_000_000 {
		client.delay -= 1
		client.stats.delay_changes += 1
		client.delay_eval_us = now
	}
	behind := relay_tick + clock_lead(client, client.delay) - f64(client.local) // ticks behind its target
	period := tick_us
	if behind > 1.0 {
		period *= 0.98
	} else if behind < 0 {
		period *= 1.02
	}
	for f64(now) >= client.next_tick_us {
		client.next_tick_us += period
		if at_end(client, client.local) || behind < -4 {
			continue // finished, or far ahead of the relay: hold
		}
		clock_tick(client)
		behind -= 1
		advanced = true
	}
	// Far behind (e.g. after an outage): catch up without waiting for the slew, the last OWN_RING ticks one by one (their
	// inputs are sampled), any before them in one jump.
	if behind > OWN_RING && !at_end(client, client.local) {
		skip := min(clock_ticks(behind - OWN_RING), CLOCK_MAX - client.local)
		if client.ticks != 0 {
			skip = min(skip, client.ticks - client.local)
		}
		client.local += skip
		behind = min(behind - f64(skip), OWN_RING) // past CLOCK_MAX: no relay's clock
		advanced = true
	}
	for behind > 4 && !at_end(client, client.local) && client.local < CLOCK_MAX {
		clock_tick(client)
		behind -= 1
		advanced = true
	}
	return
}

// The local clock stays below this (2.1 years at 64 Hz): a relay time past it is no relay's, and the clock never wraps.
@(private)
CLOCK_MAX :: max(u32) / 2

// A tick count from the clock's f64, clamped to [0, CLOCK_MAX] (a converted out-of-range float is the platform's own).
@(private)
clock_ticks :: proc(ticks: f64) -> u32 {
	return u32(clamp(ticks, 0, f64(CLOCK_MAX)))
}

@(private)
predict :: proc(client: ^Client($G)) {
	if client.sim == nil || client.checking || catching_up(client) {
		return
	}
	for client.predicted < client.local &&
	    client.predicted < client.verified + client.tm.prediction_cap &&
	    !at_end(client, client.predicted) {
		tick := client.predicted + 1
		step_predicted(client, tick, .Predicted)
		client.predicted = tick
	}
}

// What a local player asks for, as a Hello's or Join's seat.
@(private)
seat_ask :: proc(seat: ^Local_Seat($G), local: int) -> (ask: Seat_Ask) {
	ask = {
		local     = u8(local),
		slot      = seat.want_slot < 0 ? ANY_SLOT : u8(seat.want_slot),
		join_tick = seat.join_tick,
		name      = seat.name,
	}
	ask.profile.len = u8(copy(ask.profile.bytes[:], usim.bytes_of(&seat.profile)))
	return
}

// Sends a Join for each local player added since the Welcome.
@(private)
send_joins :: proc(client: ^Client($G), now: i64) {
	for &seat, local in client.locals {
		if seat.state != .Asked || seat.asked do continue
		ask := seat_ask(&seat, local)
		writer := msg_begin(&client.w, .Join)
		wire.w_u8(writer, ask.local)
		wire.w_u8(writer, ask.slot)
		wire.w_u32(writer, ask.join_tick)
		w_text(writer, &ask.name)
		w_text(writer, &ask.profile)
		csend(client, writer, .Reliable, now)
		seat.asked = true
	}
}

// Says Hello: every local player asked for, who this is, and what it can resume from: its verified tick V and its
// checksum of the checksum tick at or before V (none without a checked sim, or before tick 16).
@(private)
send_hello :: proc(client: ^Client($G), now: i64) {
	hello := Hello {
		compat  = client.cfg.compat,
		token   = client.cfg.token,
		sent_us = now,
	}
	if client.sim != nil && !client.checking && client.verified >= CHECKSUM_EVERY {
		check_tick := client.verified - client.verified % CHECKSUM_EVERY
		if entry := client.chk[(check_tick / CHECKSUM_EVERY) % CHK_RING]; entry.tick == check_tick {
			hello.resume_tick, hello.resume_checksum = client.verified, entry.value
		}
	}
	for &seat, local in client.locals {
		if seat.state != .Asked do continue
		hello.seats[hello.seat_count] = seat_ask(&seat, local)
		hello.seat_count += 1
		seat.asked = true
	}
	clear(&client.w.buf)
	write_hello(&client.w, &hello)
	csend(client, &client.w, .Reliable, now)
	client.hello_sent = true
	if client.reconnect_us == 0 {
		set_status(client, .Connecting, "")
	}
}

// The connection to the relay ended without a goodbye after it worked (silence, the transport said so, the relay
// forgot us): open a new one, as a restarted program would (one that echoes the old one's epoch would be taken as the
// peer starting over, by both sides, without end), and say Hello again, asking for every local player it had, with
// what we can resume from. What belonged to the old seats goes: the clock, the commands the relay never finalized
// (they went with the seats), the joiners that waited for our snapshot, a snapshot on its way. The sim, the finalized
// ring and V stay.
@(private)
reconnect :: proc(client: ^Client($G), lost_us: i64) {
	client.relay = channel_reopen(client.ch, client.link_index, 0)
	client.stats.reconnects += 1
	client.reconnect_us = lost_us
	client.hello_sent = false
	client.welcomed = false
	client.started = false
	client.have_offset = false
	client.rtt_samples = 0 // the new connection's samples count from 0
	for &seat in client.locals {
		if seat.state == .None do continue
		seat.state = .Asked // in the next Hello: the lowest free slot, as soon as possible, like any rejoin
		seat.asked = false
		seat.want_slot = -1
		seat.join_tick = 0
		seat.slot = -1
		clear(&seat.own_cmds)
		seat.cmd_seq, seat.cmd_acked, seat.cmd_final = 0, 0, 0
	}
	client.slot = -1
	clear(&client.snap_reqs)
	client.snap_total = 0
	clear(&client.snap_buf)
	client.resync_tick = 0
	if client.checking {
		usim.destroy(client.sim) // a snapshot not checked yet is no state to resume from
		client.sim = nil
		client.checking = false
		client.kept_ticks = {}
		client.verified, client.predicted = 0, 0
	}
	set_status(client, .Reconnecting, "connection lost")
}

// One step of the client: receive, verify (rolling back if needed), advance the local clock,
// predict, publish, send. Returns when it wants to run next (a now_us value).
client_step :: proc(client: ^Client($G), now: i64) -> (wake_us: i64) {
	if client_finished(client) {
		return now + 100_000
	}
	if !client.hello_sent {
		send_hello(client, now)
	}
	work_start := time.tick_now()
	client.received_work = false
	for event in channel_poll(client.ch, now) {
		if event.peer != client.relay {
			continue // not from the relay
		}
		switch event.kind {
		case .Message:
			handle_client_msg(client, event.data, now)
		case .Disconnected:
			lost := client.reconnect_us != 0 ? client.reconnect_us : now
			worked := client.welcomed || client.reconnect_us != 0
			if client.end_us == 0 && worked && now - lost < RECONNECT_US {
				reconnect(client, lost)
			} else if client.end_us == 0 {
				set_status(
					client,
					worked ? .Disconnected : .Failed,
					worked ? "connection lost" : "no answer from the relay",
				)
			}
		case .Incompatible:
			set_status(client, .Failed, "a different game build (another protocol version)")
		case .Connected:
		}
	}
	if client.rehello {
		client.rehello = false
		if client.end_us == 0 do reconnect(client, client.reconnect_us)
	}
	if client_finished(client) {
		return now + 100_000
	}
	if !client.hello_sent {
		send_hello(client, now) // a reconnect's, on the new connection, in the step that opened it
	}
	client.resim_from = 0
	if !client.leaving {
		if client.welcomed do send_joins(client, now)
		advance_verified(client, now)
		if client.reconnect_us != 0 &&
		   client.welcomed &&
		   client.sim != nil &&
		   !client.checking &&
		   !catching_up(client) {
			client.reconnect_us = 0 // back at the live tick
			set_status(client, .Connected, "")
		}
		advanced := schedule(client, now)
		predict(client)
		if client.resim_from != 0 || client.received_work {
			durations_add(&client.stats.client_steps, i64(time.duration_microseconds(time.tick_since(work_start))))
		}
		if client.resim_from != 0 && client.hooks.frame != nil {
			client.hooks.frame(
				client.hooks.user,
				client.sim,
				Frame_Info{client.predicted, client.verified, client.resim_from},
			)
		}
		if client.welcomed && (advanced || f64(now - client.last_send_us) >= client.tm.tick_us) {
			send_inputs(client, now)
		}
		if client.welcomed && client.ticks != 0 && client.verified >= client.ticks && !client.done_sent {
			csend(client, msg_begin(&client.w, .Done), .Reliable, now)
			client.done_sent = true
		}
	}
	channel_flush(client.ch, now)
	if client.end_us != 0 {
		// Linger briefly so the last acks (End) or our Leave go out, then leave once our reliable
		// queue is empty.
		if (channel_idle(client.ch, client.relay) && now - client.end_us > 100_000) ||
		   now - client.end_us > 2_000_000 {
			set_status(client, .Disconnected, client.detail)
		}
	}
	wake_us = now + client.poll_us
	if client.started && !client.leaving {
		wake_us = min(wake_us, i64(client.next_tick_us) + 1) // a leaving client's clock stopped: it only lingers
	}
	if catching_up(client) && !client.leaving {
		wake_us = now // the next budget's worth at once, after this step's poll, clock, inputs and flush
	}
	return
}

// What a client reports about its session: the headless CLI's client object (src/headless/README.md), the Godot host's
// result line, and the end-to-end scenarios' checks.
Client_Result :: struct {
	slot:        int,
	member:      int, // the relay's member id
	join_tick:   u32, // the first tick the player is present
	final_tick:  u32, // the last verified tick (= the session's ticks on success)
	checksums:   [][2]u64, // Client.checksums: an endless session's last CHECKSUMS_KEPT
	// Did not fail and was told of no desync; a fixed-length session's client also verified every tick of it.
	ok:          bool,
	using stats: Client_Stats,
	zones:       []Zone_Mean, // Client_Config.dev: each zone's self time per stepped tick, the game's zones then "other"
}

// A zone's mean self time per stepped tick (Client_Result.zones).
@(private)
Zone_Mean :: struct {
	name: string,
	us:   f64,
}

// The clock a client's sim times its zones by (sim.dev_attach): the netcode's, in nanoseconds.
@(private)
zone_clock :: proc "contextless" () -> i64 {
	return time.tick_now()._nsec
}

// A client's results; the checksums are copied into `allocator` (the caller deletes them).
client_result :: proc(client: ^Client($G), allocator := context.allocator) -> Client_Result {
	checksums := make([][2]u64, len(client.checksums), allocator)
	copy(checksums, client.checksums[:])
	zones: []Zone_Mean
	if client.sim != nil {
		totals := usim.zone_totals(client.sim)
		zones = make([]Zone_Mean, len(totals.names), allocator)
		stepped := 0
		for count in client.stats.steps do stepped += count
		for name, i in totals.names {
			zones[i] = {strings.clone(name, allocator), stepped > 0 ? f64(totals.ns[i]) / 1000 / f64(stepped) : 0}
		}
	}
	return {
		zones      = zones,
		slot       = client.slot,
		member     = int(client.member),
		join_tick  = client.first_tick,
		final_tick = client.verified,
		checksums  = checksums,
		ok         = client.status !=
			.Failed && client.stats.desyncs == 0 && (client.ticks == 0 || client.verified == client.ticks),
		stats      = client_stats(client),
	}
}

// The JSON object of a client's results (temp-allocated).
client_json :: proc(result: Client_Result) -> string {
	checksums := make([dynamic]u8, 0, 64 + len(result.checksums) * 32, context.temp_allocator)
	for entry, i in result.checksums {
		if i > 0 {
			append(&checksums, ',')
		}
		append(&checksums, ..transmute([]u8)fmt.tprintf(`[%d,"%016x"]`, entry[0], entry[1]))
	}
	zones := make([dynamic]u8, 0, 16 + len(result.zones) * 32, context.temp_allocator)
	for zone, i in result.zones {
		if i > 0 do append(&zones, ',')
		append(&zones, ..transmute([]u8)fmt.tprintf(`"%s":%.2f`, zone.name, zone.us))
	}
	return fmt.tprintf(
		`{{"slot":%d,"member":%d,"final_tick":%d,"checksums":[%s],"client_step_us":{{"p99":%d,"max":%d,"count":%d}},"snapshot_bytes":%d,"snapshot_ms":%.1f,"rollbacks":%d,"rollback_depth_avg":%.2f,"rollback_depth_max":%d,"stall_ticks":%d,"resim_ticks":%d,"join_tick":%d,"delay":%d,"delay_changes":%d,"rtt_ms":%.1f,"ceiling_ms":%.1f,"slow":%v,"slow_changes":%d,"desyncs":%d,"reconnects":%d,"resumes":%d,"resyncs":%d,"ok":%v,"net":%s,"steps":{{"verified":%d,"resim":%d,"predicted":%d}},"step_us":{{"verified":%d,"resim":%d,"predicted":%d}},"zones":{{%s}}}}`,
		result.slot,
		result.member,
		result.final_tick,
		string(checksums[:]),
		durations_percentile(result.client_steps, 99),
		result.client_steps.max_us,
		result.client_steps.count,
		result.snapshot_bytes,
		f64(result.snapshot_us) / 1000,
		result.rollbacks,
		result.rollbacks > 0 ? f64(result.depth_sum) / f64(result.rollbacks) : 0,
		result.depth_max,
		result.stall_ticks,
		result.resim_ticks,
		result.join_tick,
		result.delay,
		result.delay_changes,
		result.rtt_ms,
		result.ceiling_ms,
		result.slow,
		result.slow_changes,
		result.desyncs,
		result.reconnects,
		result.resumes,
		result.resyncs,
		result.ok,
		channel_stats_json(result.net),
		result.steps[.Verified],
		result.steps[.Resim],
		result.steps[.Predicted],
		result.step_us[.Verified],
		result.step_us[.Resim],
		result.step_us[.Predicted],
		string(zones[:]),
	)
}
