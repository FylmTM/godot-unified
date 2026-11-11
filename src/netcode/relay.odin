// The input relay (src/netcode/SPEC.md), generic over the game's input type I and slot count P. No game
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
	start_players: int, // slots 0..start_players-1 must connect before the clock starts (>= 1)
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
	cmd:  sim.Command,
}

@(private)
Check :: struct {
	tick:     u32,
	value:    u64,
	mismatch: bool,
}

Relay :: struct($I: typeid, $P: int) {
	cfg:         Relay_Config,
	tm:          Timing,
	ch:          ^Channel,
	w:           wire.Writer,
	started:     bool,
	start_us:    i64,
	clock:       u32,
	clock_pub:   u32, // clock, readable from other threads (atomic)
	finalized:   u32,
	peer_of:     [P]Peer,
	player_of:   [MAX_PEERS]int,
	welcomed:    [P]bool,
	names:       [P]Player_Name,
	connected:   [P]bool,
	done:        [P]bool,
	base_known:  [P]bool, // finalized ticks can be streamed to this client
	active_from: [P]u32, // first tick the player is present (0: not joined)
	provider:    [P]int, // who sends this joiner its snapshot (-1: none pending)
	snap_min:    [P]u32, // the oldest tick the joiner's snapshot may be of
	snap_total:  [P]u32, // bytes of the snapshot being forwarded (from its Snap_Begin)
	snap_sent:   [P]u32, // bytes forwarded so far
	inputs:      [P][INPUT_RING]I,
	input_tick:  [P][INPUT_RING]u32, // which tick inputs[p][k] holds
	recv_upto:   [P]u32,
	client_ack:  [P]u32,
	cmd_recv:    [P]u32, // the command ack: every seq up to this one is received
	cmd_wait:    [P][dynamic]Wait_Command, // received, not finalized yet, in seq order
	rotate:      [P]u32, // which window of a long backlog the next broadcast carries
	echo_time:   [P]i64,
	echo_recv:   [P]i64,
	sent_clock:  u32,
	log:         sim.Input_Log(I, P),
	checks:      [CHECK_RING]Check,
	desyncs:     int,
	replaced:    int,
	ending:      bool,
	end_us:      i64,
	finished:    bool,
}

relay_create :: proc(cfg: Relay_Config, $I: typeid, $P: int) -> ^Relay(I, P) {
	sim.check_plain(I)
	_ = tick_command_budget(I, P) // asserts a tick with a command fits a datagram
	assert(cfg.start_players >= 1 && cfg.start_players <= P)
	r := new(Relay(I, P))
	r.cfg = cfg
	if r.cfg.poll_us <= 0 {
		r.cfg.poll_us = DEFAULT_POLL_US
	}
	r.tm = timing_of(cfg.tick_hz)
	r.ch = channel_make()
	r.w = wire.writer_make(MAX_DATAGRAM)
	for p in 0 ..< P {
		r.peer_of[p] = -1
		r.provider[p] = -1
	}
	for &p in r.player_of {
		p = -1
	}
	r.log.seed = cfg.seed
	r.log.content = cfg.content
	return r
}

relay_destroy :: proc(r: ^Relay($I, $P)) {
	channel_destroy(r.ch)
	delete(r.w.buf)
	sim.log_destroy(&r.log)
	for &q in r.cmd_wait {
		delete(q)
	}
	free(r)
}

// Adds a transport; the relay owns it from now on. Peers on every link are served alike.
relay_add_link :: proc(r: ^Relay($I, $P), link: Link) -> int {
	return channel_add_link(r.ch, link)
}

// The relay's tick clock, readable from any thread.
relay_clock :: proc(r: ^Relay($I, $P)) -> u32 {
	return sync.atomic_load(&r.clock_pub)
}

// Ends the session: every connected client gets End; the relay is finished once they acked it
// (or after 3 s). Keep stepping until relay_finished.
relay_stop :: proc(r: ^Relay($I, $P), now: i64) {
	if r.ending {
		return
	}
	for p in 0 ..< P {
		if r.connected[p] {
			relay_send(r, p, msg_begin(&r.w, .End), .Reliable, now)
		}
	}
	r.ending = true
	r.end_us = now
}

relay_finished :: proc(r: ^Relay($I, $P)) -> bool {
	return r.finished
}

@(private)
relay_log :: proc(r: ^Relay($I, $P), format: string, args: ..any) {
	if !r.cfg.quiet {
		fmt.eprintf("%s: ", r.cfg.name)
		fmt.eprintfln(format, ..args)
	}
}

@(private)
relay_send :: proc(r: ^Relay($I, $P), p: int, w: ^wire.Writer, d: Delivery, now: i64) {
	if r.peer_of[p] >= 0 {
		channel_send(r.ch, r.peer_of[p], w.buf[:], d, now)
	}
}

@(private)
send_welcome :: proc(r: ^Relay($I, $P), p: int, from_start: bool, now: i64) {
	w := msg_begin(&r.w, .Welcome)
	wire.w_u8(w, u8(p))
	wire.w_u64(w, r.cfg.seed)
	wire.w_u16(w, u16(r.cfg.tick_hz))
	wire.w_u32(w, r.cfg.ticks)
	wire.w_u32(w, r.active_from[p])
	wire.w_u8(w, u8(from_start))
	relay_send(r, p, w, .Reliable, now)
	r.welcomed[p] = true
}

@(private)
reject :: proc(r: ^Relay($I, $P), peer: Peer, why: Reject_Reason, now: i64) {
	w := msg_begin(&r.w, .Reject)
	wire.w_u8(w, u8(why))
	channel_send(r.ch, peer, w.buf[:], .Reliable, now)
}

@(private)
on_hello :: proc(r: ^Relay($I, $P), peer: Peer, rd: ^wire.Reader, now: i64) {
	proto := wire.r_u16(rd)
	want := wire.r_u8(rd)
	join := wire.r_u32(rd)
	compat := wire.r_u64(rd)
	name := r_name(rd)
	if !rd.ok || r.player_of[peer] >= 0 || r.ending {
		return
	}
	if proto != PROTOCOL_VERSION || (r.cfg.compat != 0 && compat != r.cfg.compat) {
		reject(r, peer, .Incompatible, now)
		return
	}
	p := -1
	if want == ANY_SLOT {
		limit := r.started ? P : r.cfg.start_players
		for q in 0 ..< limit {
			if !r.connected[q] {
				p = q
				break
			}
		}
		if p < 0 {
			reject(r, peer, .Full, now)
			return
		}
	} else {
		p = int(want)
		if p >= P {
			reject(r, peer, .Full, now)
			return
		}
		if r.connected[p] {
			reject(r, peer, .Slot_Taken, now)
			return
		}
		if !r.started && p >= r.cfg.start_players {
			reject(r, peer, .Not_Started, now)
			return
		}
	}
	r.peer_of[p] = peer
	r.player_of[peer] = p
	r.connected[p] = true
	r.done[p] = false
	r.names[p] = name
	r.cmd_recv[p] = 0 // a new client numbers its commands from 1
	clear(&r.cmd_wait[p])
	send_roster(r, now)
	if !r.started {
		r.active_from[p] = 1
		r.base_known[p] = true
		for q in 0 ..< r.cfg.start_players {
			if !r.connected[q] {
				return
			}
		}
		r.started = true
		r.start_us = now
		for q in 0 ..< r.cfg.start_players {
			send_welcome(r, q, false, now)
		}
		relay_log(r, "%d players connected, clock started", r.cfg.start_players)
		return
	}
	// Late join or rejoin: the slot becomes present at a future tick J.
	j := max(join, r.clock + ceil_ticks(JOIN_LEAD_MS * 1000, r.tm.tick_us), r.finalized + 2)
	r.active_from[p] = j
	r.recv_upto[p] = j - 1
	r.base_known[p] = false
	r.client_ack[p] = 0
	r.snap_min[p] = j - 1
	if provider := pick_provider(r, p); provider >= 0 {
		send_welcome(r, p, false, now)
		request_snapshot(r, p, provider, now)
		relay_log(r, "player %d joins at tick %d (clock %d), snapshot from player %d", p, j, r.clock, provider)
	} else {
		// Nobody can send a snapshot: the joiner starts from tick 0 and replays the whole log.
		r.base_known[p] = true
		send_welcome(r, p, true, now)
		relay_log(r, "player %d joins at tick %d (clock %d), replaying from tick 1", p, j, r.clock)
	}
}

// The lowest connected player that can send `joiner` a snapshot (-1: none).
@(private)
pick_provider :: proc(r: ^Relay($I, $P), joiner: int) -> int {
	for q in 0 ..< P {
		if q != joiner && r.connected[q] && r.welcomed[q] && r.base_known[q] && r.provider[q] < 0 {
			return q
		}
	}
	return -1
}

@(private)
request_snapshot :: proc(r: ^Relay($I, $P), joiner, provider: int, now: i64) {
	r.provider[joiner] = provider
	r.snap_total[joiner] = 0
	r.snap_sent[joiner] = 0
	w := msg_begin(&r.w, .Snap_Request)
	wire.w_u8(w, u8(joiner))
	wire.w_u32(w, r.snap_min[joiner])
	relay_send(r, provider, w, .Reliable, now)
}

// The provider of `joiner`'s snapshot left before the snapshot got through: ask another player, or
// tell the joiner to start from tick 0 and replay the log (an empty Snap_Begin).
@(private)
restart_snapshot :: proc(r: ^Relay($I, $P), joiner: int, now: i64) {
	r.provider[joiner] = -1
	r.base_known[joiner] = false
	r.client_ack[joiner] = 0
	if provider := pick_provider(r, joiner); provider >= 0 {
		request_snapshot(r, joiner, provider, now)
		relay_log(r, "player %d: snapshot provider left, asking player %d", joiner, provider)
		return
	}
	w := msg_begin(&r.w, .Snap_Begin)
	wire.w_u8(w, u8(joiner))
	wire.w_u32(w, 0)
	wire.w_u32(w, 0)
	relay_send(r, joiner, w, .Reliable, now)
	r.base_known[joiner] = true
	relay_log(r, "player %d: snapshot provider left, replaying from tick 1", joiner)
}

@(private)
have_input :: #force_inline proc(r: ^Relay($I, $P), p: int, t: u32) -> bool {
	return r.input_tick[p][t % INPUT_RING] == t
}

@(private)
on_inputs :: proc(r: ^Relay($I, $P), p: int, rd: ^wire.Reader, now: i64) {
	ctime := r_i64(rd)
	fin_ack := wire.r_u32(rd)
	first := wire.r_u32(rd)
	count := u32(wire.r_u8(rd))
	if !rd.ok {
		return
	}
	r.echo_time[p] = ctime
	r.echo_recv[p] = now
	if r.base_known[p] {
		r.client_ack[p] = max(r.client_ack[p], min(fin_ack, r.finalized))
	}
	for k in 0 ..< count {
		in_ := r_raw(rd, I)
		t := first + k
		if !rd.ok ||
		   t <= r.finalized ||
		   t >= r.finalized + INPUT_RING ||
		   (r.cfg.ticks != 0 && t > r.cfg.ticks) ||
		   t < r.active_from[p] ||
		   have_input(r, p, t) {
			continue // late inputs for finalized ticks are dropped; the first copy of a tick wins
		}
		r.inputs[p][t % INPUT_RING] = in_
		r.input_tick[p][t % INPUT_RING] = t
	}
	for have_input(r, p, r.recv_upto[p] + 1) {
		r.recv_upto[p] += 1
	}
	// Commands: the sender's unacked ones, from `first_seq` on. Each seq is taken once, in order; one the
	// relay already has (a resend, a duplicate) is skipped.
	first_seq := wire.r_u32(rd)
	ncmd := u32(wire.r_u8(rd))
	for k in 0 ..< ncmd {
		want := wire.r_u32(rd)
		kind := wire.r_u8(rd)
		size := int(wire.r_u8(rd))
		bytes := wire.r_bytes(rd, size)
		if !rd.ok || size > sim.COMMAND_MAX || size == 0 {
			return
		}
		seq := first_seq + k
		if seq <= r.cmd_recv[p] {
			continue
		}
		if seq != r.cmd_recv[p] + 1 || len(r.cmd_wait[p]) >= COMMAND_QUEUE {
			return // a gap (never from an honest client) or a flood: the rest comes again
		}
		wc := Wait_Command {
			// a wanted tick far ahead would hold back the sender's later commands: clamp it
			want = min(want, r.finalized + INPUT_RING),
			cmd = {kind = kind, slot = u8(p), size = u8(size)},
		}
		copy(wc.cmd.data[:], bytes)
		append(&r.cmd_wait[p], wc)
		r.cmd_recv[p] = seq
	}
}

@(private)
on_checksum :: proc(r: ^Relay($I, $P), p: int, rd: ^wire.Reader) {
	_ = wire.r_u8(rd) // the sender's slot; the relay knows it
	tick := wire.r_u32(rd)
	value := wire.r_u64(rd)
	if !rd.ok || tick % CHECKSUM_EVERY != 0 || tick == 0 {
		return
	}
	c := &r.checks[(tick / CHECKSUM_EVERY) % CHECK_RING]
	if c.tick != tick {
		c^ = {
			tick  = tick,
			value = value,
		}
	} else if c.value != value && !c.mismatch {
		c.mismatch = true
		r.desyncs += 1
		relay_log(r, "DESYNC at tick %d: player %d has %016x, another player %016x", tick, p, value, c.value)
	}
}

@(private)
active :: proc(r: ^Relay($I, $P), p: int, t: u32) -> bool {
	return r.active_from[p] != 0 && t >= r.active_from[p] && r.connected[p]
}

@(private)
finalize :: proc(r: ^Relay($I, $P)) {
	for r.cfg.ticks == 0 || r.finalized < r.cfg.ticks {
		t := r.finalized + 1
		anyone := false
		for p in 0 ..< P {
			if !active(r, p, t) {
				continue
			}
			anyone = true
			if !have_input(r, p, t) && r.clock < t + r.tm.tolerance {
				return
			}
		}
		if !anyone && t > r.clock {
			return // nobody plays: empty ticks keep pace with the clock, never run ahead of it
		}
		lt: sim.Inputs(I, P)
		for p in 0 ..< P {
			if !active(r, p, t) {
				continue
			}
			lt.present += {p}
			if have_input(r, p, t) {
				lt.input[p] = r.inputs[p][t % INPUT_RING]
			} else {
				if t > 1 && p in r.log.ticks[t - 2].present {
					lt.input[p] = r.log.ticks[t - 2].input[p]
				} // else just joined: there is no previous input to repeat
				lt.replaced += {p}
				r.replaced += 1
			}
		}
		take_commands(r, t, &lt)
		sim.log_append(&r.log, &lt)
		r.finalized = t
	}
}

// Puts the waiting commands that are due into tick t: each present player's in seq order, those sent for
// t or earlier, at most COMMANDS_PER_PLAYER each and TICK_COMMANDS in all, within the bytes a tick may
// carry (round-robin over the players, so one can't crowd the others out). The rest wait for t + 1.
@(private)
take_commands :: proc(r: ^Relay($I, $P), t: u32, lt: ^sim.Inputs(I, P)) {
	taken: [P]int
	total, bytes := 0, 0
	budget := tick_command_budget(I, P)
	for k in 0 ..< sim.COMMANDS_PER_PLAYER {
		for p in 0 ..< P {
			q := &r.cmd_wait[p]
			if taken[p] != k || k >= len(q) || !active(r, p, t) || q[k].want > t {
				continue
			}
			size := sim.COMMAND_HEAD + int(q[k].cmd.size)
			if total == sim.TICK_COMMANDS || bytes + size > budget {
				continue
			}
			taken[p] += 1
			total += 1
			bytes += size
		}
	}
	if total == 0 {
		return
	}
	for p in 0 ..< P {
		q := &r.cmd_wait[p]
		for k in 0 ..< taken[p] {
			lt.commands[lt.n_commands] = q[k].cmd
			lt.n_commands += 1
		}
		remove_range(q, 0, taken[p])
	}
}

@(private)
broadcast :: proc(r: ^Relay($I, $P), now: i64) {
	window := finalized_window(I, P)
	for p in 0 ..< P {
		if !r.welcomed[p] || !r.connected[p] {
			continue
		}
		w := msg_begin(&r.w, .Finalized)
		w_i64(w, now - r.start_us)
		w_i64(w, r.echo_time[p])
		w_i64(w, r.echo_time[p] != 0 ? now - r.echo_recv[p] : 0)
		wire.w_u32(w, max(r.recv_upto[p], r.finalized))
		wire.w_u32(w, r.cmd_recv[p])
		first := r.client_ack[p] + 1
		last := first - 1
		if r.base_known[p] {
			// A backlog longer than a window (catching up after a stall, a late join) goes out one
			// window per broadcast in turn, so it streams at a window per tick instead of a window
			// per round trip.
			backlog := min(r.finalized + 1 - first, CATCHUP_TICKS)
			if windows := (backlog + window - 1) / window; windows > 1 {
				r.rotate[p] = (r.rotate[p] + 1) % windows
				first += r.rotate[p] * window
			}
			last = min(r.finalized, first + window - 1)
		}
		wire.w_u32(w, first)
		count_at := len(w.buf)
		wire.w_u8(w, 0)
		n := 0
		for t := first; t <= last; t += 1 {
			// Ticks with commands are larger: stop at the message limit (every tick alone fits, see
			// tick_command_budget), the rest goes in a later packet.
			if len(w.buf) + sim.tick_bytes(I, P, sim.log_commands(&r.log, int(t - 1))) > MAX_MESSAGE {
				break
			}
			sim.log_write_tick(w, &r.log, int(t - 1))
			n += 1
		}
		w.buf[count_at] = u8(n)
		relay_send(r, p, w, .Unreliable, now)
	}
}

// Tells every connected client who is in which slot, with names.
@(private)
send_roster :: proc(r: ^Relay($I, $P), now: i64) {
	w := msg_begin(&r.w, .Roster)
	wire.w_u8(w, u8(P))
	for p in 0 ..< P {
		wire.w_u8(w, u8(r.connected[p]))
		w_name(w, &r.names[p])
	}
	for p in 0 ..< P {
		if r.connected[p] {
			relay_send(r, p, w, .Reliable, now)
		}
	}
}

@(private)
player_gone :: proc(r: ^Relay($I, $P), p: int, why: string, now: i64) {
	r.connected[p] = false
	r.welcomed[p] = false
	r.player_of[r.peer_of[p]] = -1
	r.peer_of[p] = -1
	r.names[p] = {}
	r.provider[p] = -1
	clear(&r.cmd_wait[p]) // a left player's commands that never reached a tick go with it
	relay_log(r, "player %d %s", p, why)
	send_roster(r, now)
	for q in 0 ..< P {
		if r.provider[q] == p && r.connected[q] {
			restart_snapshot(r, q, now)
		}
	}
}

@(private)
handle_relay_msg :: proc(r: ^Relay($I, $P), peer: Peer, data: []u8, now: i64) {
	rd := wire.reader_make(data)
	kind := Msg(wire.r_u8(&rd))
	if kind == .Hello {
		on_hello(r, peer, &rd, now)
		return
	}
	p := r.player_of[peer]
	if p < 0 {
		return
	}
	#partial switch kind {
	case .Inputs:
		if int(wire.r_u8(&rd)) == p {
			on_inputs(r, p, &rd, now)
		}
	case .Checksum:
		on_checksum(r, p, &rd)
	case .Snap_Begin, .Snap_Chunk:
		forward_snapshot(r, p, kind, &rd, data, now)
	case .Done:
		r.done[p] = true
	case .Leave:
		player_gone(r, p, "left", now)
		channel_drop(r.ch, peer)
	}
}

// Forwards a snapshot message from the provider the relay asked (anything else is dropped).
@(private)
forward_snapshot :: proc(r: ^Relay($I, $P), p: int, kind: Msg, rd: ^wire.Reader, data: []u8, now: i64) {
	joiner := int(wire.r_u8(rd))
	if !rd.ok || joiner >= P || r.peer_of[joiner] < 0 || r.provider[joiner] != p || len(data) > MAX_MESSAGE {
		return
	}
	if kind == .Snap_Begin {
		tick := wire.r_u32(rd)
		total := wire.r_u32(rd)
		if !rd.ok || tick < r.snap_min[joiner] || tick > r.finalized || total == 0 {
			return
		}
		r.snap_total[joiner] = total
		r.snap_sent[joiner] = 0
		// Stream finalized ticks from the snapshot's tick on (that tick's inputs seed the joiner's
		// prediction of the others).
		r.client_ack[joiner] = tick - 1
		r.base_known[joiner] = true
		relay_log(r, "forwarding player %d's snapshot of tick %d to player %d", p, tick, joiner)
	} else {
		offset := wire.r_u32(rd)
		n := u32(len(rd.data) - rd.pos)
		if !rd.ok || r.snap_total[joiner] == 0 || offset != r.snap_sent[joiner] || n > r.snap_total[joiner] - offset {
			return
		}
		r.snap_sent[joiner] += n
		if r.snap_sent[joiner] == r.snap_total[joiner] {
			r.provider[joiner] = -1 // complete: the joiner no longer depends on the provider
		}
	}
	channel_send(r.ch, r.peer_of[joiner], data, .Reliable, now)
}

// One step of the relay: receive, advance the clock, finalize, broadcast, flush. Returns when it
// wants to run next (a now_us value): the next clock tick, or sooner to poll the links.
relay_step :: proc(r: ^Relay($I, $P), now: i64) -> (wake_us: i64) {
	for ev in channel_poll(r.ch, now) {
		switch ev.kind {
		case .Connected:
		case .Disconnected:
			if p := r.player_of[ev.peer]; p >= 0 {
				player_gone(r, p, "disconnected", now)
			}
		case .Message:
			handle_relay_msg(r, ev.peer, ev.data, now)
		}
	}
	if r.started && !r.finished {
		r.clock = u32(f64(now - r.start_us) / r.tm.tick_us)
		sync.atomic_store(&r.clock_pub, r.clock)
		prev := r.finalized
		finalize(r)
		if r.clock != r.sent_clock || r.finalized != prev {
			broadcast(r, now)
			r.sent_clock = r.clock
		}
	}
	if !r.ending && r.started && r.cfg.ticks != 0 && r.finalized == r.cfg.ticks {
		all_done := true
		for p in 0 ..< P {
			if r.welcomed[p] && r.connected[p] && !r.done[p] {
				all_done = false
			}
		}
		if all_done {
			relay_stop(r, now)
		}
	}
	channel_flush(r.ch, now)
	if r.ending && !r.finished {
		idle := true
		for p in 0 ..< P {
			if r.peer_of[p] >= 0 && !channel_idle(r.ch, r.peer_of[p]) {
				idle = false
			}
		}
		r.finished = idle || now - r.end_us > 3_000_000
	}
	wake_us = now + r.cfg.poll_us
	if r.started {
		wake_us = min(wake_us, r.start_us + i64(f64(r.clock + 1) * r.tm.tick_us) + 1)
	}
	return
}
