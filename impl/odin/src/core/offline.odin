// Offline harness modes: scripted runs, sync-test, replay, snapshot/resume and the rollback bench.
package core

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "../game"

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

// `sim`: scripted run for `ticks` ticks; optional trace and input log.
run_sim :: proc(ticks: u32, seed: u32, players: int, trace_path, log_path: string) -> (res: Run_Result, ok: bool) {
	sim := sim_create(seed, players)
	defer sim_destroy(sim)
	scripts: [game.MAX_PLAYERS]game.Script
	for p in 0 ..< game.MAX_PLAYERS {
		scripts[p] = game.script_init(seed, p)
	}
	tr: Trace
	lg := Input_Log{seed = u64(seed), players = u8(players)}
	for t in 1 ..= ticks {
		inputs := game.script_inputs(&scripts, &sim.state, t, players)
		if log_path != "" {
			append(&lg.ticks, Log_Tick{inputs = inputs})
		}
		sim_step(sim, inputs)
		res.final_checksum = sim_checksum(sim)
		trace_add(&tr, t, res.final_checksum)
	}
	res.final_tick = ticks
	res.summary = game.summary(&sim.state)
	ok = true
	if trace_path != "" {
		ok &&= trace_write(&tr, trace_path)
	}
	if log_path != "" {
		ok &&= log_write(log_path, &lg)
	}
	return
}

// `synctest`: every tick, once `window` ticks exist, restore `window` ticks back, re-simulate with
// the recorded inputs and compare each tick's checksum with the forward one.
run_synctest :: proc(ticks: u32, window: u32, seed: u32, players: int) -> (mismatches: int, resimulated: int, final: u64) {
	assert(window >= 1 && window < RING)
	sim := sim_create(seed, players)
	defer sim_destroy(sim)
	scripts: [game.MAX_PLAYERS]game.Script
	for p in 0 ..< game.MAX_PLAYERS {
		scripts[p] = game.script_init(seed, p)
	}
	recorded := make([]game.Inputs, ticks + 1)
	forward := make([]u64, ticks + 1)
	defer delete(recorded)
	defer delete(forward)
	for t in 1 ..= ticks {
		recorded[t] = game.script_inputs(&scripts, &sim.state, t, players)
		sim_step(sim, recorded[t])
		forward[t] = sim_checksum(sim)
		if t < window {
			continue
		}
		base := t - window
		if !sim_restore(sim, base) {
			fmt.eprintfln("synctest: restore of tick %d failed", base)
			mismatches += 1
			continue
		}
		for u in base + 1 ..= t {
			sim_step(sim, recorded[u])
			resimulated += 1
			if c := sim_checksum(sim); c != forward[u] {
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
run_replay :: proc(log_path, trace_path: string) -> (res: Run_Result, ok: bool) {
	lg, lok := log_read(log_path)
	if !lok {
		fmt.eprintfln("replay: cannot read input log %s", log_path)
		return
	}
	defer delete(lg.ticks)
	sim := sim_create(u32(lg.seed), int(lg.players))
	defer sim_destroy(sim)
	tr: Trace
	for &lt, i in lg.ticks {
		sim_step(sim, lt.inputs)
		res.final_checksum = sim_checksum(sim)
		trace_add(&tr, u32(i + 1), res.final_checksum)
	}
	res.final_tick = u32(len(lg.ticks))
	return res, trace_path == "" || trace_write(&tr, trace_path)
}

// `snapshot`: scripted run to `ticks`, then a portable snapshot of that tick.
run_snapshot :: proc(ticks: u32, seed: u32, players: int, out_path: string) -> (bytes: int, checksum: u64, ok: bool) {
	sim := sim_create(seed, players)
	defer sim_destroy(sim)
	scripts: [game.MAX_PLAYERS]game.Script
	for p in 0 ..< game.MAX_PLAYERS {
		scripts[p] = game.script_init(seed, p)
	}
	for t in 1 ..= ticks {
		sim_step(sim, game.script_inputs(&scripts, &sim.state, t, players))
	}
	data := snapshot_encode(sim, ticks)
	defer delete(data)
	return len(data), sim_checksum(sim), os.write_entire_file(out_path, data) == nil
}

// `resume`: restores a portable snapshot and continues the scripted run for `ticks` ticks.
run_resume :: proc(in_path: string, ticks: u32, trace_path: string) -> (res: Run_Result, ok: bool) {
	data, err := os.read_entire_file(in_path, context.allocator)
	if err != nil {
		fmt.eprintfln("resume: cannot read %s", in_path)
		return
	}
	defer delete(data)
	sim := sim_from_snapshot(data)
	if sim == nil {
		fmt.eprintfln("resume: %s is not a valid snapshot for this build", in_path)
		return
	}
	defer sim_destroy(sim)
	scripts: [game.MAX_PLAYERS]game.Script
	for p in 0 ..< game.MAX_PLAYERS {
		scripts[p] = game.script_init(sim.seed, p)
	}
	tr: Trace
	start := sim.state.tick
	for t in start + 1 ..= start + ticks {
		sim_step(sim, game.script_inputs(&scripts, &sim.state, t, sim.players))
		res.final_checksum = sim_checksum(sim)
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

// `bench`: pre-spawns `enemies` enemies (the spawner then refills to that count), and every tick
// measures the forward step, the save, a restore `window` ticks back and the `window`-tick re-sim
// (step + save per tick, which is what a client rollback costs). Re-sim checksums are compared too.
run_bench :: proc(enemies: int, window: u32, ticks: u32, seed: u32, players: int) -> (br: Bench_Result) {
	assert(window >= 1 && window < RING)
	sim := sim_create(seed, players)
	defer sim_destroy(sim)
	sim.state.enemy_cap = u32(enemies)
	game.prespawn_enemies(&sim.state, enemies)
	sim_save(sim)
	scripts: [game.MAX_PLAYERS]game.Script
	for p in 0 ..< game.MAX_PLAYERS {
		scripts[p] = game.script_init(seed, p)
	}
	n := int(ticks)
	step := make([]f64, n)
	save := make([]f64, n)
	restore := make([]f64, n)
	resim := make([]f64, n)
	recorded := make([]game.Inputs, ticks + 1)
	forward := make([]u64, ticks + 1)
	defer {
		delete(step)
		delete(save)
		delete(restore)
		delete(resim)
		delete(recorded)
		delete(forward)
	}
	us :: proc(a, b: time.Tick) -> f64 {return time.duration_microseconds(time.tick_diff(a, b))}
	enemy_sum := 0.0
	nr := 0
	for t in 1 ..= ticks {
		recorded[t] = game.script_inputs(&scripts, &sim.state, t, players)
		t0 := time.tick_now()
		game.tick(&sim.state, &sim.phys, &sim.scratch, &recorded[t])
		t1 := time.tick_now()
		sim_save(sim)
		t2 := time.tick_now()
		forward[t] = sim_checksum(sim)
		step[t - 1] = us(t0, t1)
		save[t - 1] = us(t1, t2)
		enemy_sum += f64(sim.state.enemies.count)
		if t < window {
			continue
		}
		base := t - window
		t3 := time.tick_now()
		ok := sim_restore(sim, base)
		t4 := time.tick_now()
		assert(ok)
		for u in base + 1 ..= t {
			sim_step(sim, recorded[u])
		}
		t5 := time.tick_now()
		if sim_checksum(sim) != forward[t] {
			br.mismatches += 1
		}
		restore[nr] = us(t3, t4)
		resim[nr] = us(t4, t5)
		nr += 1
	}
	br.step = stat_of(step)
	br.save = stat_of(save)
	br.restore = stat_of(restore[:nr])
	br.resim = stat_of(resim[:nr])
	br.block_bytes = size_of(game.State)
	br.snapshot_bytes = br.block_bytes + sim_physics_bytes(sim)
	br.enemies_mean = enemy_sum / f64(max(n, 1))
	return
}
