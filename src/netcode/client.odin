// The client (CORE.md §2): a verified frame advanced only with finalized inputs, a predicted
// frame up to the local tick (own inputs + the others' last finalized input repeated), rollback
// on misprediction, a 10-tick prediction cap, adaptive input delay and a 2% clock slew towards
// relay tick + delay. Also serves and receives late-join snapshots.
package netcode

import "core:fmt"

import "../game"
import "../sim"
import "../wire"

Client_Config :: struct {
	player:    int,
	join_tick: u32, // late join: the tick asked for in Hello (0: a starting player)
	timeout_s: f64,
	name:      string,
}

PRED_RING :: 64
CHK_RING :: 64

Client :: struct {
	cfg:           Client_Config,
	ch:            ^Channel,
	world:         ^sim.Sim, // nil until welcomed (or, for a late joiner, until the snapshot lands)
	script:        game.Script,
	// from Welcome
	welcomed:      bool,
	seed:          u32,
	start_players: int,
	ticks:         u32,
	first_tick:    u32, // J: first tick this player is active
	// finalized inputs from the relay, indexed by tick
	fin:           []sim.Log_Tick,
	fin_have:      []bool,
	fin_upto:      u32, // highest contiguous finalized tick held
	// frames
	verified:      u32, // V
	predicted:     u32, // P (the sim's current tick)
	local:         u32, // L (scheduler tick)
	pred_inputs:   [PRED_RING]game.Inputs,
	chk:           [CHK_RING]struct {
		tick:  u32,
		value: u64,
	},
	// own inputs, indexed by tick
	own:           []game.Input,
	own_last:      u32,
	own_acked:     u32,
	// time sync
	started:       bool,
	offset_us:     f64, // relay time - local time
	have_offset:   bool,
	rtt_us:        f64,
	rtt_samples:   int,
	delay:         u32,
	delay_eval_us: i64,
	next_tick_us:  f64,
	last_send_us:  i64,
	// late join
	snap_req:      bool,
	snap_joiner:   int,
	snap_min:      u32,
	snap_buf:      [dynamic]u8,
	snap_total:    int,
	snap_tick:     u32,
	// end
	done_sent:     bool,
	end_received:  bool,
	// results
	checksums:     [dynamic][2]u64,
	rollbacks:     int,
	depth_sum:     int,
	depth_max:     int,
	stall_ticks:   int,
	resim_ticks:   int,
	mispredicted:  int,
	delay_changes: int,
	ok:            bool,
	error:         string,
}

client_create :: proc(cfg: Client_Config, link: Link) -> ^Client {
	c := new(Client)
	c.cfg = cfg
	c.ch = channel_make(link)
	c.delay = 1
	return c
}

client_destroy :: proc(c: ^Client) {
	channel_destroy(c.ch)
	if c.world != nil {
		sim.destroy(c.world)
	}
	delete(c.fin)
	delete(c.fin_have)
	delete(c.own)
	delete(c.snap_buf)
	delete(c.checksums)
	free(c)
}

@(private)
csend :: proc(c: ^Client, w: ^wire.Writer, d: Delivery) {
	channel_send(c.ch, RELAY_PEER, w.buf[:], d)
}

@(private)
on_welcome :: proc(c: ^Client, rd: ^wire.Reader) {
	p := int(wire.r_u8(rd))
	seed := wire.r_u32(rd)
	players := int(wire.r_u8(rd))
	ticks := wire.r_u32(rd)
	first := wire.r_u32(rd)
	if !rd.ok || p != c.cfg.player || c.welcomed {
		return
	}
	c.welcomed = true
	c.seed = seed
	c.start_players = players
	c.ticks = ticks
	c.first_tick = first
	c.fin = make([]sim.Log_Tick, ticks + 2)
	c.fin_have = make([]bool, ticks + 2)
	c.own = make([]game.Input, ticks + 2 + 16)
	c.own_last = first - 1
	c.own_acked = first - 1
	c.script = game.script_init(seed, p)
	if first <= 1 {
		c.world = sim.create(seed, players)
	}
}

@(private)
on_finalized :: proc(c: ^Client, rd: ^wire.Reader, now: i64) {
	relay_time := r_i64(rd)
	echo := r_i64(rd)
	hold := r_i64(rd)
	input_ack := wire.r_u32(rd)
	first := wire.r_u32(rd)
	count := u32(wire.r_u8(rd))
	if !rd.ok || !c.welcomed {
		return
	}
	if echo > 0 {
		sample := f64(now - echo - hold)
		if sample > 0 {
			c.rtt_us = c.rtt_samples == 0 ? sample : c.rtt_us + (sample - c.rtt_us) * 0.1
			c.rtt_samples += 1
		}
	}
	if c.rtt_samples > 0 {
		off := f64(relay_time) + c.rtt_us / 2 - f64(now)
		c.offset_us = c.have_offset ? c.offset_us + (off - c.offset_us) * 0.05 : off
		c.have_offset = true
	}
	c.own_acked = max(c.own_acked, input_ack)
	for k in 0 ..< count {
		t := first + k
		lt: sim.Log_Tick
		lt.inputs = sim.read_inputs(rd)
		lt.replaced = wire.r_u8(rd)
		if !rd.ok || t == 0 || t > c.ticks || c.fin_have[t] {
			continue
		}
		c.fin[t] = lt
		c.fin_have[t] = true
	}
	for c.fin_upto < c.ticks && c.fin_have[c.fin_upto + 1] {
		c.fin_upto += 1
	}
}

@(private)
handle_client_msg :: proc(c: ^Client, data: []u8, now: i64) {
	rd := wire.reader_make(data)
	#partial switch Msg(wire.r_u8(&rd)) {
	case .Welcome:
		on_welcome(c, &rd)
	case .Finalized:
		on_finalized(c, &rd, now)
	case .Snap_Request:
		c.snap_joiner = int(wire.r_u8(&rd))
		c.snap_min = wire.r_u32(&rd)
		c.snap_req = rd.ok
	case .Snap_Begin:
		_ = wire.r_u8(&rd)
		c.snap_tick = wire.r_u32(&rd)
		c.snap_total = int(wire.r_u32(&rd))
		clear(&c.snap_buf)
		// Finalized ticks are streamed from the snapshot tick on.
		c.fin_upto = max(c.fin_upto, c.snap_tick - 1)
		for c.fin_upto < c.ticks && c.fin_have[c.fin_upto + 1] {
			c.fin_upto += 1
		}
	case .Snap_Chunk:
		_ = wire.r_u8(&rd)
		offset := int(wire.r_u32(&rd))
		bytes := rd.data[rd.pos:]
		if offset == len(c.snap_buf) {
			append(&c.snap_buf, ..bytes)
		}
		if c.snap_total > 0 && len(c.snap_buf) == c.snap_total && c.world == nil {
			load_snapshot(c)
		}
	case .End:
		c.end_received = true
	}
}

@(private)
load_snapshot :: proc(c: ^Client) {
	c.world = sim.from_snapshot(c.snap_buf[:])
	if c.world == nil {
		c.error = "received snapshot does not restore"
		return
	}
	c.verified = c.world.state.tick
	c.predicted = c.verified
	c.own_last = max(c.own_last, c.verified)
	fmt.eprintfln("%s: restored snapshot of tick %d (%d bytes)", c.cfg.name, c.verified, len(c.snap_buf))
}

// Inputs for predicting tick t: own input, the others' latest finalized input repeated.
@(private)
predicted_inputs :: proc(c: ^Client, t: u32) -> (out: game.Inputs) {
	if c.fin_upto >= 1 && c.fin_have[c.fin_upto] {
		out = c.fin[c.fin_upto].inputs
	} else {
		for &in_ in out {
			in_ = game.ABSENT_INPUT
		}
	}
	if t >= c.first_tick {
		out[c.cfg.player] = c.own[min(t, c.own_last)]
	}
	return
}

@(private)
record_checksum :: proc(c: ^Client) {
	t := c.world.state.tick
	if t % CHECKSUM_EVERY == 0 {
		c.chk[(t / CHECKSUM_EVERY) % CHK_RING] = {t, sim.checksum(c.world)}
	}
}

// Advances the verified frame with newly finalized ticks, rolling back on a misprediction.
@(private)
advance_verified :: proc(c: ^Client) {
	new_v := c.fin_upto
	if c.world == nil || new_v <= c.verified {
		return
	}
	old_v := c.verified
	limit := min(new_v, c.predicted)
	m: u32 = 0
	for t in old_v + 1 ..= limit {
		if c.pred_inputs[t % PRED_RING] != c.fin[t].inputs {
			m = t
			break
		}
	}
	if m != 0 {
		ok := sim.restore(c.world, m - 1)
		assert(ok, "rollback target not in the snapshot ring")
		depth := int(c.predicted - (m - 1))
		c.rollbacks += 1
		c.depth_sum += depth
		c.depth_max = max(c.depth_max, depth)
		for t in m ..= new_v {
			sim.step(c.world, c.fin[t].inputs)
			record_checksum(c)
			c.resim_ticks += 1
		}
		for t in new_v + 1 ..= c.predicted {
			in_ := predicted_inputs(c, t)
			c.pred_inputs[t % PRED_RING] = in_
			sim.step(c.world, in_)
			record_checksum(c)
			c.resim_ticks += 1
		}
		c.predicted = max(c.predicted, new_v)
	} else if new_v > c.predicted {
		for t in c.predicted + 1 ..= new_v {
			sim.step(c.world, c.fin[t].inputs)
			record_checksum(c)
		}
		c.predicted = new_v
	}
	c.verified = new_v
	// Report the checksums of newly verified ticks (every 16th; a joiner from its join tick on).
	first := (old_v / CHECKSUM_EVERY + 1) * CHECKSUM_EVERY
	for t := first; t <= new_v; t += CHECKSUM_EVERY {
		e := c.chk[(t / CHECKSUM_EVERY) % CHK_RING]
		assert(e.tick == t, "missing checksum for a verified tick")
		if t < c.first_tick {
			continue
		}
		append(&c.checksums, [2]u64{u64(t), e.value})
		w := msg_begin(.Checksum)
		wire.w_u8(&w, u8(c.cfg.player))
		wire.w_u32(&w, t)
		wire.w_u64(&w, e.value)
		csend(c, &w, .Reliable)
	}
}

// Generates own inputs up to local + delay. A tick skipped because the delay grew repeats the
// last input; when the delay shrinks, the already-sent input for a tick is kept.
@(private)
generate_inputs :: proc(c: ^Client) {
	target := min(c.local + c.delay, c.ticks)
	first_gen := c.own_last < c.first_tick
	for t := c.own_last + 1; t <= target; t += 1 {
		if t < target && !first_gen {
			c.own[t] = c.own[t - 1]
		} else {
			pending: i32 = 0
			if c.world != nil {
				pending = c.world.state.players[c.cfg.player].pending_levelups
			}
			c.own[t] = game.script_input(&c.script, t, pending)
		}
		c.own_last = t
	}
}

@(private)
send_inputs :: proc(c: ^Client, now: i64) {
	w := msg_begin(.Inputs)
	wire.w_u8(&w, u8(c.cfg.player))
	w_i64(&w, now)
	wire.w_u32(&w, c.fin_upto)
	first := max(c.own_acked + 1, c.first_tick)
	last := min(c.own_last, first + INPUTS_MAX - 1)
	wire.w_u32(&w, first)
	count := last >= first ? last - first + 1 : 0
	wire.w_u8(&w, u8(count))
	for t in first ..< first + count {
		w_input(&w, c.own[t])
	}
	csend(c, &w, .Unreliable)
	c.last_send_us = now
}

// Input delay in ticks for a round-trip time: clamp(ceil((rtt/2 + 8 ms) / 16.667 ms), 1, 6).
// The ceiling is done by hand: netcode stays off core:math (see tests/lint).
want_delay :: proc(rtt_us: f64) -> u32 {
	x := (rtt_us / 1000 / 2 + 8) / 16.667
	if x <= 1 {
		return 1
	}
	if x >= 6 {
		return 6
	}
	d := u32(x) // x in (1, 6): truncation is floor
	if f64(d) < x {
		d += 1
	}
	return d
}

// Scheduler: advances the local tick at 60 Hz ± 2% towards relay tick + delay.
@(private)
schedule :: proc(c: ^Client, now: i64) -> (advanced: bool) {
	if !c.welcomed || !c.have_offset || c.rtt_samples < 3 {
		return
	}
	relay_tick := (f64(now) + c.offset_us) / TICK_US
	if !c.started {
		c.started = true
		c.delay = want_delay(c.rtt_us)
		c.delay_eval_us = now
		c.local = max(u32(max(relay_tick, 0)) + c.delay, c.verified)
		c.next_tick_us = f64(now) + TICK_US
		generate_inputs(c)
		return true
	}
	if now - c.delay_eval_us >= 1_000_000 {
		c.delay_eval_us = now
		want := want_delay(c.rtt_us)
		if want > c.delay {
			c.delay += 1
			c.delay_changes += 1
		} else if want < c.delay {
			c.delay -= 1
			c.delay_changes += 1
		}
	}
	err := relay_tick + f64(c.delay) - f64(c.local)
	period := f64(TICK_US)
	if err > 1.0 {
		period *= 0.98
	} else if err < 0 {
		period *= 1.02
	}
	for f64(now) >= c.next_tick_us {
		c.next_tick_us += period
		if c.local >= c.ticks || err < -4 {
			continue // finished, or far ahead of the relay: hold
		}
		if c.world != nil && c.local + 1 > c.verified + PREDICTION_CAP {
			c.stall_ticks += 1
			continue
		}
		c.local += 1
		err -= 1
		advanced = true
		generate_inputs(c)
	}
	// Far behind (e.g. after a stall): catch up without waiting for the slew.
	for err > 4 && c.local < c.ticks && (c.world == nil || c.local + 1 <= c.verified + PREDICTION_CAP) {
		c.local += 1
		err -= 1
		advanced = true
		generate_inputs(c)
	}
	return
}

@(private)
predict :: proc(c: ^Client) {
	if c.world == nil {
		return
	}
	for c.predicted < c.local && c.predicted < c.verified + PREDICTION_CAP && c.predicted < c.ticks {
		t := c.predicted + 1
		in_ := predicted_inputs(c, t)
		c.pred_inputs[t % PRED_RING] = in_
		sim.step(c.world, in_)
		record_checksum(c)
		c.predicted = t
	}
}

@(private)
serve_snapshot :: proc(c: ^Client) {
	if !c.snap_req || c.world == nil || c.verified < c.snap_min {
		return
	}
	c.snap_req = false
	data := sim.snapshot_encode(c.world, c.verified, context.temp_allocator)
	w := msg_begin(.Snap_Begin)
	wire.w_u8(&w, u8(c.snap_joiner))
	wire.w_u32(&w, c.verified)
	wire.w_u32(&w, u32(len(data)))
	csend(c, &w, .Reliable)
	for off := 0; off < len(data); off += SNAP_CHUNK {
		cw := msg_begin(.Snap_Chunk)
		wire.w_u8(&cw, u8(c.snap_joiner))
		wire.w_u32(&cw, u32(off))
		wire.w_bytes(&cw, data[off:min(off + SNAP_CHUNK, len(data))])
		csend(c, &cw, .Reliable)
	}
	fmt.eprintfln(
		"%s: sent snapshot of tick %d (%d bytes) for player %d",
		c.cfg.name,
		c.verified,
		len(data),
		c.snap_joiner,
	)
}

// Runs the client until the relay ends the session. Returns ok.
client_run :: proc(c: ^Client) -> bool {
	sw := Stopwatch {
		start = now_tick(),
	}
	hello := msg_begin(.Hello)
	wire.w_u8(&hello, u8(c.cfg.player))
	wire.w_u32(&hello, c.cfg.join_tick)
	csend(c, &hello, .Reliable)
	end_at: i64 = 0
	for {
		now := now_us()
		for ev in channel_poll(c.ch) {
			if ev.kind == .Message {
				handle_client_msg(c, ev.data, now)
			}
		}
		if c.error != "" {
			break
		}
		advance_verified(c)
		advanced := schedule(c, now)
		predict(c)
		serve_snapshot(c)
		if c.welcomed && (advanced || now - c.last_send_us >= TICK_US) {
			send_inputs(c, now)
		}
		if c.welcomed && c.verified >= c.ticks && !c.done_sent {
			w := msg_begin(.Done)
			wire.w_u8(&w, u8(c.cfg.player))
			wire.w_u32(&w, c.verified)
			csend(c, &w, .Reliable)
			c.done_sent = true
		}
		channel_flush(c.ch)
		free_all(context.temp_allocator)
		if c.end_received {
			if end_at == 0 {
				end_at = now
			}
			// Linger briefly so the ack for End goes out, then leave once our reliable queue is empty.
			if (channel_idle(c.ch, RELAY_PEER) && now - end_at > 100_000) || now - end_at > 2_000_000 {
				c.ok = c.verified == c.ticks
				return c.ok
			}
		}
		if elapsed_s(sw) > c.cfg.timeout_s {
			c.error = "timeout"
			break
		}
		sleep_ms(1)
	}
	fmt.eprintfln(
		"%s: %s (verified %d, predicted %d, local %d, finalized %d)",
		c.cfg.name,
		c.error,
		c.verified,
		c.predicted,
		c.local,
		c.fin_upto,
	)
	return false
}

// The client's JSON object (CORE.md §3 conventions).
client_json :: proc(c: ^Client) -> string {
	b := make([dynamic]u8, 0, 64 + len(c.checksums) * 32, context.temp_allocator)
	for e, i in c.checksums {
		if i > 0 {
			append(&b, ',')
		}
		append(&b, ..transmute([]u8)fmt.tprintf(`[%d,"%016x"]`, e[0], e[1]))
	}
	avg := c.rollbacks > 0 ? f64(c.depth_sum) / f64(c.rollbacks) : 0
	return fmt.tprintf(
		`{{"player":%d,"final_tick":%d,"checksums":[%s],"rollbacks":%d,"rollback_depth_avg":%.2f,"rollback_depth_max":%d,"stall_ticks":%d,"resim_ticks":%d,"join_tick":%d,"delay":%d,"delay_changes":%d,"rtt_ms":%.1f,"ok":%v,"net":%s}}`,
		c.cfg.player,
		c.verified,
		string(b[:]),
		c.rollbacks,
		avg,
		c.depth_max,
		c.stall_ticks,
		c.resim_ticks,
		c.first_tick,
		c.delay,
		c.delay_changes,
		c.rtt_us / 1000,
		c.ok,
		channel_stats_json(c.ch),
	)
}
