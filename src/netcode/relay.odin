// The input relay (src/netcode/SPEC.md), generic over the game's Input type and player count PLAYERS. No game
// logic: it owns the tick clock, collects inputs stamped with their target tick, finalizes tick T
// once every present player's input for T is in or the clock reaches T + tolerance (a missing
// input becomes the player's last finalized one, flagged "replaced"), places each player's commands
// in order in the first tick it finalizes at or after the tick they were sent for (never repeated,
// never lost), broadcasts finalized ticks
// unreliably with every unacknowledged tick resent, keeps the official input log, routes late-join
// snapshots (asking another player, or falling back to a replay from tick 0, when the provider
// leaves) and compares the clients' checksums. It serves any number of links at once (the host's
// in-process client plus remote peers) and is driven by relay_step from the host's own loop.
package netcode

// Used only inside generic procs: @(require) keeps -vet from calling them unused in a program that never
// instantiates those (a game's tests that run the sim offline only).
@(require) import "core:fmt"
@(require) import "core:sync"

import "unified:sim"
import "unified:wire"

Relay_Config :: struct {
	tick_hz:       int,
	seed:          u64,
	ticks:         u32, // session length; 0: endless
	start_players: int, // players 0..start_players-1 must connect before the clock starts (>= 1)
	compat:        u64, // build/game id (sim.compat_of); a Hello with another value is rejected (0: any)
	content:       u64, // the content's hash (sim.content_hash), recorded in the input log
	name:          string, // for log lines
	poll_us:       i64, // 0: DEFAULT_POLL_US
	quiet:         bool,
}

INPUT_RING :: 256
CHECK_RING :: 64
JOIN_LEAD_MS :: 500 // a joiner becomes present this long after the relay clock at its Hello

// A received command waiting for the tick it goes in.
@(private)
Wait_Command :: struct {
	want: u32, // the tick the sender predicted it at
	cmd:  sim.Raw_Command,
}

@(private)
Check :: struct {
	tick:     u32,
	value:    u64,
	mismatch: bool,
}

Relay :: struct($Input: typeid, $PLAYERS: int) {
	cfg:         Relay_Config,
	tm:          Timing,
	ch:          ^Channel,
	w:           wire.Writer,
	started:     bool,
	start_us:    i64,
	clock:       u32,
	clock_pub:   u32, // clock, readable from other threads (atomic)
	finalized:   u32,
	peer_of:     [PLAYERS]Peer,
	player_of:   [MAX_PEERS]int,
	welcomed:    [PLAYERS]bool,
	names:       [PLAYERS]Player_Name,
	connected:   [PLAYERS]bool,
	done:        [PLAYERS]bool,
	base_known:  [PLAYERS]bool, // finalized ticks can be streamed to this client
	active_from: [PLAYERS]u32, // first tick the player is present (0: not joined)
	provider:    [PLAYERS]int, // who sends this joiner its snapshot (-1: none pending)
	snap_min:    [PLAYERS]u32, // the oldest tick the joiner's snapshot may be of
	snap_total:  [PLAYERS]u32, // bytes of the snapshot being forwarded (from its Snap_Begin)
	snap_sent:   [PLAYERS]u32, // bytes forwarded so far
	inputs:      [PLAYERS][INPUT_RING]Input,
	input_tick:  [PLAYERS][INPUT_RING]u32, // which tick inputs[player][k] holds
	recv_upto:   [PLAYERS]u32,
	client_ack:  [PLAYERS]u32,
	cmd_recv:    [PLAYERS]u32, // the command ack: every seq up to this one is received
	cmd_wait:    [PLAYERS][dynamic]Wait_Command, // received, not finalized yet, in seq order
	rotate:      [PLAYERS]u32, // which window of a long backlog the next broadcast carries
	echo_time:   [PLAYERS]i64,
	echo_recv:   [PLAYERS]i64,
	sent_clock:  u32,
	log:         sim.Input_Log(Input, PLAYERS),
	checks:      [CHECK_RING]Check,
	desyncs:     int,
	replaced:    int,
	ending:      bool,
	end_us:      i64,
	finished:    bool,
}

relay_create :: proc(cfg: Relay_Config, $Input: typeid, $PLAYERS: int) -> ^Relay(Input, PLAYERS) {
	sim.check_plain(Input)
	_ = tick_command_budget(Input, PLAYERS) // asserts a tick with a command fits a datagram
	assert(cfg.start_players >= 1 && cfg.start_players <= PLAYERS)
	relay := new(Relay(Input, PLAYERS))
	relay.cfg = cfg
	if relay.cfg.poll_us <= 0 {
		relay.cfg.poll_us = DEFAULT_POLL_US
	}
	relay.tm = timing_of(cfg.tick_hz)
	relay.ch = channel_make()
	relay.w = wire.writer_make(MAX_DATAGRAM)
	for player in 0 ..< PLAYERS {
		relay.peer_of[player] = -1
		relay.provider[player] = -1
	}
	for &player in relay.player_of {
		player = -1
	}
	relay.log.seed = cfg.seed
	relay.log.content = cfg.content
	return relay
}

relay_destroy :: proc(relay: ^Relay($Input, $PLAYERS)) {
	channel_destroy(relay.ch)
	delete(relay.w.buf)
	sim.log_destroy(&relay.log)
	for &waiting in relay.cmd_wait {
		delete(waiting)
	}
	free(relay)
}

// Adds a transport; the relay owns it from now on. Peers on every link are served alike.
relay_add_link :: proc(relay: ^Relay($Input, $PLAYERS), link: Link) -> int {
	return channel_add_link(relay.ch, link)
}

// The relay's tick clock, readable from any thread.
relay_clock :: proc(relay: ^Relay($Input, $PLAYERS)) -> u32 {
	return sync.atomic_load(&relay.clock_pub)
}

// Ends the session: every connected client gets End; the relay is finished once they acked it
// (or after 3 s). Keep stepping until relay_finished.
relay_stop :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) {
	if relay.ending {
		return
	}
	for player in 0 ..< PLAYERS {
		if relay.connected[player] {
			relay_send(relay, player, msg_begin(&relay.w, .End), .Reliable, now)
		}
	}
	relay.ending = true
	relay.end_us = now
}

relay_finished :: proc(relay: ^Relay($Input, $PLAYERS)) -> bool {
	return relay.finished
}

@(private)
relay_log :: proc(relay: ^Relay($Input, $PLAYERS), format: string, args: ..any) {
	if !relay.cfg.quiet {
		fmt.eprintf("%s: ", relay.cfg.name)
		fmt.eprintfln(format, ..args)
	}
}

@(private)
relay_send :: proc(relay: ^Relay($Input, $PLAYERS), player: int, writer: ^wire.Writer, delivery: Delivery, now: i64) {
	if relay.peer_of[player] >= 0 {
		channel_send(relay.ch, relay.peer_of[player], writer.buf[:], delivery, now)
	}
}

@(private)
send_welcome :: proc(relay: ^Relay($Input, $PLAYERS), player: int, from_start: bool, now: i64) {
	writer := msg_begin(&relay.w, .Welcome)
	wire.w_u8(writer, u8(player))
	wire.w_u64(writer, relay.cfg.seed)
	wire.w_u16(writer, u16(relay.cfg.tick_hz))
	wire.w_u32(writer, relay.cfg.ticks)
	wire.w_u32(writer, relay.active_from[player])
	wire.w_u8(writer, u8(from_start))
	relay_send(relay, player, writer, .Reliable, now)
	relay.welcomed[player] = true
}

@(private)
reject :: proc(relay: ^Relay($Input, $PLAYERS), peer: Peer, why: Reject_Reason, now: i64) {
	writer := msg_begin(&relay.w, .Reject)
	wire.w_u8(writer, u8(why))
	channel_send(relay.ch, peer, writer.buf[:], .Reliable, now)
}

@(private)
on_hello :: proc(relay: ^Relay($Input, $PLAYERS), peer: Peer, reader: ^wire.Reader, now: i64) {
	protocol := wire.r_u16(reader)
	wanted := wire.r_u8(reader)
	asked_join_tick := wire.r_u32(reader)
	compat := wire.r_u64(reader)
	name := r_name(reader)
	if !reader.ok || relay.player_of[peer] >= 0 || relay.ending {
		return
	}
	if protocol != PROTOCOL_VERSION || (relay.cfg.compat != 0 && compat != relay.cfg.compat) {
		reject(relay, peer, .Incompatible, now)
		return
	}
	player := -1
	if wanted == ANY_PLAYER {
		limit := relay.started ? PLAYERS : relay.cfg.start_players
		for other in 0 ..< limit {
			if !relay.connected[other] {
				player = other
				break
			}
		}
		if player < 0 {
			reject(relay, peer, .Full, now)
			return
		}
	} else {
		player = int(wanted)
		if player >= PLAYERS {
			reject(relay, peer, .Full, now)
			return
		}
		if relay.connected[player] {
			reject(relay, peer, .Player_Taken, now)
			return
		}
		if !relay.started && player >= relay.cfg.start_players {
			reject(relay, peer, .Not_Started, now)
			return
		}
	}
	relay.peer_of[player] = peer
	relay.player_of[peer] = player
	relay.connected[player] = true
	relay.done[player] = false
	relay.names[player] = name
	relay.cmd_recv[player] = 0 // a new client numbers its commands from 1
	clear(&relay.cmd_wait[player])
	send_roster(relay, now)
	if !relay.started {
		relay.active_from[player] = 1
		relay.base_known[player] = true
		for other in 0 ..< relay.cfg.start_players {
			if !relay.connected[other] {
				return
			}
		}
		relay.started = true
		relay.start_us = now
		for other in 0 ..< relay.cfg.start_players {
			send_welcome(relay, other, false, now)
		}
		relay_log(relay, "%d players connected, clock started", relay.cfg.start_players)
		return
	}
	// Late join or rejoin: the player becomes present at a future tick J.
	join_tick := max(
		asked_join_tick,
		relay.clock + ceil_ticks(JOIN_LEAD_MS * 1000, relay.tm.tick_us),
		relay.finalized + 2,
	)
	relay.active_from[player] = join_tick
	relay.recv_upto[player] = join_tick - 1
	relay.base_known[player] = false
	relay.client_ack[player] = 0
	relay.snap_min[player] = join_tick - 1
	if provider := pick_provider(relay, player); provider >= 0 {
		send_welcome(relay, player, false, now)
		request_snapshot(relay, player, provider, now)
		relay_log(
			relay,
			"player %d joins at tick %d (clock %d), snapshot from player %d",
			player,
			join_tick,
			relay.clock,
			provider,
		)
	} else {
		// Nobody can send a snapshot: the joiner starts from tick 0 and replays the whole log.
		relay.base_known[player] = true
		send_welcome(relay, player, true, now)
		relay_log(
			relay,
			"player %d joins at tick %d (clock %d), replaying from tick 1",
			player,
			join_tick,
			relay.clock,
		)
	}
}

// The lowest connected player that can send `joiner` a snapshot (-1: none).
@(private)
pick_provider :: proc(relay: ^Relay($Input, $PLAYERS), joiner: int) -> int {
	for other in 0 ..< PLAYERS {
		if other != joiner &&
		   relay.connected[other] &&
		   relay.welcomed[other] &&
		   relay.base_known[other] &&
		   relay.provider[other] < 0 {
			return other
		}
	}
	return -1
}

@(private)
request_snapshot :: proc(relay: ^Relay($Input, $PLAYERS), joiner, provider: int, now: i64) {
	relay.provider[joiner] = provider
	relay.snap_total[joiner] = 0
	relay.snap_sent[joiner] = 0
	writer := msg_begin(&relay.w, .Snap_Request)
	wire.w_u8(writer, u8(joiner))
	wire.w_u32(writer, relay.snap_min[joiner])
	relay_send(relay, provider, writer, .Reliable, now)
}

// The provider of `joiner`'s snapshot left before the snapshot got through: ask another player, or
// tell the joiner to start from tick 0 and replay the log (an empty Snap_Begin).
@(private)
restart_snapshot :: proc(relay: ^Relay($Input, $PLAYERS), joiner: int, now: i64) {
	relay.provider[joiner] = -1
	relay.base_known[joiner] = false
	relay.client_ack[joiner] = 0
	if provider := pick_provider(relay, joiner); provider >= 0 {
		request_snapshot(relay, joiner, provider, now)
		relay_log(relay, "player %d: snapshot provider left, asking player %d", joiner, provider)
		return
	}
	writer := msg_begin(&relay.w, .Snap_Begin)
	wire.w_u8(writer, u8(joiner))
	wire.w_u32(writer, 0)
	wire.w_u32(writer, 0)
	relay_send(relay, joiner, writer, .Reliable, now)
	relay.base_known[joiner] = true
	relay_log(relay, "player %d: snapshot provider left, replaying from tick 1", joiner)
}

@(private)
have_input :: #force_inline proc(relay: ^Relay($Input, $PLAYERS), player: int, tick: u32) -> bool {
	return relay.input_tick[player][tick % INPUT_RING] == tick
}

@(private)
on_inputs :: proc(relay: ^Relay($Input, $PLAYERS), player: int, reader: ^wire.Reader, now: i64) {
	client_time := r_i64(reader)
	finalized_ack := wire.r_u32(reader)
	first := wire.r_u32(reader)
	count := u32(wire.r_u8(reader))
	if !reader.ok {
		return
	}
	relay.echo_time[player] = client_time
	relay.echo_recv[player] = now
	if relay.base_known[player] {
		relay.client_ack[player] = max(relay.client_ack[player], min(finalized_ack, relay.finalized))
	}
	for k in 0 ..< count {
		input := r_raw(reader, Input)
		tick := first + k
		if !reader.ok ||
		   tick <= relay.finalized ||
		   tick >= relay.finalized + INPUT_RING ||
		   (relay.cfg.ticks != 0 && tick > relay.cfg.ticks) ||
		   tick < relay.active_from[player] ||
		   have_input(relay, player, tick) {
			continue // late inputs for finalized ticks are dropped; the first copy of a tick wins
		}
		relay.inputs[player][tick % INPUT_RING] = input
		relay.input_tick[player][tick % INPUT_RING] = tick
	}
	for have_input(relay, player, relay.recv_upto[player] + 1) {
		relay.recv_upto[player] += 1
	}
	// Commands: the sender's unacked ones, from `first_seq` on. Each seq is taken once, in order; one the
	// relay already has (a resend, a duplicate) is skipped.
	first_seq := wire.r_u32(reader)
	command_count := u32(wire.r_u8(reader))
	for k in 0 ..< command_count {
		want := wire.r_u32(reader)
		kind := wire.r_u8(reader)
		size := int(wire.r_u8(reader))
		bytes := wire.r_bytes(reader, size)
		if !reader.ok || size > sim.COMMAND_MAX || size == 0 {
			return
		}
		seq := first_seq + k
		if seq <= relay.cmd_recv[player] {
			continue
		}
		if seq != relay.cmd_recv[player] + 1 || len(relay.cmd_wait[player]) >= COMMAND_QUEUE {
			return // a gap (never from an honest client) or a flood: the rest comes again
		}
		waiting := Wait_Command {
			// a wanted tick far ahead would hold back the sender's later commands: clamp it
			want = min(want, relay.finalized + INPUT_RING),
			cmd = {kind = kind, player = u8(player), size = u8(size)},
		}
		copy(waiting.cmd.data[:], bytes)
		append(&relay.cmd_wait[player], waiting)
		relay.cmd_recv[player] = seq
	}
}

@(private)
on_checksum :: proc(relay: ^Relay($Input, $PLAYERS), player: int, reader: ^wire.Reader) {
	_ = wire.r_u8(reader) // the sender's player; the relay knows it
	tick := wire.r_u32(reader)
	value := wire.r_u64(reader)
	if !reader.ok || tick % CHECKSUM_EVERY != 0 || tick == 0 {
		return
	}
	check := &relay.checks[(tick / CHECKSUM_EVERY) % CHECK_RING]
	if check.tick != tick {
		check^ = {
			tick  = tick,
			value = value,
		}
	} else if check.value != value && !check.mismatch {
		check.mismatch = true
		relay.desyncs += 1
		relay_log(
			relay,
			"DESYNC at tick %d: player %d has %016x, another player %016x",
			tick,
			player,
			value,
			check.value,
		)
	}
}

@(private)
active :: proc(relay: ^Relay($Input, $PLAYERS), player: int, tick: u32) -> bool {
	return relay.active_from[player] != 0 && tick >= relay.active_from[player] && relay.connected[player]
}

@(private)
finalize :: proc(relay: ^Relay($Input, $PLAYERS)) {
	for relay.cfg.ticks == 0 || relay.finalized < relay.cfg.ticks {
		tick := relay.finalized + 1
		anyone := false
		for player in 0 ..< PLAYERS {
			if !active(relay, player, tick) {
				continue
			}
			anyone = true
			if !have_input(relay, player, tick) && relay.clock < tick + relay.tm.tolerance {
				return
			}
		}
		if !anyone && tick > relay.clock {
			return // nobody plays: empty ticks keep pace with the clock, never run ahead of it
		}
		tick_inputs: sim.Inputs(Input, PLAYERS)
		for player in 0 ..< PLAYERS {
			if !active(relay, player, tick) {
				continue
			}
			tick_inputs.present += {player}
			if have_input(relay, player, tick) {
				tick_inputs.input[player] = relay.inputs[player][tick % INPUT_RING]
			} else {
				if tick > 1 && player in relay.log.ticks[tick - 2].present {
					tick_inputs.input[player] = relay.log.ticks[tick - 2].input[player]
				} // else just joined: there is no previous input to repeat
				tick_inputs.replaced += {player}
				relay.replaced += 1
			}
		}
		take_commands(relay, tick, &tick_inputs)
		sim.log_append(&relay.log, &tick_inputs)
		relay.finalized = tick
	}
}

// Puts the waiting commands that are due into `tick`: each present player's in seq order, those sent for
// it or earlier, at most COMMANDS_PER_PLAYER each and TICK_COMMANDS in all, within the bytes a tick may
// carry (round-robin over the players, so one can't crowd the others out). The rest wait for the next tick.
@(private)
take_commands :: proc(relay: ^Relay($Input, $PLAYERS), tick: u32, tick_inputs: ^sim.Inputs(Input, PLAYERS)) {
	taken: [PLAYERS]int
	total, bytes := 0, 0
	budget := tick_command_budget(Input, PLAYERS)
	for k in 0 ..< sim.COMMANDS_PER_PLAYER {
		for player in 0 ..< PLAYERS {
			waiting := &relay.cmd_wait[player]
			if taken[player] != k || k >= len(waiting) || !active(relay, player, tick) || waiting[k].want > tick {
				continue
			}
			size := sim.COMMAND_HEAD + int(waiting[k].cmd.size)
			if total == sim.TICK_COMMANDS || bytes + size > budget {
				continue
			}
			taken[player] += 1
			total += 1
			bytes += size
		}
	}
	if total == 0 {
		return
	}
	for player in 0 ..< PLAYERS {
		waiting := &relay.cmd_wait[player]
		for k in 0 ..< taken[player] {
			tick_inputs.commands[tick_inputs.command_count] = waiting[k].cmd
			tick_inputs.command_count += 1
		}
		remove_range(waiting, 0, taken[player])
	}
}

@(private)
broadcast :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) {
	window := finalized_window(Input, PLAYERS)
	for player in 0 ..< PLAYERS {
		if !relay.welcomed[player] || !relay.connected[player] {
			continue
		}
		writer := msg_begin(&relay.w, .Finalized)
		w_i64(writer, now - relay.start_us)
		w_i64(writer, relay.echo_time[player])
		w_i64(writer, relay.echo_time[player] != 0 ? now - relay.echo_recv[player] : 0)
		wire.w_u32(writer, max(relay.recv_upto[player], relay.finalized))
		wire.w_u32(writer, relay.cmd_recv[player])
		first := relay.client_ack[player] + 1
		last := first - 1
		if relay.base_known[player] {
			// A backlog longer than a window (catching up after a stall, a late join) goes out one
			// window per broadcast in turn, so it streams at a window per tick instead of a window
			// per round trip.
			backlog := min(relay.finalized + 1 - first, CATCHUP_TICKS)
			if windows := (backlog + window - 1) / window; windows > 1 {
				relay.rotate[player] = (relay.rotate[player] + 1) % windows
				first += relay.rotate[player] * window
			}
			last = min(relay.finalized, first + window - 1)
		}
		wire.w_u32(writer, first)
		count_at := len(writer.buf)
		wire.w_u8(writer, 0)
		written := 0
		for tick := first; tick <= last; tick += 1 {
			// Ticks with commands are larger: stop at the message limit (every tick alone fits, see
			// tick_command_budget), the rest goes in a later packet.
			if len(writer.buf) + sim.tick_bytes(Input, PLAYERS, sim.log_commands(&relay.log, int(tick - 1))) >
			   MAX_MESSAGE {
				break
			}
			sim.log_write_tick(writer, &relay.log, int(tick - 1))
			written += 1
		}
		writer.buf[count_at] = u8(written)
		relay_send(relay, player, writer, .Unreliable, now)
	}
}

// Tells every connected client which players are connected, with names.
@(private)
send_roster :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) {
	writer := msg_begin(&relay.w, .Roster)
	wire.w_u8(writer, u8(PLAYERS))
	for player in 0 ..< PLAYERS {
		wire.w_u8(writer, u8(relay.connected[player]))
		w_name(writer, &relay.names[player])
	}
	for player in 0 ..< PLAYERS {
		if relay.connected[player] {
			relay_send(relay, player, writer, .Reliable, now)
		}
	}
}

@(private)
player_gone :: proc(relay: ^Relay($Input, $PLAYERS), player: int, why: string, now: i64) {
	relay.connected[player] = false
	relay.welcomed[player] = false
	relay.player_of[relay.peer_of[player]] = -1
	relay.peer_of[player] = -1
	relay.names[player] = {}
	relay.provider[player] = -1
	clear(&relay.cmd_wait[player]) // a left player's commands that never reached a tick go with it
	relay_log(relay, "player %d %s", player, why)
	send_roster(relay, now)
	for other in 0 ..< PLAYERS {
		if relay.provider[other] == player && relay.connected[other] {
			restart_snapshot(relay, other, now)
		}
	}
}

@(private)
handle_relay_msg :: proc(relay: ^Relay($Input, $PLAYERS), peer: Peer, data: []u8, now: i64) {
	reader := wire.reader_make(data)
	kind := Msg(wire.r_u8(&reader))
	if kind == .Hello {
		on_hello(relay, peer, &reader, now)
		return
	}
	player := relay.player_of[peer]
	if player < 0 {
		return
	}
	#partial switch kind {
	case .Inputs:
		if int(wire.r_u8(&reader)) == player {
			on_inputs(relay, player, &reader, now)
		}
	case .Checksum:
		on_checksum(relay, player, &reader)
	case .Snap_Begin, .Snap_Chunk:
		forward_snapshot(relay, player, kind, &reader, data, now)
	case .Done:
		relay.done[player] = true
	case .Leave:
		player_gone(relay, player, "left", now)
		channel_drop(relay.ch, peer)
	}
}

// Forwards a snapshot message from the provider the relay asked (anything else is dropped).
@(private)
forward_snapshot :: proc(
	relay: ^Relay($Input, $PLAYERS),
	player: int,
	kind: Msg,
	reader: ^wire.Reader,
	data: []u8,
	now: i64,
) {
	joiner := int(wire.r_u8(reader))
	if !reader.ok ||
	   joiner >= PLAYERS ||
	   relay.peer_of[joiner] < 0 ||
	   relay.provider[joiner] != player ||
	   len(data) > MAX_MESSAGE {
		return
	}
	if kind == .Snap_Begin {
		tick := wire.r_u32(reader)
		total := wire.r_u32(reader)
		if !reader.ok || tick < relay.snap_min[joiner] || tick > relay.finalized || total == 0 {
			return
		}
		relay.snap_total[joiner] = total
		relay.snap_sent[joiner] = 0
		// Stream finalized ticks from the snapshot's tick on (that tick's inputs seed the joiner's
		// prediction of the others).
		relay.client_ack[joiner] = tick - 1
		relay.base_known[joiner] = true
		relay_log(relay, "forwarding player %d's snapshot of tick %d to player %d", player, tick, joiner)
	} else {
		offset := wire.r_u32(reader)
		size := u32(len(reader.data) - reader.pos)
		if !reader.ok ||
		   relay.snap_total[joiner] == 0 ||
		   offset != relay.snap_sent[joiner] ||
		   size > relay.snap_total[joiner] - offset {
			return
		}
		relay.snap_sent[joiner] += size
		if relay.snap_sent[joiner] == relay.snap_total[joiner] {
			relay.provider[joiner] = -1 // complete: the joiner no longer depends on the provider
		}
	}
	channel_send(relay.ch, relay.peer_of[joiner], data, .Reliable, now)
}

// One step of the relay: receive, advance the clock, finalize, broadcast, flush. Returns when it
// wants to run next (a now_us value): the next clock tick, or sooner to poll the links.
relay_step :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) -> (wake_us: i64) {
	for event in channel_poll(relay.ch, now) {
		switch event.kind {
		case .Connected:
		case .Disconnected:
			if player := relay.player_of[event.peer]; player >= 0 {
				player_gone(relay, player, "disconnected", now)
			}
		case .Message:
			handle_relay_msg(relay, event.peer, event.data, now)
		}
	}
	if relay.started && !relay.finished {
		relay.clock = u32(f64(now - relay.start_us) / relay.tm.tick_us)
		sync.atomic_store(&relay.clock_pub, relay.clock)
		finalized_before := relay.finalized
		finalize(relay)
		if relay.clock != relay.sent_clock || relay.finalized != finalized_before {
			broadcast(relay, now)
			relay.sent_clock = relay.clock
		}
	}
	if !relay.ending && relay.started && relay.cfg.ticks != 0 && relay.finalized == relay.cfg.ticks {
		all_done := true
		for player in 0 ..< PLAYERS {
			if relay.welcomed[player] && relay.connected[player] && !relay.done[player] {
				all_done = false
			}
		}
		if all_done {
			relay_stop(relay, now)
		}
	}
	channel_flush(relay.ch, now)
	if relay.ending && !relay.finished {
		idle := true
		for player in 0 ..< PLAYERS {
			if relay.peer_of[player] >= 0 && !channel_idle(relay.ch, relay.peer_of[player]) {
				idle = false
			}
		}
		relay.finished = idle || now - relay.end_us > 3_000_000
	}
	wake_us = now + relay.cfg.poll_us
	if relay.started {
		wake_us = min(wake_us, relay.start_us + i64(f64(relay.clock + 1) * relay.tm.tick_us) + 1)
	}
	return
}
