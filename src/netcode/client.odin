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

// What a client asks the relay for and who it says it is (client_create).
Client_Config :: struct {
	slot:        int, // the slot to ask for; -1: any free one
	join_tick:   u32, // the earliest tick to become present (0: as soon as possible)
	compat:      u64, // build/game id the relay checks (0: sim.compat_of(game, content))
	content:     []u8, // the level (src/level/README.md; nil: the game's own, sim.Game.content); borrowed for the client's lifetime
	player_name: string, // the player's display name (sent to the relay, shared with everyone)
	// On a link that vouches for no account (LAN, direct UDP): what the relay recognizes this person by when they
	// come back (the same member, in any free slot). All zero: none (a new member every time).
	token:       Token,
}

// Where a client stands (Client.status), reported through Hooks.status.
Status :: enum u8 {
	Idle,
	Connecting,
	Connected, // welcomed and simulating (a late joiner: once its snapshot is restored and checked)
	Failed, // rejected, a protocol error, another protocol version, or the relay never answered
	Disconnected, // left, the session ended, refused as too far behind, or the connection was lost after it worked
}

// What changed in a step, for the view.
Frame_Info :: struct {
	tick:       u32, // the latest predicted tick (the sim's current tick)
	verified:   u32, // the latest verified tick
	resim_from: u32, // ticks resim_from..tick were computed in this step: their events are new
}

// How a client talks to the host application (src/netcode/README.md, Hooks): every hook is called from client_step, on
// its caller's thread, and gets `user` back.
Hooks :: struct($G: typeid) {
	user:     rawptr,
	// The local player's input for `tick` (it holds `slot`), sampled when the client's clock reaches it. `state` is
	// the latest predicted state (nil before the sim exists).
	sample:   proc(
		user: rawptr,
		slot: int,
		tick: u32,
		state: ^usim.part(G, usim.GAME_STATE),
	) -> usim.part(G, usim.GAME_INPUT),
	// Optional: the local player's commands for `tick`, called right after `sample` for every tick the
	// client generates. usim.send_command(out, command) returns false once COMMAND_QUEUE commands wait.
	commands: proc(
		user: rawptr,
		slot: int,
		tick: u32,
		state: ^usim.part(G, usim.GAME_STATE),
		out: ^usim.Command_Out(usim.part(G, usim.GAME_CMD)),
	),
	// After a step that computed new predicted ticks: the view reads simulation.state (frame.tick's) and
	// usim.events_at for ticks frame.resim_from..frame.tick.
	frame:    proc(user: rawptr, simulation: ^usim.Sim(G), frame: Frame_Info),
	// Each newly verified tick, in order, with its final inputs and the events it emitted under them.
	verified: proc(
		user: rawptr,
		simulation: ^usim.Sim(G),
		tick: u32,
		inputs: ^usim.Inputs(G),
		events: []usim.Raw_Event,
	),
	// Each change of the client's status, with why ("" when there is nothing to say).
	status:   proc(user: rawptr, status: Status, detail: string),
	// Optional: the relay found the players' checksums of a tick differ (report.detail is valid during the call).
	desync:   proc(user: rawptr, report: Desync_Report),
}

// An own command the client holds until a verified tick carries it.
@(private)
Own_Command :: struct {
	seq:  u32,
	want: u32, // the tick it was sent for (W)
	cmd:  usim.Raw_Command,
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
// The checksums of verified checksum ticks, until reported: a joiner's first step verifies every finalized tick it
// holds, up to FIN_RING of them.
CHK_RING :: FIN_RING / CHECKSUM_EVERY
#assert(CHK_RING * CHECKSUM_EVERY >= FIN_RING)
CHECKSUMS_KEPT :: 64 // an endless session's client keeps its last this many checksums (Client.checksums)
// Predicted ticks are saved every 2nd tick (and a checksum tick a snapshot is wanted of): a rollback restores the
// nearest saved tick at or before its target, at most one tick back, which the ring still holds at the prediction cap
// (P - V <= ring - 2). Checksum ticks are multiples of it, so always saved.
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
	// live, filled by client_stats
	rtt_ms:         f64, // the round trip the clock and input delay use
	delay:          u32, // the input delay, ticks
	net:            Channel_Stats,
}

// A client of one session (client_create): its sim's verified and predicted frames, its clock, its own inputs and
// commands, the snapshots it sends joiners, and the roster. Driven by client_step.
Client :: struct($G: typeid) {
	game:           ^G,
	cfg:            Client_Config,
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
	// from Welcome
	welcomed:       bool,
	slot:           int,
	member:         u16, // our member id (the relay's): our join record's
	seed:           u64,
	ticks:          u32, // session length, 0: endless
	first_tick:     u32, // J: first tick this player is present
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
	// own inputs
	own:            [OWN_RING]usim.part(G, usim.GAME_INPUT),
	own_last:       u32,
	own_acked:      u32,
	own_sends:      [OWN_RING]u8, // how many Inputs messages carried each own input (send_inputs)
	// own commands: sent (until acked) and predicted until a verified tick carries them
	own_cmds:       [dynamic]Own_Command, // seq order
	cmd_seq:        u32, // the last seq given
	cmd_acked:      u32, // the relay has every seq up to this one
	cmd_out:        usim.Command_Out(usim.part(G, usim.GAME_CMD)), // for hooks.commands
	// time sync
	started:        bool,
	offset_us:      f64, // relay time - local time
	have_offset:    bool,
	rtt_us:         f64, // the round trip, averaged over the channel's samples
	rtt_dev_us:     f64, // its mean deviation (jitter)
	rtt_samples:    int, // the channel's samples taken in
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
client_create :: proc(game: ^$G, cfg: Client_Config, link: Link, hooks: Hooks(G)) -> ^Client(G) {
	Input :: usim.part(G, usim.GAME_INPUT)
	usim.check_wire(Input)
	client := new(Client(G))
	client.game = game
	client.cfg = cfg
	if client.cfg.compat == 0 {
		client.cfg.compat = usim.compat_of(game, client.cfg.content)
	}
	client.poll_us = POLL_US
	client.hooks = hooks
	client.tm = timing_of(game.tick_hz)
	client.ch = channel_make()
	link_index := channel_add_link(client.ch, link)
	client.relay = channel_peer(client.ch, link_index, 0)
	client.w = wire.writer_make(MAX_DATAGRAM)
	reserve(&client.own_cmds, COMMAND_QUEUE)
	client.delay = 1
	client.slot = -1
	return client
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
	delete(client.own_cmds)
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
	csend(client, msg_begin(&client.w, .Leave), .Reliable, now)
	client.end_us = now
}

// Whether the client is done: it left, the session ended, the connection was lost, or it failed. The loop stepping
// it stops on it.
client_finished :: proc(client: ^Client($G)) -> bool {
	return client.status == .Disconnected || client.status == .Failed
}

// The latest predicted state (nil before the sim exists).
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

// The client's counters and live estimates (round trip, input delay, the channel's bytes and datagrams).
client_stats :: proc(client: ^Client($G)) -> Client_Stats {
	stats := client.stats
	stats.rtt_ms = client.rtt_us / 1000
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
	PLAYERS :: usim.part(G, usim.GAME_PLAYERS)
	slot := int(wire.r_u8(reader))
	member := wire.r_u16(reader)
	seed := wire.r_u64(reader)
	tick_hz := int(wire.r_u16(reader))
	ticks := wire.r_u32(reader)
	first := wire.r_u32(reader)
	flags := transmute(Welcome_Flags)wire.r_u8(reader)
	if !reader.ok ||
	   client.welcomed ||
	   slot >= PLAYERS ||
	   member == NO_MEMBER ||
	   first == 0 ||
	   (client.cfg.slot >= 0 && slot != client.cfg.slot) {
		return
	}
	if tick_hz != client.game.tick_hz {
		set_status(client, .Failed, "the relay runs another tick rate")
		return
	}
	client.welcomed = true
	client.slot = slot
	client.member = member
	client.seed = seed
	client.ticks = ticks
	client.first_tick = first
	client.keep_images = .Keep_Images in flags
	client.own_last = first - 1
	client.own_acked = first - 1
	// No growing on the session thread.
	reserve(&client.checksums, ticks != 0 ? int(ticks / CHECKSUM_EVERY) + 1 : CHECKSUMS_KEPT)
	if first == 1 {
		client.sim = usim.create(client.game, seed, client.cfg.content)
		if !client.leaving {
			set_status(client, .Connected, "") // a client that left before its Welcome stays leaving ("left")
		}
	}
}

@(private)
fin_have :: #force_inline proc(client: ^Client($G), tick: u32) -> bool {
	return client.fin_tick[tick % FIN_RING] == tick
}

// The base the finalized ring is anchored to: ticks beyond base + FIN_RING are not accepted yet.
@(private)
fin_base :: proc(client: ^Client($G)) -> u32 {
	return client.sim != nil ? client.verified : client.snap_tick
}

// Takes the channel's new round-trip sample, if there is one, into the average and its deviation.
@(private)
take_rtt :: proc(client: ^Client($G)) {
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
}

@(private)
on_finalized :: proc(client: ^Client($G), reader: ^wire.Reader, now: i64) {
	relay_time := r_i64(reader)
	input_ack := wire.r_u32(reader)
	command_ack := wire.r_u32(reader)
	first := wire.r_u32(reader)
	count := u32(wire.r_u8(reader))
	if !reader.ok || !client.welcomed {
		return
	}
	client.cmd_acked = max(client.cmd_acked, min(command_ack, client.cmd_seq))
	// The channel measured the round trip from the Hello's ack on, so the first Finalized already times the clock
	// (a late joiner's inputs for its join tick reach the relay in time).
	take_rtt(client)
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
	client.own_acked = max(client.own_acked, min(input_ack, client.own_last))
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
		if !reader.ok do return
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
		case .Newer_Connection:
			detail = "this player is in the session on a newer connection"
		}
		set_status(client, why == .Too_Far_Behind ? .Disconnected : .Failed, detail)
	case .Finalized:
		on_finalized(client, &reader, now)
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
		   client.sim != nil ||
		   client.snap_total == 0 ||
		   offset != len(client.snap_buf) ||
		   len(bytes) > client.snap_total - offset {
			return
		}
		append(&client.snap_buf, ..bytes)
		if len(client.snap_buf) == client.snap_total {
			load_snapshot(client, now)
		}
	case .Snap_Ok:
		tick := wire.r_u32(&reader)
		if reader.ok && client.checking && client.sim != nil && tick == client.sim.tick {
			client.checking = false
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
// that tick (a checksum tick) and says Snap_Ok, or sends a snapshot from someone else. Until then the sim waits.
@(private)
load_snapshot :: proc(client: ^Client($G), now: i64) {
	client.received_work = true
	sim, err := usim.from_snapshot(client.game, client.snap_buf[:], client.cfg.content)
	client.snap_total = 0
	if err != .None || sim.tick != client.snap_tick {
		if sim != nil {
			usim.destroy(sim)
		}
		set_status(client, .Failed, fmt.tprintf("received snapshot does not restore: %v", err))
		return
	}
	client.sim = sim
	client.stats.snapshot_bytes = len(client.snap_buf)
	client.stats.snapshot_us = now - client.snap_begin_us
	client.verified = client.sim.tick
	client.predicted = client.verified
	client.own_last = max(client.own_last, client.verified)
	client.own_acked = max(client.own_acked, client.verified) // finalized: nothing of them to send
	client.checking = true
	tick := client.sim.tick
	value := usim.checksum(client.sim)
	client.chk[(tick / CHECKSUM_EVERY) % CHK_RING] = {tick, value}
	writer := msg_begin(&client.w, .Checksum)
	wire.w_u32(writer, tick)
	wire.w_u64(writer, value)
	csend(client, writer, .Reliable, now)
	log.infof("restored snapshot of tick %d (%d bytes)", tick, len(client.snap_buf))
	delete(client.snap_buf) // a snapshot's size, needed again only if this one fails the check
	client.snap_buf = nil
}

// Inputs for predicting `tick`: own input and commands, the others' latest finalized input repeated
// (their commands are unknown until finalized: none).
@(private)
predicted_inputs :: proc(client: ^Client($G), tick: u32, out: ^usim.Inputs(G)) {
	out^ = {}
	if client.fin_upto >= 1 && fin_have(client, client.fin_upto) {
		last := &client.fin[client.fin_upto % FIN_RING]
		out.present = last.present
		out.input = last.input
	}
	if tick >= client.first_tick {
		out.present += {client.slot}
		out.input[client.slot] = client.own[min(tick, client.own_last) % OWN_RING]
		if tick == client.first_tick {
			out.joins[client.slot] = client.member // our join record, as the relay will write it
		}
	}
	// Own commands where the relay will put them if they reach it in time: each in the tick it was sent
	// for, or the first tick not finalized yet when that one is (a late command moves on), in order, at
	// most COMMANDS_PER_SLOT per tick. A wrong guess is an ordinary misprediction.
	at, in_tick: u32 = 0, 0
	for &own_command in client.own_cmds {
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

// A verified tick carries the own commands the relay put in it: they are no longer predicted.
@(private)
drop_verified_commands :: proc(client: ^Client($G), tick: u32) {
	carried := len(usim.slot_commands(&client.fin[tick % FIN_RING], client.slot))
	remove_range(&client.own_cmds, 0, min(carried, len(client.own_cmds)))
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

// Advances the verified frame with newly finalized ticks, rolling back on a misprediction.
@(private)
advance_verified :: proc(client: ^Client($G), now: i64) {
	new_verified := client.fin_upto
	if client.sim == nil || client.checking || new_verified <= client.verified {
		return
	}
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
		if client.slot >= 0 && client.slot in client.fin[tick % FIN_RING].replaced do client.stats.own_replaced += 1
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
	// A clock far ahead of the inputs (after a long outage; or a relay time that is no relay's, which would cost a
	// step per tick) generates only the ring's worth: the older ticks would be overwritten unsent, and the relay
	// replaced their inputs long ago.
	if target > client.own_last + OWN_RING {
		client.own_last = target - OWN_RING
		client.own_acked = max(client.own_acked, client.own_last)
	}
	first_gen := client.own_last < client.first_tick
	for tick := client.own_last + 1; tick <= target; tick += 1 {
		if tick < target && !first_gen {
			client.own[tick % OWN_RING] = client.own[(tick - 1) % OWN_RING]
		} else if client.hooks.sample != nil {
			client.own[tick % OWN_RING] = client.hooks.sample(
				client.hooks.user,
				client.slot,
				tick,
				client_state(client),
			)
		} else {
			client.own[tick % OWN_RING] = {}
		}
		client.own_last = tick
		client.own_sends[tick % OWN_RING] = 0
		if client.hooks.commands != nil {
			out := &client.cmd_out
			out.slot = client.slot
			out.cap = COMMAND_QUEUE - len(client.own_cmds)
			clear(&out.list)
			client.hooks.commands(client.hooks.user, client.slot, tick, client_state(client), out)
			for command in out.list[:min(len(out.list), max(out.cap, 0))] {
				client.cmd_seq += 1
				append(&client.own_cmds, Own_Command {
					seq  = client.cmd_seq,
					want = tick,
					cmd  = command,
				})
			}
		}
	}
}

@(private)
send_inputs :: proc(client: ^Client($G), now: i64) {
	Input :: usim.part(G, usim.GAME_INPUT)
	window := inputs_window(Input)
	// The newest unacked inputs, up to the window: each rides in that many consecutive packets whatever the round
	// trip. From the oldest, a round trip longer than the window would hold the newest back until acks move, past
	// their ticks.
	first := max(client.own_acked + 1, client.first_tick)
	if client.own_last >= first + window {
		newest := client.own_last + 1 - window
		// Unacked inputs the main message has moved past that rode in fewer packets than the window: a step that
		// generated several at once (the clock's first step samples the input delay's ticks; a jump of the delay or
		// the clock; a client stepped late) left the older of them fewer packets, none past the window. They ride in
		// messages of their own beside this one until each has had the window's packets: those that can still be in
		// time (max_delay + tolerance back), so a starved client with no acks coming sends a bounded few per step.
		from := first
		if reach := client.tm.max_delay + client.tm.tolerance; newest > reach {
			from = max(from, newest - reach)
		}
		for from < newest {
			if client.own_sends[from % OWN_RING] >= u8(window) {
				from += 1
				continue
			}
			last := from
			for last + 1 < newest && last + 1 < from + window && client.own_sends[(last + 1) % OWN_RING] < u8(window) {
				last += 1
			}
			inputs_message(client, from, last, false, now)
			from = last + 1
		}
		first = newest
	}
	inputs_message(client, first, client.own_last, true, now)
	client.last_send_us = now
}

// One Inputs message: own inputs first..last (none when last < first), and with `commands` the unacked commands.
@(private)
inputs_message :: proc(client: ^Client($G), first, last: u32, commands: bool, now: i64) {
	Input :: usim.part(G, usim.GAME_INPUT)
	writer := msg_begin(&client.w, .Inputs)
	wire.w_u32(writer, min(client.fin_upto, fin_base(client) + FIN_RING - 64))
	wire.w_u32(writer, first)
	count := last >= first ? last - first + 1 : 0
	assert(len(writer.buf) + 1 == INPUTS_HEAD)
	wire.w_u8(writer, u8(count))
	base: Input // each input as its changes from the one before it, the first from the zero input
	for tick in first ..< first + count {
		window_write_input(writer, &client.own[tick % OWN_RING], &base)
		base = client.own[tick % OWN_RING]
		client.own_sends[tick % OWN_RING] = min(client.own_sends[tick % OWN_RING] + 1, INPUTS_MAX)
	}
	// Commands the relay hasn't acked, in seq order, as many as fit.
	k := 0
	for k < len(client.own_cmds) && client.own_cmds[k].seq <= client.cmd_acked {
		k += 1
	}
	wire.w_u32(writer, k < len(client.own_cmds) ? client.own_cmds[k].seq : client.cmd_seq + 1)
	command_count_at := len(writer.buf)
	wire.w_u8(writer, 0)
	command_count := 0
	for ; commands && k < len(client.own_cmds) && command_count < 255; k += 1 {
		own_command := &client.own_cmds[k]
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
	return want_delay(client.rtt_us + 4 * client.rtt_dev_us, client.tm)
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
CLOCK_MAX :: max(u32) / 2

// A tick count from the clock's f64, clamped to [0, CLOCK_MAX] (a converted out-of-range float is the platform's own).
@(private)
clock_ticks :: proc(ticks: f64) -> u32 {
	return u32(clamp(ticks, 0, f64(CLOCK_MAX)))
}

@(private)
predict :: proc(client: ^Client($G)) {
	if client.sim == nil || client.checking {
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

// One step of the client: receive, verify (rolling back if needed), advance the local clock,
// predict, publish, send. Returns when it wants to run next (a now_us value).
client_step :: proc(client: ^Client($G), now: i64) -> (wake_us: i64) {
	if client_finished(client) {
		return now + 100_000
	}
	if !client.hello_sent {
		writer := msg_begin(&client.w, .Hello)
		wire.w_u8(writer, client.cfg.slot < 0 ? ANY_SLOT : u8(client.cfg.slot))
		wire.w_u32(writer, client.cfg.join_tick)
		wire.w_u64(writer, client.cfg.compat)
		wire.w_bytes(writer, client.cfg.token[:])
		name := text_of(NAME_MAX, client.cfg.player_name)
		w_text(writer, &name)
		w_i64(writer, now)
		csend(client, writer, .Reliable, now)
		client.hello_sent = true
		set_status(client, .Connecting, "")
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
			if client.end_us == 0 {
				set_status(
					client,
					client.welcomed ? .Disconnected : .Failed,
					client.welcomed ? "connection lost" : "no answer from the relay",
				)
			}
		case .Incompatible:
			set_status(client, .Failed, "a different game build (another protocol version)")
		case .Connected:
		}
	}
	if client_finished(client) {
		return now + 100_000
	}
	client.resim_from = 0
	if !client.leaving {
		advance_verified(client, now)
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
}

// A client's results; the checksums are copied into `allocator` (the caller deletes them).
client_result :: proc(client: ^Client($G), allocator := context.allocator) -> Client_Result {
	checksums := make([][2]u64, len(client.checksums), allocator)
	copy(checksums, client.checksums[:])
	return {
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
	return fmt.tprintf(
		`{{"slot":%d,"member":%d,"final_tick":%d,"checksums":[%s],"client_step_us":{{"p99":%d,"max":%d,"count":%d}},"snapshot_bytes":%d,"snapshot_ms":%.1f,"rollbacks":%d,"rollback_depth_avg":%.2f,"rollback_depth_max":%d,"stall_ticks":%d,"resim_ticks":%d,"join_tick":%d,"delay":%d,"delay_changes":%d,"rtt_ms":%.1f,"desyncs":%d,"ok":%v,"net":%s,"steps":{{"verified":%d,"resim":%d,"predicted":%d}},"step_us":{{"verified":%d,"resim":%d,"predicted":%d}}}}`,
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
		result.desyncs,
		result.ok,
		channel_stats_json(result.net),
		result.steps[.Verified],
		result.steps[.Resim],
		result.steps[.Predicted],
		result.step_us[.Verified],
		result.step_us[.Resim],
		result.step_us[.Predicted],
	)
}
