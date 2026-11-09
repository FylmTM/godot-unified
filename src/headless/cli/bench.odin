// `bench` (src/headless/SPEC.md, CLI): the cost of a forward step, a save, a restore and a re-sim,
// every tick, for `dev.py bench`.
package cli

import "core:slice"
import "core:time"

import "unified:headless"
import "unified:sim"

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
	h: ^headless.Headless($S, $I, $W, $P),
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
	sc: headless.Script_Commands
	defer headless.script_commands_destroy(&sc)
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
		recorded[t] = headless.scripted(h, s, t, players, &sc)
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
