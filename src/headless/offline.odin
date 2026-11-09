// Offline modes, generic over the game: scripted runs, sync-test, replay, snapshot/resume and the
// rollback bench (spec/headless.md (CLI)).
package headless

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "unified:sim"

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
}

Trace :: struct {
	b: strings.Builder,
}

trace_add :: proc(tr: ^Trace, tick: u32, checksum: u64) {
	fmt.sbprintf(&tr.b, "%06d %016x\n", tick, checksum)
}

trace_write :: proc(tr: ^Trace, path: string) -> bool {
	return os.write_entire_file(path, tr.b.buf[:]) == nil
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

// `sim`: scripted run for `ticks` ticks; optional trace and input log.
run_sim :: proc(
	h: ^Headless($S, $I, $W, $P),
	ticks: u32,
	seed: u64,
	players: int,
	trace_path, log_path: string,
) -> (
	res: Run_Result,
	ok: bool,
) {
	s := sim.create(h.game, seed)
	defer sim.destroy(s)
	tr: Trace
	lg := sim.Input_Log(I, P) {
		seed = seed,
	}
	defer sim.log_destroy(&lg)
	for t in 1 ..= ticks {
		inputs := scripted(h, s, t, players)
		if log_path != "" {
			append(&lg.ticks, inputs)
		}
		sim.step(s, &inputs)
		res.final_checksum = sim.checksum(s)
		trace_add(&tr, t, res.final_checksum)
	}
	res.final_tick = ticks
	if h.summary != nil {
		res.summary = h.summary(&s.state)
	}
	ok = true
	if trace_path != "" {
		ok &&= trace_write(&tr, trace_path)
	}
	if log_path != "" {
		ok &&= sim.log_write(log_path, &lg)
	}
	return
}

// `synctest`: every tick, once `window` ticks exist, restore `window` ticks back, re-simulate with
// the recorded inputs and compare each tick's checksum with the forward one.
run_synctest :: proc(
	h: ^Headless($S, $I, $W, $P),
	ticks, window: u32,
	seed: u64,
	players: int,
) -> (
	mismatches: int,
	resimulated: int,
	final: u64,
) {
	assert(window >= 1 && window < sim.RING)
	s := sim.create(h.game, seed)
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
			fmt.eprintfln("synctest: restore of tick %d failed", base)
			mismatches += 1
			continue
		}
		for u in base + 1 ..= t {
			sim.step(s, &recorded[u])
			resimulated += 1
			if c := sim.checksum(s); c != forward[u] {
				if mismatches < 10 {
					fmt.eprintfln("synctest: tick %d (re-sim at %d): %016x vs forward %016x", u, t, c, forward[u])
				}
				mismatches += 1
			}
		}
	}
	return mismatches, resimulated, forward[ticks] if ticks > 0 else 0
}

// `replay`: re-simulates an input log, tracing every tick.
run_replay :: proc(h: ^Headless($S, $I, $W, $P), log_path, trace_path: string) -> (res: Run_Result, ok: bool) {
	lg, lok := sim.log_read(log_path, I, P)
	if !lok {
		fmt.eprintfln("replay: cannot read input log %s (or it is for another game build)", log_path)
		return
	}
	defer sim.log_destroy(&lg)
	s := sim.create(h.game, lg.seed)
	defer sim.destroy(s)
	tr: Trace
	for &in_, i in lg.ticks {
		sim.step(s, &in_)
		res.final_checksum = sim.checksum(s)
		trace_add(&tr, u32(i + 1), res.final_checksum)
	}
	res.final_tick = u32(len(lg.ticks))
	return res, trace_path == "" || trace_write(&tr, trace_path)
}

// `snapshot`: scripted run to `ticks`, then a portable snapshot of that tick.
run_snapshot :: proc(
	h: ^Headless($S, $I, $W, $P),
	ticks: u32,
	seed: u64,
	players: int,
	out_path: string,
) -> (
	bytes: int,
	final: u64,
	ok: bool,
) {
	s := sim.create(h.game, seed)
	defer sim.destroy(s)
	for t in 1 ..= ticks {
		in_ := scripted(h, s, t, players)
		sim.step(s, &in_)
	}
	data := sim.snapshot_encode(s, ticks)
	defer delete(data)
	return len(data), sim.checksum(s), os.write_entire_file(out_path, data) == nil
}

// `resume`: restores a portable snapshot and continues the scripted run for `ticks` ticks with
// `players` players present.
run_resume :: proc(
	h: ^Headless($S, $I, $W, $P),
	in_path: string,
	ticks: u32,
	players: int,
	trace_path: string,
) -> (
	res: Run_Result,
	ok: bool,
) {
	data, err := os.read_entire_file(in_path, context.allocator)
	if err != nil {
		fmt.eprintfln("resume: cannot read %s", in_path)
		return
	}
	defer delete(data)
	s := sim.from_snapshot(h.game, data)
	if s == nil {
		fmt.eprintfln("resume: %s is not a valid snapshot for this build", in_path)
		return
	}
	defer sim.destroy(s)
	tr: Trace
	start := s.tick
	for t in start + 1 ..= start + ticks {
		in_ := scripted(h, s, t, players)
		sim.step(s, &in_)
		res.final_checksum = sim.checksum(s)
		trace_add(&tr, t, res.final_checksum)
	}
	res.final_tick = start + ticks
	return res, trace_path == "" || trace_write(&tr, trace_path)
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
	s := sim.create(h.game, seed)
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
