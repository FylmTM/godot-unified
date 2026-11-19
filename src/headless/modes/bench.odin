// `bench` (src/headless/README.md, The binary): the cost of a forward step, a save, a checksum, a restore and a
// re-sim, every tick, for `uni bench`.
package modes

import "core:fmt"
import "core:slice"
@(require) import "core:time" // only in generic procs

@(require) import uheadless "unified:headless" // only in generic procs
@(require) import "unified:sim" // only in generic procs

@(private)
Stat :: struct {
	mean: f64,
	p99:  f64,
}

// A Stat as the modes print every timing: {"mean":..,"p99":..}, in µs (temp-allocated).
@(private)
stat_json :: proc(stat: Stat) -> string {
	return fmt.tprintf(`{{"mean":%.2f,"p99":%.2f}}`, stat.mean, stat.p99)
}

// The mean and nearest-rank p99 of timing samples (zeros for none); sorts `samples` in place.
@(private)
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

@(private)
Bench_Result :: struct {
	step, save, restore, resim: Stat,
	// The same re-sim of ticks that are all final (a catch-up burst), saving only the last one (what the netcode
	// does)
	resim_final:                Stat,
	// sim.checksum of the stepped tick: on the ticks peers compare (sim.DEEP_CHECKSUM_EVERY: every extra's whole
	// state) and on the others (an extra's cheaper summary)
	checksum_deep, checksum:    Stat,
	// Of a checksum tick the sim has moved past (a client verifies behind its prediction): sim.snapshot_encode_into
	// into a reused buffer, what a joiner's snapshot costs its provider; sim.snapshot_keep (a copy of the block and
	// the Extra's save), what typed desync reports cost a client on every checksum tick (Welcome's Keep_Images)
	snapshot_encode:            Stat,
	snapshot_keep:              Stat,
	snapshot_bytes:             int,
	save_bytes:                 int, // what each tick's save copies: the block and the extras' saves (sim.save_size)
	warmup:                     int, // the first ticks, left out of the timings
	mismatches:                 int,
	// The game's zones (sim.zone) per forward step, from a second pass of the same ticks with a Dev attached and timed
	// (so the timings above carry no clock reads), the game's zones then "other"; empty for a game without zones.
	zones:                      []Zone_Stat,
}

@(private)
Zone_Stat :: struct {
	name: string,
	stat: Stat,
}

// The zones' clock (sim.dev_attach): nanoseconds.
@(private)
bench_clock :: proc "contextless" () -> i64 {
	return time.tick_now()._nsec
}

// The zone pass of run_bench: the same forward ticks, a Dev attached with a clock, each zone's self time per step.
@(private)
bench_zones :: proc(
	game: ^$G,
	entities: int,
	seed: u64,
	recorded: []sim.Inputs(G),
	warmup: u32,
	result: ^Bench_Result,
) {
	simulation := sim.create(game, seed)
	defer sim.destroy(simulation)
	if game.bench_prepare != nil {
		game.bench_prepare(&simulation.state, simulation.world, entities)
		sim.save(simulation)
	}
	dev := sim.dev_attach(simulation, bench_clock)
	if dev == nil do return // a build without the dev UI times no zones
	samples: [sim.ZONES_MAX + 1][dynamic]f64
	for &zone in samples do zone = make([dynamic]f64, context.temp_allocator)
	for tick in 1 ..< u32(len(recorded)) {
		before := dev.zone_ns
		sim.step(simulation, &recorded[tick], save = false)
		sim.save(simulation)
		if tick <= warmup do continue
		for &zone, i in samples do append(&zone, f64(dev.zone_ns[i] - before[i]) / 1000)
	}
	totals := sim.zone_totals(simulation)
	if len(totals.names) == 0 do return
	result.zones = make([]Zone_Stat, len(totals.names), context.temp_allocator)
	for name, i in totals.names {
		index := i < len(totals.names) - 1 ? i : sim.ZONES_MAX
		result.zones[i] = {fmt.tprint(name), stat_of(samples[index][:])} // the names die with the sim
	}
}

// The ticks a benchmark runs before it times anything, after the first `window` (which have no rollback that deep):
// caches warm and a game's population settles (players joining, the first waves).
@(private)
BENCH_WARMUP :: 64

// `bench`: prepares `entities` entities (the game holds that population), and every tick measures
// the forward step, the save, a restore `window` ticks back and the `window`-tick re-sim (step +
// save per tick, which is what a client rollback of predicted ticks costs), then the same re-sim of final ticks
// (no save but the last: a catch-up burst). Re-sim checksums are compared too, and the forward tick's
// checksum is timed (deep ticks and the others apart). The first `window` + BENCH_WARMUP ticks run untimed (all of
// them when the run is no longer). A rollback at the prediction cap every tick is the worst case the netcode
// makes, not a typical frame: the bound the frame budget is checked against.
@(private)
run_bench :: proc(game: ^$G, entities: int, window, ticks: u32, seed: u64, players: int) -> (result: Bench_Result) {
	State :: sim.part(G, sim.GAME_STATE)
	Input :: sim.part(G, sim.GAME_INPUT)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	assert(window >= 1 && int(window) <= uheadless.max_window(game))
	simulation := sim.create(game, seed)
	defer sim.destroy(simulation)
	if game.bench_prepare != nil {
		game.bench_prepare(&simulation.state, simulation.world, entities)
		sim.save(simulation)
	}
	for k in 0 ..< sim.KEEP_SLOTS {
		sim.snapshot_keep(simulation, 0, k) // the keep slots and their buffers, at the population's size
	}
	tick_count := int(ticks)
	step_us := make([]f64, tick_count)
	save_us := make([]f64, tick_count)
	restore_us := make([]f64, tick_count)
	resim_us := make([]f64, tick_count)
	resim_final_us := make([]f64, tick_count)
	checksum_us := make([]f64, tick_count)
	checksum_deep_us := make([]f64, tick_count)
	snapshot_encode_us := make([]f64, tick_count)
	snapshot_keep_us := make([]f64, tick_count)
	image: [dynamic]u8
	recorded := make([]sim.Inputs(G), ticks + 1)
	forward := make([]u64, ticks + 1)
	commands: uheadless.Scripted_Commands(G)
	defer uheadless.scripted_commands_destroy(&commands)
	defer {
		delete(step_us)
		delete(save_us)
		delete(restore_us)
		delete(resim_us)
		delete(resim_final_us)
		delete(checksum_us)
		delete(checksum_deep_us)
		delete(snapshot_encode_us)
		delete(snapshot_keep_us)
		delete(image)
		delete(recorded)
		delete(forward)
	}
	micros :: proc(from, to: time.Tick) -> f64 {return time.duration_microseconds(time.tick_diff(from, to))}
	warmup := u32(window) + BENCH_WARMUP
	if warmup >= ticks {
		warmup = 0
	}
	result.warmup = int(warmup)
	steps, rollbacks, checksums, deep_checksums := 0, 0, 0, 0
	for tick in 1 ..= ticks {
		timed := tick > warmup
		recorded[tick] = uheadless.scripted(game, simulation, tick, players, &commands)
		step_start := time.tick_now()
		sim.step(simulation, &recorded[tick], save = false)
		step_end := time.tick_now()
		sim.save(simulation)
		save_end := time.tick_now()
		forward[tick] = sim.checksum(simulation)
		checksum_end := time.tick_now()
		if timed {
			if tick % sim.DEEP_CHECKSUM_EVERY == 0 {
				checksum_deep_us[deep_checksums] = micros(save_end, checksum_end)
				encode_start := time.tick_now()
				_ = sim.snapshot_encode_into(simulation, tick - 1, &image)
				encode_end := time.tick_now()
				snapshot_encode_us[deep_checksums] = micros(encode_start, encode_end)
				_ = sim.snapshot_keep(simulation, tick - 1, deep_checksums % sim.KEEP_SLOTS)
				snapshot_keep_us[deep_checksums] = micros(encode_end, time.tick_now())
				deep_checksums += 1
			} else {
				checksum_us[checksums] = micros(save_end, checksum_end)
				checksums += 1
			}
			step_us[steps] = micros(step_start, step_end)
			save_us[steps] = micros(step_end, save_end)
			steps += 1
		}
		if tick < window {
			continue
		}
		base := tick - window
		// The final-tick burst first: it leaves base + 1 ..< tick unsaved, and the saved re-sim after it saves
		// them again, so the next tick's restore target is in the ring.
		ok := sim.restore(simulation, base)
		assert(ok)
		final_start := time.tick_now()
		for resim in base + 1 ..< tick {
			sim.step(simulation, &recorded[resim], save = false)
		}
		sim.step(simulation, &recorded[tick])
		final_end := time.tick_now()
		if sim.checksum(simulation) != forward[tick] {
			result.mismatches += 1
		}
		restore_start := time.tick_now()
		ok = sim.restore(simulation, base)
		restore_end := time.tick_now()
		assert(ok)
		for resim in base + 1 ..= tick {
			sim.step(simulation, &recorded[resim])
		}
		resim_end := time.tick_now()
		if sim.checksum(simulation) != forward[tick] {
			result.mismatches += 1
		}
		if timed {
			restore_us[rollbacks] = micros(restore_start, restore_end)
			resim_us[rollbacks] = micros(restore_end, resim_end)
			resim_final_us[rollbacks] = micros(final_start, final_end)
			rollbacks += 1
		}
	}
	result.step = stat_of(step_us[:steps])
	result.save = stat_of(save_us[:steps])
	result.restore = stat_of(restore_us[:rollbacks])
	result.resim = stat_of(resim_us[:rollbacks])
	result.resim_final = stat_of(resim_final_us[:rollbacks])
	result.checksum = stat_of(checksum_us[:checksums])
	result.checksum_deep = stat_of(checksum_deep_us[:deep_checksums])
	result.snapshot_encode = stat_of(snapshot_encode_us[:deep_checksums])
	result.snapshot_keep = stat_of(snapshot_keep_us[:deep_checksums])
	result.save_bytes = sim.save_size(simulation)
	result.snapshot_bytes = sim.snapshot_size(simulation)
	bench_zones(game, entities, seed, recorded, warmup, &result)
	return
}

// The zones as the bench prints them: {"<zone>":{"mean":..,"p99":..},...} (temp-allocated).
@(private)
zones_json :: proc(zones: []Zone_Stat) -> string {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, '{')
	for zone, i in zones {
		if i > 0 do append(&out, ',')
		append(&out, fmt.tprintf(`"%s":%s`, zone.name, stat_json(zone.stat)))
	}
	append(&out, '}')
	return string(out[:])
}
