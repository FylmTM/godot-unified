// The client (src/netcode/SPEC.md), generic over the game: a verified frame advanced only with finalized
// inputs, a predicted frame up to the local tick (own inputs and commands + the others' last finalized
// input repeated), rollback on misprediction, a prediction cap, an adaptive input delay and a 2% clock slew
// towards relay tick + stamp lead - delay. Own inputs are sampled and sent on the clock, also while the prediction
// cap holds the sim back. Own commands are resent until the relay acks them and predicted until a finalized tick
// carries them. Serves late-join snapshots of checksum ticks; a late joiner plays once the relay has checked its
// restored snapshot against the others' checksum. Re-simulated ticks that are already final are not saved, except
// the ones something reads. Driven by client_step from the host's loop; talks to the host application through
// Hooks (all called from client_step).
package netcode

import "core:fmt"
// Used only inside generic procs: @(require) keeps -vet from calling it unused in a program that never instantiates
// them (a game's tests that don't run the netcode).
@(require) import "core:strings"
@(require) import "core:time"

import usim "unified:sim" // the field Client.sim shadows the package name
import "unified:wire"

Client_Config :: struct {
	slot:        int, // the slot to ask for; -1: any free one
	join_tick:   u32, // the earliest tick to become present (0: as soon as possible)
	compat:      u64, // build/game id the relay checks (0: sim.compat_of(game, content))
	content:     []u8, // the game's content (the level, src/level/SPEC.md); borrowed for the client's lifetime
	player_name: string, // the player's display name (sent to the relay, shared with everyone)
	// On a link that vouches for no account (LAN, direct UDP): what the relay recognizes this person by when they
	// come back (the same member, in any free slot). All zero: none (a new member every time).
	token:       Token,
	name:        string, // for log lines
	poll_us:     i64, // 0: DEFAULT_POLL_US
	quiet:       bool,
}

Status :: enum u8 {
	Idle,
	Connecting,
	Connected, // welcomed and simulating (a late joiner: once its snapshot is restored and checked)
	Failed, // rejected, a protocol error, or the relay never answered
	Disconnected, // left, the session ended, or the connection was lost after it worked
}

// What changed in a step, for the view.
Frame_Info :: struct {
	tick:       u32, // the latest predicted tick (the sim's current tick)
	verified:   u32, // the latest verified tick
	resim_from: u32, // ticks resim_from..tick were computed in this step: their events are new
}

Hooks :: struct($State, $Input, $World, $Event, $Cmd: typeid, $PLAYERS: int) {
	user:     rawptr,
	// The local player's input for `tick` (it holds `slot`), sampled when the client's clock reaches it. `state` is
	// the latest predicted state (nil before the sim exists).
	sample:   proc(user: rawptr, slot: int, tick: u32, state: ^State) -> Input,
	// Optional: the local player's commands for `tick`, called right after `sample` for every tick the
	// client generates. usim.send_command(out, command) returns false once COMMAND_QUEUE commands wait.
	commands: proc(user: rawptr, slot: int, tick: u32, state: ^State, out: ^usim.Command_Out(Cmd)),
	// After a step that computed new predicted ticks: the view reads sim.state_at(simulation, frame.tick)
	// and frame.tick - 1 for interpolation, and usim.events_at for ticks frame.resim_from..frame.tick.
	frame:    proc(user: rawptr, simulation: ^usim.Sim(State, Input, World, Event, Cmd, PLAYERS), frame: Frame_Info),
	// Each newly verified tick, in order, with the events it emitted under the final inputs.
	verified: proc(
		user: rawptr,
		simulation: ^usim.Sim(State, Input, World, Event, Cmd, PLAYERS),
		tick: u32,
		events: []usim.Raw_Event,
	),
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

// A kept snapshot of a checksum tick (Welcome's Keep_Images), for a desync report. Its buffer is reused for the next
// tick it keeps.
@(private)
Kept_Image :: struct {
	tick: u32,
	data: [dynamic]u8, // empty: nothing kept
}

FIN_RING :: 512
#assert(CATCHUP_TICKS <= FIN_RING - 64) // a relay never streams ticks the ring would refuse
OWN_RING :: 512
PRED_RING :: 64
CHK_RING :: 64

// What a stepped tick was: verified for the first time, re-simulated after a rollback (with final or predicted
// inputs), or newly predicted.
Step_Kind :: enum u8 {
	Verified,
	Resim,
	Predicted,
}

Client :: struct($State, $Input, $World, $Event, $Cmd: typeid, $PLAYERS: int) {
	game:           ^usim.Game(State, Input, World, Event, Cmd, PLAYERS),
	cfg:            Client_Config,
	hooks:          Hooks(State, Input, World, Event, Cmd, PLAYERS),
	tm:             Timing,
	min_delay:      u32, // the game's floor on the input delay (sim.Game.min_input_delay)
	ch:             ^Channel,
	relay:          Peer,
	w:              wire.Writer,
	sim:            ^usim.Sim(State, Input, World, Event, Cmd, PLAYERS), // nil until welcomed (a late joiner: until its snapshot lands)
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
	fin:            [FIN_RING]usim.Inputs(Input, PLAYERS),
	fin_tick:       [FIN_RING]u32,
	fin_scratch:    usim.Inputs(Input, PLAYERS), // a finalized tick being decoded
	fin_upto:       u32, // highest contiguous finalized tick held
	// frames
	verified:       u32, // V
	predicted:      u32, // P (the sim's current tick)
	local:          u32, // L (scheduler tick)
	resim_from:     u32,
	pred_inputs:    [PRED_RING]usim.Inputs(Input, PLAYERS),
	chk:            [CHK_RING]struct {
		tick:  u32,
		value: u64,
	},
	// own inputs
	own:            [OWN_RING]Input,
	own_last:       u32,
	own_acked:      u32,
	// own commands: sent (until acked) and predicted until a verified tick carries them
	own_cmds:       [dynamic]Own_Command, // seq order
	cmd_seq:        u32, // the last seq given
	cmd_acked:      u32, // the relay has every seq up to this one
	cmd_out:        usim.Command_Out(Cmd), // for hooks.commands
	// time sync
	started:        bool,
	offset_us:      f64, // relay time - local time
	have_offset:    bool,
	rtt_us:         f64,
	rtt_dev_us:     f64, // the round trip's mean deviation (jitter)
	rtt_samples:    int,
	delay:          u32, // k: own inputs are sampled for tick local + delay
	delay_eval_us:  i64,
	next_tick_us:   f64,
	last_send_us:   i64,
	// late join
	snap_reqs:      [dynamic]Snap_Req, // joiners waiting for our snapshot
	snap_buf:       [dynamic]u8,
	snap_total:     int,
	snap_tick:      u32,
	checking:       bool, // our restored snapshot waits for the relay's check (Snap_Ok)
	images:         [DESYNC_IMAGES]Kept_Image,
	// end
	done_sent:      bool,
	end_us:         i64, // when End arrived or stop was called (0: not ending)
	leaving:        bool, // client_stop was called
	// results
	checksums:      [dynamic][2]u64, // (tick, checksum) of verified ticks divisible by 16, from J on
	rollbacks:      int,
	depth_sum:      int,
	depth_max:      int,
	stall_ticks:    int,
	resim_ticks:    int,
	delay_changes:  int,
	desyncs:        int, // desync reports from the relay
	first_desync:   Desync_Report, // the first one (its detail owned by the client)
	// for the dev UI's graphs (cumulative; the host takes differences)
	own_replaced:   int, // finalized ticks where the relay replaced our input (it arrived too late)
	steps:          [Step_Kind]int, // ticks stepped, by kind
	step_us:        [Step_Kind]i64, // time spent stepping them, µs
	last_msg_us:    i64, // when the relay's last message arrived (now_us; 0: none yet)
	// the relay's roster: every member of the session, by member id - 1 (departed ones stay)
	roster:         [dynamic]Roster_Entry,
	roster_changes: u32, // bumped on every roster entry received
}

// The roster entry of member `id` (the relay's id, sim.Player.id; nil: not known yet).
client_member :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), id: u16) -> ^Roster_Entry {
	index := int(id) - 1
	if index < 0 || index >= len(client.roster) || client.roster[index].member != id {
		return nil
	}
	return &client.roster[index]
}

// Creates a client talking to a relay over `link` (the client owns it). Nothing is sent until the
// first client_step.
client_create :: proc(
	game: ^usim.Game($State, $Input, $World, $Event, $Cmd, $PLAYERS),
	cfg: Client_Config,
	link: Link,
	hooks: Hooks(State, Input, World, Event, Cmd, PLAYERS),
) -> ^Client(State, Input, World, Event, Cmd, PLAYERS) {
	usim.check_wire(Input)
	client := new(Client(State, Input, World, Event, Cmd, PLAYERS))
	client.game = game
	client.cfg = cfg
	if client.cfg.compat == 0 {
		client.cfg.compat = usim.compat_of(game, client.cfg.content)
	}
	if client.cfg.poll_us <= 0 {
		client.cfg.poll_us = DEFAULT_POLL_US
	}
	client.hooks = hooks
	client.tm = timing_of(game.tick_hz)
	client.min_delay = u32(max(game.min_input_delay, 1))
	client.ch = channel_make()
	link_index := channel_add_link(client.ch, link)
	client.relay = channel_peer(client.ch, link_index, 0)
	client.w = wire.writer_make(MAX_DATAGRAM)
	reserve(&client.own_cmds, COMMAND_QUEUE)
	client.delay = client.min_delay
	client.slot = -1
	return client
}

// Frees the client, its sim and its channel (closing the link it owns). Call client_stop and step until
// Disconnected first, so the relay hears the Leave.
client_destroy :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS)) {
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
	for image in client.images {
		delete(image.data)
	}
	delete(client.first_desync.detail)
	delete(client.roster)
	free(client)
}

// Leaves the session: the relay frees the player at once. Keep stepping until the status is
// Disconnected (at most ~0.5 s, so the Leave gets through).
client_stop :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), now: i64) {
	if client.status == .Failed || client.status == .Disconnected || client.end_us != 0 {
		return
	}
	if client.hello_sent {
		csend(client, msg_begin(&client.w, .Leave), .Reliable, now)
	}
	client.end_us = now
	client.leaving = true
	client.detail = "left"
}

// The latest predicted state (nil before the sim exists).
client_state :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS)) -> ^State {
	return &client.sim.state if client.sim != nil else nil
}

// The round trip to the relay in milliseconds, the estimate the clock and input delay use, for the dev UI.
client_rtt_ms :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS)) -> f64 {
	return client.rtt_us / 1000
}

// The typed diff of a game's State's snapshots, for Relay_Config.desync_diff (and Host_Config.desync_detail).
desync_diff_of :: proc($State: typeid) -> proc(a, b: []u8) -> string {
	return proc(a, b: []u8) -> string {return usim.snapshot_diff(State, a, b)}
}

@(private)
set_status :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), status: Status, detail: string) {
	if client.status == status {
		return
	}
	client.status = status
	client.detail = detail
	if !client.cfg.quiet && (status == .Failed || status == .Disconnected) {
		fmt.eprintfln("%s: %v (%s)", client.cfg.name, status, detail)
	}
	if client.hooks.status != nil {
		client.hooks.status(client.hooks.user, status, detail)
	}
}

@(private)
csend :: proc(
	client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS),
	writer: ^wire.Writer,
	delivery: Delivery,
	now: i64,
) {
	channel_send(client.ch, client.relay, writer.buf[:], delivery, now)
}

@(private)
on_welcome :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), reader: ^wire.Reader) {
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
	if ticks != 0 {
		reserve(&client.checksums, int(ticks / CHECKSUM_EVERY) + 1) // no growing on the session thread
	}
	if first == 1 {
		client.sim = usim.create(client.game, seed, client.cfg.content)
		set_status(client, .Connected, "")
	}
}

@(private)
fin_have :: #force_inline proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), tick: u32) -> bool {
	return client.fin_tick[tick % FIN_RING] == tick
}

// The base the finalized ring is anchored to: ticks beyond base + FIN_RING are not accepted yet.
@(private)
fin_base :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS)) -> u32 {
	return client.sim != nil ? client.verified : client.snap_tick
}

@(private)
on_finalized :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), reader: ^wire.Reader, now: i64) {
	relay_time := r_i64(reader)
	echo := r_i64(reader)
	hold := r_i64(reader)
	input_ack := wire.r_u32(reader)
	command_ack := wire.r_u32(reader)
	first := wire.r_u32(reader)
	count := u32(wire.r_u8(reader))
	if !reader.ok || !client.welcomed {
		return
	}
	client.cmd_acked = max(client.cmd_acked, min(command_ack, client.cmd_seq))
	if echo > 0 {
		sample := f64(now - echo - hold)
		// A sample past the disconnect timeout is no round trip: an echo of another clock (a previous occupant's).
		if sample > 0 && sample < DISCONNECT_US {
			if client.rtt_samples == 0 {
				client.rtt_us = sample
			} else {
				client.rtt_dev_us += (abs(sample - client.rtt_us) - client.rtt_dev_us) * 0.1
				client.rtt_us += (sample - client.rtt_us) * 0.1
			}
			client.rtt_samples += 1
		}
	}
	// Until the first echo of our inputs (they go out from Welcome on, so it takes a round trip), the
	// channel's latest RTT sample (the acks of the Hello and the datagrams since) stands in, and the first
	// echo replaces it. Waiting for echoes would start a late joiner's clock a round trip later and land
	// its inputs for the join tick at the relay about two round trips after its Hello: past J + tolerance
	// from ~280 ms.
	rtt_ok := client.rtt_samples > 0
	if !rtt_ok {
		client.rtt_us, rtt_ok = channel_rtt(client.ch, client.relay)
	}
	if rtt_ok {
		offset := f64(relay_time) + client.rtt_us / 2 - f64(now)
		if !client.have_offset {
			client.offset_us = offset
			client.have_offset = true
		} else if abs(offset - client.offset_us) < DISCONNECT_US {
			client.offset_us += (offset - client.offset_us) * 0.05
		} // else not the relay's clock (a mangled time): taken, it would throw the local clock hours off
	}
	client.own_acked = max(client.own_acked, input_ack)
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
on_snap_begin :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), reader: ^wire.Reader) {
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
		client.checking = false
		client.verified, client.predicted = 0, 0
	}
	client.snap_tick = tick
	client.snap_total = total
	clear(&client.snap_buf)
	// Finalized ticks are streamed from the snapshot tick on.
	client.fin_upto = max(client.fin_upto, client.snap_tick - 1)
	for fin_have(client, client.fin_upto + 1) {
		client.fin_upto += 1
	}
}

@(private)
on_desync :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), reader: ^wire.Reader) {
	report := Desync_Report {
		tick     = wire.r_u32(reader),
		diverged = transmute(usim.Slots)wire.r_u32(reader),
	}
	report.detail = string(wire.r_bytes(reader, int(wire.r_u16(reader))))
	if !reader.ok {
		return
	}
	client.desyncs += 1
	if client.desyncs == 1 {
		client.first_desync = report
		client.first_desync.detail = strings.clone(report.detail)
	}
	if !client.cfg.quiet {
		fmt.eprintfln(
			"%s: desync at tick %d: players %v differ%s%s",
			client.cfg.name,
			report.tick,
			report.diverged,
			report.detail != "" ? ": " : "",
			report.detail,
		)
	}
	if client.hooks.desync != nil {
		client.hooks.desync(client.hooks.user, report)
	}
}

@(private)
handle_client_msg :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), data: []u8, now: i64) {
	client.last_msg_us = now
	reader := wire.reader_make(data)
	#partial switch Msg(wire.r_u8(&reader)) {
	case .Welcome:
		on_welcome(client, &reader)
	case .Reject:
		why := Reject_Reason(wire.r_u8(&reader))
		detail := "rejected"
		#partial switch why {
		case .Full:
			detail = "the session is full"
		case .Player_Taken:
			detail = "that player is taken"
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
			append(&client.snap_reqs, Snap_Req{int(target), tick})
		}
	case .Snap_Begin:
		on_snap_begin(client, &reader)
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
			set_status(client, .Connected, "")
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
load_snapshot :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), now: i64) {
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
	client.verified = client.sim.tick
	client.predicted = client.verified
	client.own_last = max(client.own_last, client.verified)
	client.checking = true
	tick := client.sim.tick
	value := usim.checksum(client.sim)
	client.chk[(tick / CHECKSUM_EVERY) % CHK_RING] = {tick, value}
	writer := msg_begin(&client.w, .Checksum)
	wire.w_u8(writer, u8(client.slot))
	wire.w_u32(writer, tick)
	wire.w_u64(writer, value)
	csend(client, writer, .Reliable, now)
	if !client.cfg.quiet {
		fmt.eprintfln("%s: restored snapshot of tick %d (%d bytes)", client.cfg.name, tick, len(client.snap_buf))
	}
	clear(&client.snap_buf)
}

// Inputs for predicting `tick`: own input and commands, the others' latest finalized input repeated
// (their commands are unknown until finalized: none).
@(private)
predicted_inputs :: proc(
	client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS),
	tick: u32,
	out: ^usim.Inputs(Input, PLAYERS),
) {
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
			out.member[client.slot] = client.member // our join record, as the relay will write it
		}
	}
	// Own commands where the relay will put them if they reach it in time: each in the tick it was sent
	// for, or the first tick not finalized yet when that one is (a late command moves on), in order, at
	// most COMMANDS_PER_PLAYER per tick. A wrong guess is an ordinary misprediction.
	at, in_tick: u32 = 0, 0
	for &own_command in client.own_cmds {
		lands_at := max(own_command.want, client.fin_upto + 1, at)
		if lands_at == at && in_tick == usim.COMMANDS_PER_PLAYER {
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
drop_verified_commands :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), tick: u32) {
	carried := len(usim.slot_commands(&client.fin[tick % FIN_RING], client.slot))
	remove_range(&client.own_cmds, 0, min(carried, len(client.own_cmds)))
}

@(private)
record_checksum :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS)) {
	tick := client.sim.tick
	if tick % CHECKSUM_EVERY == 0 {
		client.chk[(tick / CHECKSUM_EVERY) % CHK_RING] = {tick, usim.checksum(client.sim)}
	}
}

// Steps one tick; `save` false: a tick that is already final and nothing reads its state (step_unsaved).
@(private)
step_tick :: proc(
	client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS),
	inputs: ^usim.Inputs(Input, PLAYERS),
	kind: Step_Kind,
	save := true,
) {
	step_start := time.tick_now()
	if save {
		usim.step(client.sim, inputs)
	} else {
		usim.step_unsaved(client.sim, inputs)
	}
	client.steps[kind] += 1
	client.step_us[kind] += i64(time.duration_microseconds(time.tick_since(step_start)))
	record_checksum(client)
	if client.resim_from == 0 || client.sim.tick < client.resim_from {
		client.resim_from = client.sim.tick
	}
}

@(private)
on_tick_verified :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), tick: u32) {
	if client.hooks.verified != nil {
		client.hooks.verified(client.hooks.user, client.sim, tick, usim.events_at(client.sim, tick))
	}
}

// Whether a verified checksum tick's state must be saved for a snapshot: a joiner waits for one, or the relay
// may ask for it in a desync report.
@(private)
wants_image :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), tick: u32) -> bool {
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
on_checksum_tick :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), tick: u32, now: i64) {
	if !wants_image(client, tick) || usim.state_at(client.sim, tick) == nil {
		return
	}
	// The kept image replaces the oldest one, in its buffer; a joiner gets the same bytes.
	data: []u8
	if client.keep_images {
		oldest := 0
		for image, k in client.images {
			if image.tick < client.images[oldest].tick {
				oldest = k
			}
		}
		client.images[oldest].tick = tick
		data = usim.snapshot_encode_into(client.sim, tick, &client.images[oldest].data)
	} else {
		data = usim.snapshot_encode(client.sim, tick)
	}
	for i := 0; i < len(client.snap_reqs); {
		request := client.snap_reqs[i]
		if request.min_tick > tick {
			i += 1
			continue
		}
		send_snapshot(client, u8(request.joiner), tick, data, now)
		if !client.cfg.quiet {
			fmt.eprintfln(
				"%s: sent snapshot of tick %d (%d bytes) for player %d",
				client.cfg.name,
				tick,
				len(data),
				request.joiner,
			)
		}
		ordered_remove(&client.snap_reqs, i)
	}
	if !client.keep_images {
		delete(data)
	}
}

@(private)
send_snapshot :: proc(
	client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS),
	target: u8,
	tick: u32,
	data: []u8,
	now: i64,
) {
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

// The relay asks for a kept checksum tick's snapshot (a desync report): sent, or an empty one when not kept.
@(private)
send_image :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), tick: u32, now: i64) {
	for image in client.images {
		if image.tick == tick && len(image.data) > 0 {
			send_snapshot(client, RELAY_TARGET, tick, image.data[:], now)
			return
		}
	}
	send_snapshot(client, RELAY_TARGET, tick, nil, now)
}

// Steps tick `tick`, which is final, while verifying up to `newest`. Its state is saved only when something will
// read it (#117): the newest verified tick (the next rollback's target), the one before it when nothing is predicted
// past it (the view interpolates between the current tick and the one before), and a checksum tick a snapshot is
// wanted of.
@(private)
step_final :: proc(
	client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS),
	tick, newest: u32,
	view_reads_previous: bool,
	kind: Step_Kind,
	now: i64,
) {
	save := tick == newest || (view_reads_previous && tick + 1 == newest) || wants_image(client, tick)
	step_tick(client, &client.fin[tick % FIN_RING], kind, save)
	on_tick_verified(client, tick)
	if tick % CHECKSUM_EVERY == 0 {
		on_checksum_tick(client, tick, now)
	}
}

// Advances the verified frame with newly finalized ticks, rolling back on a misprediction.
@(private)
advance_verified :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), now: i64) {
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
		if client.slot >= 0 && client.slot in client.fin[tick % FIN_RING].replaced do client.own_replaced += 1
	}
	for tick in old_verified + 1 ..= (mispredicted != 0 ? mispredicted - 1 : limit) {
		on_tick_verified(client, tick) // predicted right: the ring already holds the verified result
		if tick % CHECKSUM_EVERY == 0 {
			on_checksum_tick(client, tick, now)
		}
	}
	if mispredicted != 0 {
		if !usim.restore(client.sim, mispredicted - 1) {
			set_status(client, .Failed, "rollback failed: the target tick is not restorable")
			return
		}
		depth := int(client.predicted - (mispredicted - 1))
		client.rollbacks += 1
		client.depth_sum += depth
		client.depth_max = max(client.depth_max, depth)
		view_reads_previous := client.predicted <= new_verified
		for tick in mispredicted ..= new_verified {
			step_final(client, tick, new_verified, view_reads_previous, .Resim, now)
			client.resim_ticks += 1
		}
		for tick in new_verified + 1 ..= client.predicted {
			inputs := &client.pred_inputs[tick % PRED_RING]
			predicted_inputs(client, tick, inputs)
			step_tick(client, inputs, .Resim)
			client.resim_ticks += 1
		}
		client.predicted = max(client.predicted, new_verified)
	} else if new_verified > client.predicted {
		for tick in client.predicted + 1 ..= new_verified {
			step_final(client, tick, new_verified, true, .Verified, now)
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
		append(&client.checksums, [2]u64{u64(tick), entry.value})
		writer := msg_begin(&client.w, .Checksum)
		wire.w_u8(writer, u8(client.slot))
		wire.w_u32(writer, tick)
		wire.w_u64(writer, entry.value)
		csend(client, writer, .Reliable, now)
	}
}

// Generates own inputs up to local + delay. A tick skipped because the delay grew repeats the
// last input; when the delay shrinks, the already-sent input for a tick is kept.
@(private)
generate_inputs :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS)) {
	target := client.local + client.delay
	if client.ticks != 0 {
		target = min(target, client.ticks)
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
send_inputs :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), now: i64) {
	writer := msg_begin(&client.w, .Inputs)
	wire.w_u8(writer, u8(client.slot))
	w_i64(writer, now)
	wire.w_u32(writer, min(client.fin_upto, fin_base(client) + FIN_RING - 64))
	first := max(client.own_acked + 1, client.first_tick)
	last := min(client.own_last, first + inputs_window(Input) - 1)
	wire.w_u32(writer, first)
	count := last >= first ? last - first + 1 : 0
	wire.w_u8(writer, u8(count))
	base: Input // each input as its changes from the one before it, the first from the zero input (#245)
	for tick in first ..< first + count {
		window_write_input(writer, &client.own[tick % OWN_RING], &base)
		base = client.own[tick % OWN_RING]
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
	for ; k < len(client.own_cmds) && command_count < 255; k += 1 {
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
	client.last_send_us = now
}

@(private)
at_end :: #force_inline proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), tick: u32) -> bool {
	return client.ticks != 0 && tick >= client.ticks
}

// The local clock's lead over the relay clock, in ticks: own inputs are stamped `stamp_ahead` ahead of the relay
// clock (they reach the relay just in time) and sampled `delay` ticks before their tick, so the clock runs
// stamp_ahead - delay ahead (behind, when negative).
@(private)
clock_lead :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), delay: u32) -> f64 {
	return f64(stamp_ahead(client.rtt_us, client.tm)) - f64(delay)
}

// The input delay this round trip wants: the round trip's high end (RTT + 4 × its mean deviation, so jitter
// doesn't push the prediction past the cap) into want_delay.
@(private)
client_want_delay :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS)) -> u32 {
	return want_delay(client.rtt_us + 4 * client.rtt_dev_us, client.tm, client.min_delay)
}

// One tick of the local clock: own inputs for local + delay go out on it, also while the prediction cap holds the
// sim back (a stall: the view hitches, the inputs still count).
@(private)
clock_tick :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS)) {
	client.local += 1
	generate_inputs(client)
	if client.sim != nil && !client.checking && client.local > client.verified + client.tm.prediction_cap {
		client.stall_ticks += 1
	}
}

// Scheduler: advances the local tick at the tick rate ± 2% towards relay tick + lead.
@(private)
schedule :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), now: i64) -> (advanced: bool) {
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
		client.local = max(u32(relay_tick + clock_lead(client, delay)), client.verified)
		client.next_tick_us = f64(now) + tick_us
		generate_inputs(client)
		return true
	}
	// The delay rises at once (a prediction past the cap stalls the view) and falls a tick per second.
	if want := client_want_delay(client); want > client.delay {
		client.delay = want
		client.delay_changes += 1
		client.delay_eval_us = now
	} else if want < client.delay && now - client.delay_eval_us >= 1_000_000 {
		client.delay -= 1
		client.delay_changes += 1
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
	// Far behind (e.g. after an outage): catch up without waiting for the slew.
	for behind > 4 && !at_end(client, client.local) {
		clock_tick(client)
		behind -= 1
		advanced = true
	}
	return
}

@(private)
predict :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS)) {
	if client.sim == nil || client.checking {
		return
	}
	for client.predicted < client.local &&
	    client.predicted < client.verified + client.tm.prediction_cap &&
	    !at_end(client, client.predicted) {
		tick := client.predicted + 1
		inputs := &client.pred_inputs[tick % PRED_RING]
		predicted_inputs(client, tick, inputs)
		step_tick(client, inputs, .Predicted)
		client.predicted = tick
	}
}

// One step of the client: receive, verify (rolling back if needed), advance the local clock,
// predict, publish, send. Returns when it wants to run next (a now_us value).
client_step :: proc(client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS), now: i64) -> (wake_us: i64) {
	if client.status == .Failed || client.status == .Disconnected {
		return now + 100_000
	}
	if !client.hello_sent {
		writer := msg_begin(&client.w, .Hello)
		wire.w_u16(writer, PROTOCOL_VERSION)
		wire.w_u8(writer, client.cfg.slot < 0 ? ANY_PLAYER : u8(client.cfg.slot))
		wire.w_u32(writer, client.cfg.join_tick)
		wire.w_u64(writer, client.cfg.compat)
		wire.w_bytes(writer, client.cfg.token[:])
		name := name_of(client.cfg.player_name)
		w_name(writer, &name)
		csend(client, writer, .Reliable, now)
		client.hello_sent = true
		set_status(client, .Connecting, "")
	}
	for event in channel_poll(client.ch, now) {
		switch event.kind {
		case .Message:
			handle_client_msg(client, event.data, now)
		case .Disconnected:
			if event.peer == client.relay && client.end_us == 0 {
				set_status(
					client,
					client.welcomed ? .Disconnected : .Failed,
					client.welcomed ? "connection lost" : "no answer from the relay",
				)
			}
		case .Connected:
		}
	}
	if client.status == .Failed || client.status == .Disconnected {
		return now + 100_000
	}
	client.resim_from = 0
	if !client.leaving {
		advance_verified(client, now)
		advanced := schedule(client, now)
		predict(client)
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
			writer := msg_begin(&client.w, .Done)
			wire.w_u8(writer, u8(client.slot))
			wire.w_u32(writer, client.verified)
			csend(client, writer, .Reliable, now)
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
	wake_us = now + client.cfg.poll_us
	if client.started {
		wake_us = min(wake_us, i64(client.next_tick_us) + 1)
	}
	return
}

// What a client reports about its session: the headless CLI's client object (src/headless/SPEC.md,
// CLI conventions), the Godot host's result line, and the end-to-end scenarios' checks.
Client_Result :: struct {
	slot:               int,
	member:             int, // the relay's member id
	join_tick:          u32, // the first tick the player is present
	final_tick:         u32, // the last verified tick (= the session's ticks on success)
	checksums:          [][2]u64, // (tick, checksum) of every verified tick divisible by 16, from join_tick on
	rollbacks:          int,
	rollback_depth_avg: f64,
	rollback_depth_max: int,
	stall_ticks:        int,
	resim_ticks:        int,
	delay:              u32,
	delay_changes:      int,
	rtt_ms:             f64,
	desyncs:            int, // desync reports the relay sent
	ok:                 bool, // verified every tick of the session, did not fail, and was told of no desync
	net:                Channel_Stats,
	steps:              [Step_Kind]int, // ticks stepped, by kind
	step_us:            [Step_Kind]i64, // time stepping them (saves included), µs
}

// A client's results; the checksums are copied into `allocator` (the caller deletes them).
client_result :: proc(
	client: ^Client($State, $Input, $World, $Event, $Cmd, $PLAYERS),
	allocator := context.allocator,
) -> Client_Result {
	checksums := make([][2]u64, len(client.checksums), allocator)
	copy(checksums, client.checksums[:])
	return {
		slot               = client.slot,
		member             = int(client.member),
		join_tick          = client.first_tick,
		final_tick         = client.verified,
		checksums          = checksums,
		rollbacks          = client.rollbacks,
		rollback_depth_avg = client.rollbacks > 0 ? f64(client.depth_sum) / f64(client.rollbacks) : 0,
		rollback_depth_max = client.depth_max,
		stall_ticks        = client.stall_ticks,
		resim_ticks        = client.resim_ticks,
		delay              = client.delay,
		delay_changes      = client.delay_changes,
		rtt_ms             = client.rtt_us / 1000,
		desyncs            = client.desyncs,
		ok                 = client.ticks !=
			0 && client.verified == client.ticks && client.status != .Failed && client.desyncs == 0,
		net                = client.ch.stats,
		steps              = client.steps,
		step_us            = client.step_us,
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
		`{{"slot":%d,"member":%d,"final_tick":%d,"checksums":[%s],"rollbacks":%d,"rollback_depth_avg":%.2f,"rollback_depth_max":%d,"stall_ticks":%d,"resim_ticks":%d,"join_tick":%d,"delay":%d,"delay_changes":%d,"rtt_ms":%.1f,"desyncs":%d,"ok":%v,"net":%s,"steps":{{"verified":%d,"resim":%d,"predicted":%d}},"step_us":{{"verified":%d,"resim":%d,"predicted":%d}}}}`,
		result.slot,
		result.member,
		result.final_tick,
		string(checksums[:]),
		result.rollbacks,
		result.rollback_depth_avg,
		result.rollback_depth_max,
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
