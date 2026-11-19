// The nav row of `uni bench`: unified:nav on the yard Godot baked (tests/godot/levels/nav_yard.tscn: a deck, a bridge
// over a corridor, ramps, crates; all triangles, as Godot bakes). The mesh's build (once, in world_create), a field's
// build (a miss of the memo: a new goal), and WALKERS walkers steering and moving along fields toward the players'
// polygons every tick, as a horde does: what a tick and a re-simulation to the prediction cap pay. One JSON line.
package nav_bench

import "core:fmt"
import "core:slice"
import "core:time"

import "unified:dmath"
import "unified:level"
import "unified:nav"
import "unified:sim"

YARD :: #load("../../godot/levels/nav_yard.level")
ROUNDS :: 400
WALKERS :: 64
GOALS :: 4 // the players' polygons the walkers chase
TICKS :: 600

stat_json :: proc(samples: []f64) -> string {
	sum := 0.0
	for sample in samples do sum += sample
	slice.sort(samples)
	return fmt.tprintf(
		`{{"mean":%.3f,"p99":%.3f}}`,
		sum / f64(len(samples)),
		samples[max((99 * len(samples) + 99) / 100 - 1, 0)],
	)
}

micros :: proc(from, to: time.Tick) -> f64 {
	return time.duration_microseconds(time.tick_diff(from, to))
}

main :: proc() {
	loaded, ok := level.load(YARD)
	assert(ok, "the yard loads")
	build_us := make([]f64, ROUNDS)
	mesh: nav.Mesh
	for round in 0 ..< ROUNDS {
		started := time.tick_now()
		built, err := nav.build(loaded.nav_vertices, loaded.nav_polygons)
		build_us[round] = micros(started, time.tick_now())
		assert(err == .None)
		if round + 1 < ROUNDS do nav.destroy(&built)
		else do mesh = built
	}
	polygons := nav.poly_count(&mesh)
	// a field per goal, each built fresh: the cost of a miss
	field_us := make([]f64, ROUNDS)
	scratch := nav.fields_make(&mesh, 1)
	for round in 0 ..< ROUNDS {
		goal := nav.Poly(round * 7 % polygons)
		started := time.tick_now()
		nav.field_compute(&mesh, goal, &scratch.slots[0], &scratch.heap)
		field_us[round] = micros(started, time.tick_now())
	}
	// walkers from every polygon's centre toward GOALS polygons, the memo holding them all (hits, as a horde chasing
	// the players sees), restarted when they arrive
	fields := nav.fields_make(&mesh, GOALS)
	rng := sim.rng_seed(3)
	goals: [GOALS]nav.Poly
	for &goal in goals do goal = nav.Poly(sim.rng_below(&rng, u32(polygons)))
	Walker :: struct {
		poly: nav.Poly,
		pos:  [3]f32,
	}
	walkers: [WALKERS]Walker
	for &walker, i in walkers {
		walker.poly = nav.Poly(i * 13 % polygons)
		walker.pos = mesh.centers[walker.poly]
	}
	tick_us := make([]f64, TICKS)
	arrivals := 0
	for tick in 0 ..< TICKS {
		started := time.tick_now()
		for &walker, i in walkers {
			goal_poly := goals[i % GOALS]
			goal := mesh.centers[goal_poly]
			target := nav.steer(&mesh, nav.field(&fields, goal_poly), walker.poly, walker.pos, goal)
			step := dmath.clamp_length2(target.xz - walker.pos.xz, f32(4.0 / 64))
			walker.poly, walker.pos = nav.move(&mesh, walker.poly, walker.pos, walker.pos + {step.x, 0, step.y})
			if dmath.dist_sq3(walker.pos, goal) < 0.01 {
				arrivals += 1
				walker.poly = nav.Poly(sim.rng_below(&rng, u32(polygons)))
				walker.pos = mesh.centers[walker.poly]
			}
		}
		tick_us[tick] = micros(started, time.tick_now())
	}
	fmt.printfln(
		`{{"mode":"nav-bench","polygons":%d,"vertices":%d,"build_us":%s,"field_us":%s,"walkers":%d,"walkers_us":%s,"arrivals":%d}}`,
		polygons,
		len(mesh.vertices),
		stat_json(build_us),
		stat_json(field_us),
		WALKERS,
		stat_json(tick_us),
		arrivals,
	)
}
