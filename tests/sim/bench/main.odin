// The grid row of `uni bench`: sim.Grid apart from any game, at a horde's scale. Points scattered over 30 × 30 cells of
// 2 m (a 60 m arena), drifting a little every round; each round rebuilds the grid from them (grid_begin, an add per
// point in index order, grid_end) and runs a neighbour pass (every point's grid_near, counting the others within one
// cell). A rollback re-simulates up to the prediction cap, so a pass that rebuilds its grid pays the rebuild that many
// times in one frame. One JSON line.
package sim_bench

import "core:fmt"
import "core:slice"
import "core:time"

import "unified:sim"

COLUMNS :: 30
CELL :: f32(2)
ORIGIN :: -COLUMNS * CELL / 2
MAX_POINTS :: 4096
ROUNDS :: 400

Grid :: sim.Grid(COLUMNS * COLUMNS, MAX_POINTS)

Stat :: struct {
	mean, p99: f64,
}

stat_json :: proc(samples: []f64) -> string {
	sum := 0.0
	for sample in samples do sum += sample
	slice.sort(samples)
	return fmt.tprintf(
		`{{"mean":%.2f,"p99":%.2f}}`,
		sum / f64(len(samples)),
		samples[max((99 * len(samples) + 99) / 100 - 1, 0)],
	)
}

micros :: proc(from, to: time.Tick) -> f64 {
	return time.duration_microseconds(time.tick_diff(from, to))
}

// Rebuild and neighbour-pass times for `count` points: two JSON fields.
measure :: proc(grid: ^Grid, count: int) -> (rebuild, near: string, neighbours: int) {
	points := make([][2]f32, count, context.temp_allocator)
	rng := sim.rng_seed(u64(count))
	for &point in points do point = {sim.rng_f32(&rng) * COLUMNS * CELL + ORIGIN, sim.rng_f32(&rng) * COLUMNS * CELL + ORIGIN}
	rebuild_us := make([]f64, ROUNDS, context.temp_allocator)
	near_us := make([]f64, ROUNDS, context.temp_allocator)
	for round in 0 ..< ROUNDS {
		for &point in points do point += {sim.rng_f32(&rng) - 0.5, sim.rng_f32(&rng) - 0.5} * 0.2
		started := time.tick_now()
		sim.grid_begin(grid, {ORIGIN, ORIGIN}, CELL, COLUMNS, COLUMNS)
		for point, i in points do sim.grid_add(grid, i32(i), point)
		sim.grid_end(grid)
		built := time.tick_now()
		found := 0
		for point, i in points {
			for row in sim.grid_near(grid, point) {
				for other in row {
					if other == i32(i) do continue
					away := points[other] - point
					if away.x * away.x + away.y * away.y < CELL * CELL do found += 1
				}
			}
		}
		rebuild_us[round], near_us[round] = micros(started, built), micros(built, time.tick_now())
		neighbours = found
	}
	return stat_json(rebuild_us), stat_json(near_us), neighbours
}

main :: proc() {
	grid := new(Grid)
	small_rebuild, small_near, small_found := measure(grid, 1200)
	large_rebuild, large_near, large_found := measure(grid, MAX_POINTS)
	fmt.printfln(
		`{{"cells":%d,"small":{{"points":1200,"rebuild_us":%s,"near_us":%s,"neighbours":%d}},"large":{{"points":%d,"rebuild_us":%s,"near_us":%s,"neighbours":%d}}}}`,
		COLUMNS * COLUMNS,
		small_rebuild,
		small_near,
		small_found,
		MAX_POINTS,
		large_rebuild,
		large_near,
		large_found,
	)
}
