// The input relay (CORE.md §2). No game logic: it owns the 60 Hz tick clock,
// collects inputs stamped with their target tick, finalizes tick T once every connected active
// player's input for T is in or the clock reaches T + tolerance (a missing input becomes the
// player's last finalized one, flagged "replaced"), broadcasts finalized ticks unreliably with
// every unacknowledged tick resent (up to 32), keeps the official input log, routes late-join
// snapshots and compares the clients' checksums.
package netcode

import "core:fmt"
import "core:sync"

import "../game"
import "../sim"
import "../wire"

Relay_Config :: struct {
	ticks:         u32,
	seed:          u32,
	start_players: int, // slots 0..start_players-1 must connect before the clock starts
	timeout_s:     f64,
	name:          string, // for log lines
}

Check :: struct {
	value:    u64,
	set:      bool,
	mismatch: bool,
}

Relay :: struct {
	cfg:         Relay_Config,
	ch:          ^Channel,
	started:     bool,
	start_us:    i64,
	clock:       u32,
	clock_pub:   u32, // clock, readable from other threads (atomic)
	finalized:   u32,
	peer_of:     [game.MAX_PLAYERS]Peer,
	player_of:   [MAX_PEERS]int,
	welcomed:    [game.MAX_PLAYERS]bool,
	connected:   [game.MAX_PLAYERS]bool,
	done:        [game.MAX_PLAYERS]bool,
	base_known:  [game.MAX_PLAYERS]bool, // finalized ticks can be streamed to this client
	active_from: [game.MAX_PLAYERS]u32, // first tick the player is active (0: not joined)
	inputs:      [game.MAX_PLAYERS][]game.Input,
	have:        [game.MAX_PLAYERS][]bool,
	recv_upto:   [game.MAX_PLAYERS]u32,
	client_ack:  [game.MAX_PLAYERS]u32,
	echo_time:   [game.MAX_PLAYERS]i64,
	echo_recv:   [game.MAX_PLAYERS]i64,
	sent_clock:  u32,
	sent_final:  u32,
	log:         sim.Input_Log,
	checks:      []Check,
	desyncs:     int,
	replaced:    int,
	join_tick:   [game.MAX_PLAYERS]u32,
	ok:          bool,
	end_us:      i64,
}

relay_create :: proc(cfg: Relay_Config, link: Link) -> ^Relay {
	r := new(Relay)
	r.cfg = cfg
	r.ch = channel_make(link)
	for p in 0 ..< game.MAX_PLAYERS {
		r.peer_of[p] = -1
		r.inputs[p] = make([]game.Input, cfg.ticks + 2)
		r.have[p] = make([]bool, cfg.ticks + 2)
	}
	for &p in r.player_of {
		p = -1
	}
	r.log = {
		seed    = u64(cfg.seed),
		players = u8(cfg.start_players),
	}
	r.checks = make([]Check, cfg.ticks / CHECKSUM_EVERY + 1)
	return r
}

relay_destroy :: proc(r: ^Relay) {
	channel_destroy(r.ch)
	for p in 0 ..< game.MAX_PLAYERS {
		delete(r.inputs[p])
		delete(r.have[p])
	}
	delete(r.log.ticks)
	delete(r.checks)
	free(r)
}

relay_clock :: proc(r: ^Relay) -> u32 {
	return sync.atomic_load(&r.clock_pub)
}

@(private)
relay_send :: proc(r: ^Relay, p: int, w: ^wire.Writer, d: Delivery) {
	if r.peer_of[p] >= 0 {
		channel_send(r.ch, r.peer_of[p], w.buf[:], d)
	}
}

@(private)
send_welcome :: proc(r: ^Relay, p: int) {
	w := msg_begin(.Welcome)
	wire.w_u8(&w, u8(p))
	wire.w_u32(&w, r.cfg.seed)
	wire.w_u8(&w, u8(r.cfg.start_players))
	wire.w_u32(&w, r.cfg.ticks)
	wire.w_u32(&w, r.active_from[p])
	relay_send(r, p, &w, .Reliable)
	r.welcomed[p] = true
}

@(private)
on_hello :: proc(r: ^Relay, peer: Peer, rd: ^wire.Reader, now: i64) {
	p := int(wire.r_u8(rd))
	join := wire.r_u32(rd)
	if !rd.ok || p >= game.MAX_PLAYERS || r.connected[p] {
		return
	}
	r.peer_of[p] = peer
	r.player_of[peer] = p
	r.connected[p] = true
	if !r.started {
		if p >= r.cfg.start_players {
			fmt.eprintfln("%s: player %d connected before the start but is not a starting player", r.cfg.name, p)
			return
		}
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
			send_welcome(r, q)
		}
		fmt.eprintfln("%s: %d players connected, clock started", r.cfg.name, r.cfg.start_players)
		return
	}
	// Late join or reconnect: the slot becomes active at a future tick J.
	j := max(join, r.clock + 30, r.finalized + 2)
	r.active_from[p] = j
	r.recv_upto[p] = j - 1
	r.join_tick[p] = j
	send_welcome(r, p)
	provider := -1
	for q in 0 ..< game.MAX_PLAYERS {
		if q != p && r.connected[q] && r.welcomed[q] && r.base_known[q] {
			provider = q
			break
		}
	}
	fmt.eprintfln(
		"%s: player %d joins at tick %d (clock %d), snapshot from player %d",
		r.cfg.name,
		p,
		j,
		r.clock,
		provider,
	)
	if provider >= 0 {
		w := msg_begin(.Snap_Request)
		wire.w_u8(&w, u8(p))
		wire.w_u32(&w, j - 1)
		relay_send(r, provider, &w, .Reliable)
	}
}

@(private)
on_inputs :: proc(r: ^Relay, p: int, rd: ^wire.Reader, now: i64) {
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
		in_ := r_input(rd)
		t := first + k
		if !rd.ok || t <= r.finalized || t > r.cfg.ticks || t < r.active_from[p] || r.have[p][t] {
			continue // late inputs for finalized ticks are dropped; the first copy of a tick wins
		}
		r.inputs[p][t] = in_
		r.have[p][t] = true
	}
	for r.recv_upto[p] < r.cfg.ticks && r.have[p][r.recv_upto[p] + 1] {
		r.recv_upto[p] += 1
	}
}

@(private)
on_checksum :: proc(r: ^Relay, rd: ^wire.Reader) {
	p := int(wire.r_u8(rd))
	tick := wire.r_u32(rd)
	value := wire.r_u64(rd)
	if !rd.ok || tick % CHECKSUM_EVERY != 0 || int(tick / CHECKSUM_EVERY) >= len(r.checks) {
		return
	}
	c := &r.checks[tick / CHECKSUM_EVERY]
	if !c.set {
		c.value = value
		c.set = true
	} else if c.value != value && !c.mismatch {
		c.mismatch = true
		r.desyncs += 1
		fmt.eprintfln(
			"%s: DESYNC at tick %d: player %d has %016x, another player %016x",
			r.cfg.name,
			tick,
			p,
			value,
			c.value,
		)
	}
}

@(private)
active :: proc(r: ^Relay, p: int, t: u32) -> bool {
	return r.active_from[p] != 0 && t >= r.active_from[p] && r.connected[p]
}

@(private)
finalize :: proc(r: ^Relay) {
	for r.finalized < r.cfg.ticks {
		t := r.finalized + 1
		for p in 0 ..< game.MAX_PLAYERS {
			if active(r, p, t) && !r.have[p][t] && r.clock < t + TOLERANCE {
				return
			}
		}
		lt: sim.Log_Tick
		for p in 0 ..< game.MAX_PLAYERS {
			switch {
			case !active(r, p, t):
				lt.inputs[p] = game.ABSENT_INPUT
			case r.have[p][t]:
				lt.inputs[p] = r.inputs[p][t]
			case:
				last: game.Input
				if t > 1 {
					last = r.log.ticks[t - 2].inputs[p]
				}
				if last.buttons & game.BUTTON_ABSENT != 0 {
					last = {} // just joined: there is no previous input to repeat
				}
				lt.inputs[p] = last
				lt.replaced |= 1 << u8(p)
				r.replaced += 1
			}
		}
		append(&r.log.ticks, lt)
		r.finalized = t
	}
}

@(private)
broadcast :: proc(r: ^Relay, now: i64) {
	for p in 0 ..< game.MAX_PLAYERS {
		if !r.welcomed[p] || !r.connected[p] {
			continue
		}
		w := msg_begin(.Finalized)
		w_i64(&w, now - r.start_us)
		w_i64(&w, r.echo_time[p])
		w_i64(&w, r.echo_time[p] != 0 ? now - r.echo_recv[p] : 0)
		wire.w_u32(&w, max(r.recv_upto[p], r.finalized))
		first := r.client_ack[p] + 1
		last := first - 1
		if r.base_known[p] {
			last = min(r.finalized, first + WINDOW_MAX - 1)
		}
		wire.w_u32(&w, first)
		wire.w_u8(&w, u8(last + 1 - first))
		for t := first; t <= last; t += 1 {
			lt := &r.log.ticks[t - 1]
			for in_ in lt.inputs {
				w_input(&w, in_)
			}
			wire.w_u8(&w, lt.replaced)
		}
		relay_send(r, p, &w, .Unreliable)
	}
}

// Runs the relay until every client has verified the last tick (or the timeout). Returns ok.
relay_run :: proc(r: ^Relay) -> bool {
	sw := Stopwatch {
		start = now_tick(),
	}
	ending := false
	for {
		now := now_us()
		for ev in channel_poll(r.ch) {
			switch ev.kind {
			case .Connected:
			case .Disconnected:
				if p := r.player_of[ev.peer]; p >= 0 {
					r.connected[p] = false
					r.player_of[ev.peer] = -1
					r.peer_of[p] = -1
					fmt.eprintfln("%s: player %d disconnected", r.cfg.name, p)
				}
			case .Message:
				handle_relay_msg(r, ev.peer, ev.data, now)
			}
		}
		if r.started {
			r.clock = u32((now - r.start_us) / TICK_US)
			sync.atomic_store(&r.clock_pub, r.clock)
			prev := r.finalized
			finalize(r)
			if r.clock != r.sent_clock || r.finalized != prev {
				broadcast(r, now)
				r.sent_clock = r.clock
			}
		}
		if !ending && r.started && r.finalized == r.cfg.ticks {
			all_done := true
			for p in 0 ..< game.MAX_PLAYERS {
				if r.welcomed[p] && r.connected[p] && !r.done[p] {
					all_done = false
				}
			}
			if all_done {
				ending = true
				r.end_us = now
				for p in 0 ..< game.MAX_PLAYERS {
					if r.welcomed[p] && r.connected[p] {
						w := msg_begin(.End)
						relay_send(r, p, &w, .Reliable)
					}
				}
			}
		}
		channel_flush(r.ch)
		free_all(context.temp_allocator)
		if ending {
			idle := true
			for p in 0 ..< game.MAX_PLAYERS {
				if r.peer_of[p] >= 0 && !channel_idle(r.ch, r.peer_of[p]) {
					idle = false
				}
			}
			if idle || now - r.end_us > 3_000_000 {
				r.ok = true
				return true
			}
		}
		if elapsed_s(sw) > r.cfg.timeout_s {
			fmt.eprintfln("%s: timeout (clock %d, finalized %d, done %v)", r.cfg.name, r.clock, r.finalized, r.done)
			return false
		}
		sleep_ms(1)
	}
}

@(private)
handle_relay_msg :: proc(r: ^Relay, peer: Peer, data: []u8, now: i64) {
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
		on_checksum(r, &rd)
	case .Snap_Begin, .Snap_Chunk:
		joiner := int(wire.r_u8(&rd))
		if !rd.ok || joiner >= game.MAX_PLAYERS || r.peer_of[joiner] < 0 {
			return
		}
		if kind == .Snap_Begin {
			tick := wire.r_u32(&rd)
			// Stream finalized ticks from the snapshot's tick on (that tick's inputs seed the
			// joiner's prediction of the others).
			r.client_ack[joiner] = max(tick, 1) - 1
			r.base_known[joiner] = true
			fmt.eprintfln("%s: forwarding player %d's snapshot of tick %d to player %d", r.cfg.name, p, tick, joiner)
		}
		channel_send(r.ch, r.peer_of[joiner], data, .Reliable)
	case .Done:
		r.done[p] = true
	}
}
