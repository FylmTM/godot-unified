// `bench` (src/headless/SPEC.md, CLI): the cost of a forward step, a save, a restore and a re-sim,
// every tick, for `uni bench`.
package modes

import "core:fmt"
import "core:slice"
import "core:time"

import uheadless "unified:headless"
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
	for sample in samples {
		sum += sample
	}
	slice.sort(samples)
	rank := (99 * len(samples) + 99) / 100 // nearest rank
	return {sum / f64(len(samples)), samples[max(rank - 1, 0)]}
}

Bench_Result :: struct {
	step, save, restore, resim: Stat,
	snapshot_bytes:             int,
	block_bytes:                int,
	entities_mean:              f64,
	mismatches:                 int,
}

// `bench`: prepares `entities` entities (the game holds that population), and every tick measures
// the forward step, the save, a restore `window` ticks back and the `window`-tick re-sim (step +
// save per tick, which is what a client rollback costs). Re-sim checksums are compared too.
run_bench :: proc(
	headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS),
	entities: int,
	window, ticks: u32,
	seed: u64,
	players: int,
) -> (
	result: Bench_Result,
) {
	assert(window >= 1 && int(window) <= uheadless.max_window(headless.game))
	simulation := sim.create(headless.game, seed, headless.content)
	defer sim.destroy(simulation)
	if headless.bench_prepare != nil {
		headless.bench_prepare(&simulation.state, simulation.world, entities)
		sim.save(simulation)
	}
	tick_count := int(ticks)
	step_us := make([]f64, tick_count)
	save_us := make([]f64, tick_count)
	restore_us := make([]f64, tick_count)
	resim_us := make([]f64, tick_count)
	recorded := make([]sim.Inputs(Input, PLAYERS), ticks + 1)
	forward := make([]u64, ticks + 1)
	commands: uheadless.Scripted_Commands
	defer uheadless.scripted_commands_destroy(&commands)
	defer {
		delete(step_us)
		delete(save_us)
		delete(restore_us)
		delete(resim_us)
		delete(recorded)
		delete(forward)
	}
	micros :: proc(from, to: time.Tick) -> f64 {return time.duration_microseconds(time.tick_diff(from, to))}
	count_sum := 0.0
	rollbacks := 0
	for tick in 1 ..= ticks {
		recorded[tick] = uheadless.scripted(headless, simulation, tick, players, &commands)
		step_start := time.tick_now()
		sim.advance(simulation, &recorded[tick])
		step_end := time.tick_now()
		sim.save(simulation)
		save_end := time.tick_now()
		forward[tick] = sim.checksum(simulation)
		step_us[tick - 1] = micros(step_start, step_end)
		save_us[tick - 1] = micros(step_end, save_end)
		if headless.bench_count != nil {
			count_sum += f64(headless.bench_count(&simulation.state))
		}
		if tick < window {
			continue
		}
		base := tick - window
		restore_start := time.tick_now()
		ok := sim.restore(simulation, base)
		restore_end := time.tick_now()
		assert(ok)
		for resim in base + 1 ..= tick {
			sim.step(simulation, &recorded[resim])
		}
		resim_end := time.tick_now()
		if sim.checksum(simulation) != forward[tick] {
			result.mismatches += 1
		}
		restore_us[rollbacks] = micros(restore_start, restore_end)
		resim_us[rollbacks] = micros(restore_end, resim_end)
		rollbacks += 1
	}
	result.step = stat_of(step_us)
	result.save = stat_of(save_us)
	result.restore = stat_of(restore_us[:rollbacks])
	result.resim = stat_of(resim_us[:rollbacks])
	result.block_bytes = size_of(State)
	result.snapshot_bytes = sim.snapshot_size(simulation)
	result.entities_mean = count_sum / f64(max(tick_count, 1))
	return
}

// `table-bench` (N9, the #6 sitting): what a table walk costs when the table is sparse. sim.iterate / sim.next look
// at every slot up to high_water, which never goes down, so a table that once held 65,536 items and now holds a few
// still walks them all. Measures that walk against a dense table holding the same live items; an alive bitmask
// (1 bit per slot) comes only if this shows the scan matters. Game-independent: `uni bench` runs it once.
TABLE_BENCH_CAPACITY :: 65_536

Table_Bench_Item :: struct {
	position: [3]f32,
	velocity: [3]f32,
	life:     i32,
	kind:     u32,
}

Table_Bench :: sim.Table(Table_Bench_Item, TABLE_BENCH_CAPACITY)

mode_table_bench :: proc(args: ^Args) -> bool {
	check_known(args, "live", "walks")
	live := opt_int(args, "live", 1000, low = 1, high = TABLE_BENCH_CAPACITY)
	walks := opt_int(args, "walks", 300, low = 1, high = 100_000)
	sparse, dense := new(Table_Bench), new(Table_Bench)
	defer free(sparse)
	defer free(dense)
	// sparse: every slot used once, then all but `live` (spread evenly) despawned; dense: `live` items at the front
	for i in 0 ..< TABLE_BENCH_CAPACITY {
		item, _, _ := sim.spawn(sparse)
		item.life = i32(i)
	}
	keep_every := TABLE_BENCH_CAPACITY / live
	for i in 0 ..< TABLE_BENCH_CAPACITY {
		if i % keep_every != 0 || i / keep_every >= live do sim.despawn(sparse, i)
	}
	for i in 0 ..< live {
		item, _, _ := sim.spawn(dense)
		item.life = i32(i)
	}
	walk :: proc(table: ^Table_Bench) -> (micros: f64, sum: i64) {
		start := time.tick_now()
		items := sim.iterate(table)
		for item, handle in sim.next(&items) {
			sum += i64(item.life) + i64(handle.index)
		}
		return time.duration_microseconds(time.tick_since(start)), sum
	}
	sparse_us, dense_us := make([]f64, walks), make([]f64, walks)
	defer delete(sparse_us)
	defer delete(dense_us)
	sparse_sum, dense_sum: i64
	for i in 0 ..< walks {
		sum: i64
		sparse_us[i], sum = walk(sparse)
		sparse_sum += sum
		dense_us[i], sum = walk(dense)
		dense_sum += sum
	}
	sparse_stat, dense_stat := stat_of(sparse_us), stat_of(dense_us)
	stat_json :: proc(stat: Stat) -> string {
		return fmt.tprintf(`{{"mean":%.2f,"p99":%.2f}}`, stat.mean, stat.p99)
	}
	fmt.printfln(
		`{{"mode":"table-bench","capacity":%d,"live":%d,"walks":%d,"sparse_us":%s,"dense_us":%s,"checksum":%d}}`,
		TABLE_BENCH_CAPACITY,
		int(sparse.count),
		walks,
		stat_json(sparse_stat),
		stat_json(dense_stat),
		sparse_sum ~ dense_sum,
	)
	return int(sparse.count) == live
}
