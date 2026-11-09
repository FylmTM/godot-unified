// Offline modes, generic over the game: scripted runs, sync-test, replay, snapshot/resume and the
// rollback bench (src/headless/SPEC.md (CLI)).
package headless

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "unified:sim"

// Used only inside parametric procs: -vet would flag them in a package that imports unified:headless
// without instantiating those (a suite that never calls headless.run).
_ :: time

// What a game's headless binary supplies besides its sim.Game.
Headless :: struct($S, $I, $W: typeid, $P: int) {
	game:          ^sim.Game(S, I, W, P), // the default
	// Other variants of the game (e.g. other tunings), selected with `--game NAME` (sim.Game.name)
	// on any mode.
	variants:      []^sim.Game(S, I, W, P),
	// Scripted input of `slot` for tick t; `state` is the caller's current state (nil if none).
	script:        proc(seed: u64, slot: int, t: u32, state: ^S) -> I,
	// JSON fields describing a state, for the `sim` output (optional; temp-allocated).
	summary:       proc(s: ^S) -> string,
	// `bench`: fill the state with n entities and hold that population (optional).
	bench_prepare: proc(s: ^S, w: ^W, n: int),
	// `bench`: the current entity count, for enemies_mean (optional).
	bench_count:   proc(s: ^S) -> int,
	// Online play over a lobby transport: the <name>-host and <name>-client modes (optional).
	online:        ^Online,
	// The game's content (its level file, src/level/SPEC.md): the default (e.g. embedded with #load);
	// `--level FILE` on any mode replaces it.
	content:       []u8,
}

// A run's checksums, one per tick from `first` on: sums[i] is the checksum after tick first + i.
// On disk (`--trace`, a reference run's ref.trace): one "%06d %016x" line per tick, in order.
Trace :: struct {
	first: u32,
	sums:  [dynamic]u64,
}

trace_add :: proc(tr: ^Trace, tick: u32, checksum: u64) {
	if len(tr.sums) == 0 {
		tr.first = tick
	}
	assert(tick == tr.first + u32(len(tr.sums)), "trace ticks must be consecutive")
	append(&tr.sums, checksum)
}

trace_destroy :: proc(tr: ^Trace) {
	delete(tr.sums)
	tr^ = {}
}

// The checksum of tick t, if the trace has it.
trace_at :: proc(tr: ^Trace, t: u32) -> (checksum: u64, ok: bool) {
	if t < tr.first || t - tr.first >= u32(len(tr.sums)) {
		return
	}
	return tr.sums[t - tr.first], true
}

// The first tick where two traces differ (a tick only one of them has counts); differ = false when equal.
trace_first_difference :: proc(a, b: ^Trace) -> (tick: u32, differ: bool) {
	if len(a.sums) > 0 && len(b.sums) > 0 && a.first != b.first {
		return min(a.first, b.first), true
	}
	n := min(len(a.sums), len(b.sums))
	for i in 0 ..< n {
		if a.sums[i] != b.sums[i] {
			return a.first + u32(i), true
		}
	}
	if len(a.sums) != len(b.sums) {
		first := a.first if len(a.sums) > 0 else b.first
		return first + u32(n), true
	}
	return 0, false
}

trace_write :: proc(tr: ^Trace, path: string) -> bool {
	b := strings.builder_make(0, len(tr.sums) * 24)
	defer strings.builder_destroy(&b)
	for c, i in tr.sums {
		fmt.sbprintf(&b, "%06d %016x\n", tr.first + u32(i), c)
	}
	return os.write_entire_file(path, b.buf[:]) == nil
}

// Reads a trace file; fails on a malformed line or ticks out of order.
trace_read :: proc(path: string) -> (tr: Trace, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_right(line, "\r")
		if l == "" {
			continue
		}
		sp := strings.index_byte(l, ' ')
		tick, tok := strconv.parse_u64_of_base(l[:max(sp, 0)], 10)
		sum, sok := strconv.parse_u64_of_base(l[sp + 1:] if sp > 0 else "", 16)
		if !tok || !sok || tick > u64(max(u32)) || (len(tr.sums) > 0 && u32(tick) != tr.first + u32(len(tr.sums))) {
			trace_destroy(&tr)
			return {}, false
		}
		trace_add(&tr, u32(tick), sum)
	}
	return tr, true
}

Run_Result :: struct {
	final_tick:     u32,
	final_checksum: u64,
	summary:        string,
}

// Scripted inputs of tick t: slots < players present.
scripted :: proc(
	h: ^Headless($S, $I, $W, $P),
	s: ^sim.Sim(S, I, W, P),
	t: u32,
	players: int,
) -> (
	in_: sim.Inputs(I, P),
) {
	for p in 0 ..< players {
		in_.present += {p}
		in_.input[p] = h.script(s.seed, p, t, &s.state)
	}
	return
}

// `sim`: scripted run for `ticks` ticks; records every tick's checksum into `tr` and its inputs
// into `lg` (each optional).
run_sim :: proc(
	h: ^Headless($S, $I, $W, $P),
	ticks: u32,
	seed: u64,
	players: int,
	tr: ^Trace = nil,
	lg: ^sim.Input_Log(I, P) = nil,
) -> (
	res: Run_Result,
) {
	s := sim.create(h.game, seed, h.content)
	defer sim.destroy(s)
	if lg != nil {
		lg.seed = seed
		lg.content = s.content_hash
	}
	for t in 1 ..= ticks {
		inputs := scripted(h, s, t, players)
		if lg != nil {
			append(&lg.ticks, inputs)
		}
		sim.step(s, &inputs)
		res.final_checksum = sim.checksum(s)
		if tr != nil {
			trace_add(tr, t, res.final_checksum)
		}
	}
	res.final_tick = ticks
	if h.summary != nil {
		res.summary = h.summary(&s.state)
	}
	return
}

Synctest_Result :: struct {
	mismatches:     int,
	resimulated:    int, // ticks re-simulated
	final_checksum: u64,
	first_tick:     u32, // the first mismatching tick (0: none)
	first_at:       u32, // the tick whose rollback re-simulated it differently
}

// `synctest`: every tick, once `window` ticks exist, restore `window` ticks back, re-simulate with
// the recorded inputs and compare each tick's checksum with the forward one.
run_synctest :: proc(
	h: ^Headless($S, $I, $W, $P),
	ticks, window: u32,
	seed: u64,
	players: int,
) -> (
	res: Synctest_Result,
) {
	assert(window >= 1 && window < sim.RING)
	s := sim.create(h.game, seed, h.content)
	defer sim.destroy(s)
	recorded := make([]sim.Inputs(I, P), ticks + 1)
	forward := make([]u64, ticks + 1)
	defer delete(recorded)
	defer delete(forward)
	for t in 1 ..= ticks {
		recorded[t] = scripted(h, s, t, players)
		sim.step(s, &recorded[t])
		forward[t] = sim.checksum(s)
		if t < window {
			continue
		}
		base := t - window
		if !sim.restore(s, base) {
			if res.mismatches == 0 {
				res.first_tick, res.first_at = base, t
			}
			res.mismatches += 1
			continue
		}
		for u in base + 1 ..= t {
			sim.step(s, &recorded[u])
			res.resimulated += 1
			if sim.checksum(s) != forward[u] {
				if res.mismatches == 0 {
					res.first_tick, res.first_at = u, t
				}
				res.mismatches += 1
			}
		}
	}
	res.final_checksum = forward[ticks] if ticks > 0 else 0
	return
}

// `replay`: re-simulates an input log, recording every tick's checksum into `tr` (optional). Fails
// when the log was recorded with other content (another level).
run_replay :: proc(
	h: ^Headless($S, $I, $W, $P),
	lg: ^sim.Input_Log(I, P),
	tr: ^Trace = nil,
) -> (
	res: Run_Result,
	ok: bool,
) {
	if lg.content != sim.content_hash(h.content) {
		fmt.eprintfln(
			"replay: the log was recorded with another level (content %016x, this run has %016x; see --level)",
			lg.content,
			sim.content_hash(h.content),
		)
		return
	}
	s := sim.create(h.game, lg.seed, h.content)
	defer sim.destroy(s)
	for &in_, i in lg.ticks {
		sim.step(s, &in_)
		res.final_checksum = sim.checksum(s)
		if tr != nil {
			trace_add(tr, u32(i + 1), res.final_checksum)
		}
	}
	res.final_tick = u32(len(lg.ticks))
	return res, true
}

// `snapshot`: scripted run to `ticks`, then a portable snapshot of that tick (the caller owns `data`).
run_snapshot :: proc(
	h: ^Headless($S, $I, $W, $P),
	ticks: u32,
	seed: u64,
	players: int,
) -> (
	data: []u8,
	checksum: u64,
) {
	s := sim.create(h.game, seed, h.content)
	defer sim.destroy(s)
	for t in 1 ..= ticks {
		in_ := scripted(h, s, t, players)
		sim.step(s, &in_)
	}
	return sim.snapshot_encode(s, ticks), sim.checksum(s)
}

// `resume`: restores a portable snapshot and continues the scripted run for `ticks` ticks with
// `players` players present, recording every tick's checksum into `tr` (optional).
run_resume :: proc(
	h: ^Headless($S, $I, $W, $P),
	data: []u8,
	ticks: u32,
	players: int,
	tr: ^Trace = nil,
) -> (
	res: Run_Result,
	ok: bool,
) {
	s, serr := sim.from_snapshot(h.game, data, h.content)
	if serr != .None {
		fmt.eprintfln("resume: not a valid snapshot for this build: %v", serr)
		return
	}
	defer sim.destroy(s)
	start := s.tick
	for t in start + 1 ..= start + ticks {
		in_ := scripted(h, s, t, players)
		sim.step(s, &in_)
		res.final_checksum = sim.checksum(s)
		if tr != nil {
			trace_add(tr, t, res.final_checksum)
		}
	}
	res.final_tick = start + ticks
	return res, true
}

Stat :: struct {
	mean: f64,
	p99:  f64,
}

stat_of :: proc(samples: []f64) -> Stat {
	if len(samples) == 0 {
		return {}
	}
	sum := 0.0
	for v in samples {
		sum += v
	}
	slice.sort(samples)
	rank := (99 * len(samples) + 99) / 100 // nearest rank
	return {sum / f64(len(samples)), samples[max(rank - 1, 0)]}
}

Bench_Result :: struct {
	step, save, restore, resim: Stat,
	snapshot_bytes:             int,
	block_bytes:                int,
	enemies_mean:               f64,
	mismatches:                 int,
}

// `bench`: prepares `enemies` entities (the game holds that population), and every tick measures
// the forward step, the save, a restore `window` ticks back and the `window`-tick re-sim (step +
// save per tick, which is what a client rollback costs). Re-sim checksums are compared too.
run_bench :: proc(
	h: ^Headless($S, $I, $W, $P),
	enemies: int,
	window, ticks: u32,
	seed: u64,
	players: int,
) -> (
	br: Bench_Result,
) {
	assert(window >= 1 && window < sim.RING)
	s := sim.create(h.game, seed, h.content)
	defer sim.destroy(s)
	if h.bench_prepare != nil {
		h.bench_prepare(&s.state, s.world, enemies)
		sim.save(s)
	}
	n := int(ticks)
	step_us := make([]f64, n)
	save_us := make([]f64, n)
	restore_us := make([]f64, n)
	resim_us := make([]f64, n)
	recorded := make([]sim.Inputs(I, P), ticks + 1)
	forward := make([]u64, ticks + 1)
	defer {
		delete(step_us)
		delete(save_us)
		delete(restore_us)
		delete(resim_us)
		delete(recorded)
		delete(forward)
	}
	us :: proc(a, b: time.Tick) -> f64 {return time.duration_microseconds(time.tick_diff(a, b))}
	count_sum := 0.0
	nr := 0
	for t in 1 ..= ticks {
		recorded[t] = scripted(h, s, t, players)
		t0 := time.tick_now()
		sim.advance(s, &recorded[t])
		t1 := time.tick_now()
		sim.save(s)
		t2 := time.tick_now()
		forward[t] = sim.checksum(s)
		step_us[t - 1] = us(t0, t1)
		save_us[t - 1] = us(t1, t2)
		if h.bench_count != nil {
			count_sum += f64(h.bench_count(&s.state))
		}
		if t < window {
			continue
		}
		base := t - window
		t3 := time.tick_now()
		ok := sim.restore(s, base)
		t4 := time.tick_now()
		assert(ok)
		for u in base + 1 ..= t {
			sim.step(s, &recorded[u])
		}
		t5 := time.tick_now()
		if sim.checksum(s) != forward[t] {
			br.mismatches += 1
		}
		restore_us[nr] = us(t3, t4)
		resim_us[nr] = us(t4, t5)
		nr += 1
	}
	br.step = stat_of(step_us)
	br.save = stat_of(save_us)
	br.restore = stat_of(restore_us[:nr])
	br.resim = stat_of(resim_us[:nr])
	br.block_bytes = size_of(S)
	br.snapshot_bytes = sim.snapshot_size(s)
	br.enemies_mean = count_sum / f64(max(n, 1))
	return
}
