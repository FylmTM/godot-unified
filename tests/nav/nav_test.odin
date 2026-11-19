// unified:nav on hand-made meshes and on a level Godot baked (tests/godot/levels/nav_yard.tscn: a yard with a deck
// on pillars and a ramp up to it, a bridge over a walled corridor with a ramp at each end, crates and a tank; `uni
// bake --nav` baked it, as the editor does): building, point location on stacked floors, nearest points, moves that
// never leave the mesh, memoized fields equal to fresh ones, walkers reaching goals in 3D, and a pinned walker run that
// every platform must reproduce bit for bit.
package test_nav

import "core:log"
import "core:testing"

import "unified:dmath"
import "unified:level"
import "unified:nav"
import "unified:sim"

// tests/godot/levels/nav_yard.tscn as exported: its navigation section.
YARD :: #load("../godot/levels/nav_yard.level")

// The yard's mesh (destroy with nav.destroy), and the agent it was baked for.
yard :: proc(t: ^testing.T) -> (mesh: nav.Mesh, agent: level.Nav_Agent, ok: bool) {
	loaded, loaded_ok := level.load(YARD)
	defer level.destroy(&loaded)
	if !testing.expect(t, loaded_ok, "the yard loads") do return
	if !testing.expect(t, len(loaded.nav_polygons) > 100, "the yard has a baked mesh") do return
	err: nav.Build_Error
	mesh, err = nav.build(loaded.nav_vertices, loaded.nav_polygons)
	if !testing.expect_value(t, err, nav.Build_Error.None) do return
	return mesh, loaded.nav_agent, true
}

// Two unit squares side by side and a triangle on the second's far edge, written clockwise and counter-clockwise.
@(private = "file")
STRIP_VERTICES := [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}, {2, 0, 0}, {2, 0, 1}, {3, 0, 0.5}}

@(test)
build_links_polygons_by_shared_indices :: proc(t: ^testing.T) {
	polygons := [][]u32{{0, 1, 2, 3}, {2, 1, 4, 5}, {4, 6, 5}}
	mesh, err := nav.build(STRIP_VERTICES, polygons)
	defer nav.destroy(&mesh)
	testing.expect_value(t, err, nav.Build_Error.None)
	testing.expect_value(t, nav.poly_count(&mesh), 3)
	neighbours: [3][dynamic]nav.Poly
	defer for list in neighbours do delete(list)
	for p in 0 ..< 3 {
		for k in mesh.first[p] ..< mesh.first[p + 1] do if mesh.across[k] != nav.NO_POLY do append(&neighbours[p], mesh.across[k])
	}
	testing.expect(t, len(neighbours[0]) == 1 && neighbours[0][0] == 1, "the first square meets the second")
	testing.expect(t, len(neighbours[1]) == 2, "the second meets both")
	testing.expect(t, len(neighbours[2]) == 1 && neighbours[2][0] == 1, "the triangle meets the second square")
	// every polygon is counter-clockwise seen from above, whichever way it was written
	for p in 0 ..< 3 {
		first := mesh.first[p]
		a, b, c :=
			mesh.vertices[mesh.corners[first]],
			mesh.vertices[mesh.corners[first + 1]],
			mesh.vertices[mesh.corners[first + 2]]
		testing.expectf(t, nav.area2(a, b, c) > 0, "polygon %d counter-clockwise", p)
	}
	testing.expect_value(t, nav.locate(&mesh, {0.5, 0, 0.5}, 1), nav.Poly(0))
	testing.expect_value(t, nav.locate(&mesh, {2.5, 0, 0.5}, 1), nav.Poly(2))
	testing.expect_value(t, nav.locate(&mesh, {2.5, 3, 0.5}, 1), nav.NO_POLY) // too far above
	testing.expect_value(t, nav.locate(&mesh, {5, 0, 0.5}, 1), nav.NO_POLY) // off the mesh
	poly, point := nav.nearest(&mesh, {3.5, 0.2, 0.5}, 1)
	testing.expect(t, poly == 2 && dmath.dist_sq3(point, {3, 0, 0.5}) < 1e-6, "the triangle's tip is nearest")
	poly, _ = nav.nearest(&mesh, {6, 0, 0}, 1)
	testing.expect_value(t, poly, nav.NO_POLY)
}

@(test)
build_refuses_what_it_cannot_walk :: proc(t: ^testing.T) {
	nan := transmute(f32)u32(0x7FC0_0000)
	Case :: struct {
		vertices: [][3]f32,
		polygons: [][]u32,
		cell:     f32,
		want:     nav.Build_Error,
	}
	vertical := [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}
	bad_vertex := [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, nan, 1}}
	cases := []Case {
		{STRIP_VERTICES, {{0, 1}}, 2, .Small_Polygon},
		{STRIP_VERTICES, {{0, 1, 9}}, 2, .Bad_Index},
		{vertical, {{0, 1, 2, 3}}, 2, .Flat_Polygon},
		{bad_vertex, {{0, 1, 2}}, 2, .Bad_Vertex},
		{STRIP_VERTICES, {{0, 1, 2}, {1, 0, 3}, {0, 1, 5}}, 2, .Crowded_Edge},
		{STRIP_VERTICES, {{0, 1, 2}}, 0, .Bad_Cell},
		{STRIP_VERTICES, {{0, 1, 2}}, 1e-9, .Bad_Cell},
	}
	for c, i in cases {
		mesh, err := nav.build(c.vertices, c.polygons, c.cell)
		testing.expectf(t, err == c.want, "case %d: %v, want %v", i, err, c.want)
		nav.destroy(&mesh)
	}
}

// On stacked floors the height picks the floor: the yard under the deck and the deck, the corridor under the bridge
// and the bridge. The agent the yard was baked for comes with it.
@(test)
locate_on_stacked_floors :: proc(t: ^testing.T) {
	mesh, agent, ok := yard(t)
	if !ok do return
	defer nav.destroy(&mesh)
	testing.expect_value(t, agent, level.Nav_Agent{0.4, 1.8, 0.3})
	Spot :: struct {
		pos:    [3]f32,
		height: f32,
	}
	for spot in ([]Spot{{{8, 0, 8}, 0}, {{8, 4, 8}, 4}, {{-8, 0, -10}, 0}, {{-8, 3.3, -10}, 3.3}}) {
		poly := nav.locate(&mesh, spot.pos, 0.5)
		testing.expectf(t, poly != nav.NO_POLY, "a polygon at %v", spot.pos)
		if poly == nav.NO_POLY do continue
		height := nav.height_at(&mesh, poly, spot.pos)
		// Godot's bake floats the mesh a cell or two (its cell_height, 0.25 m) above the floor
		testing.expectf(
			t,
			height > spot.height && height - spot.height < 0.6,
			"at %v the floor is at %v, want about %v",
			spot.pos,
			height,
			spot.height,
		)
	}
	// a pillar's footprint is off the mesh; the nearest point is beside it, on the ground
	testing.expect_value(t, nav.locate(&mesh, {2.5, 0, 2.5}, 0.5), nav.NO_POLY)
	poly, point := nav.nearest(&mesh, {2.5, 0, 2.5}, 2)
	testing.expectf(
		t,
		poly != nav.NO_POLY && point.y < 0.6 && dmath.dist_sq2(point.xz, {2.5, 2.5}) < 1.5,
		"beside the pillar: %v",
		point,
	)
}

// Moves toward random points from random places stay on the mesh: each ends inside the polygon it reports, at its
// height.
@(test)
moves_never_leave_the_mesh :: proc(t: ^testing.T) {
	mesh, _, ok := yard(t)
	if !ok do return
	defer nav.destroy(&mesh)
	rng := sim.rng_seed(5)
	failures := 0
	for _ in 0 ..< 4000 {
		poly := nav.Poly(sim.rng_below(&rng, u32(nav.poly_count(&mesh))))
		from := mesh.centers[poly]
		to := from + {sim.rng_f32(&rng) * 12 - 6, 0, sim.rng_f32(&rng) * 12 - 6}
		end_poly, end := nav.move(&mesh, poly, from, to)
		inside := nav.contains(&mesh, end_poly, end)
		on := abs(nav.height_at(&mesh, end_poly, end) - end.y) < 1e-4
		if !inside || !on {
			if failures == 0 do log.errorf("from %v on %v toward %v: ended at %v on %v", from, poly, to, end, end_poly)
			failures += 1
		}
	}
	testing.expectf(t, failures == 0, "%v moves left the mesh", failures)
}

// A field is a pure function of the mesh and the goal: the memo's, through hits and evictions, equals a fresh one bit
// for bit.
@(test)
fields_cached_equal_fresh :: proc(t: ^testing.T) {
	mesh, _, ok := yard(t)
	if !ok do return
	defer nav.destroy(&mesh)
	fields := nav.fields_make(&mesh, 3)
	defer nav.fields_destroy(&fields)
	fresh := nav.fields_make(&mesh, 1)
	defer nav.fields_destroy(&fresh)
	rng := sim.rng_seed(9)
	goals: [6]nav.Poly
	for &goal in goals do goal = nav.Poly(sim.rng_below(&rng, u32(nav.poly_count(&mesh))))
	mismatches := 0
	for _ in 0 ..< 200 {
		goal := goals[sim.rng_below(&rng, len(goals))]
		cached := nav.field(&fields, goal)
		nav.field_compute(&mesh, goal, &fresh.slots[0], &fresh.heap)
		for p in 0 ..< nav.poly_count(&mesh) {
			if transmute(u32)cached.cost[p] != transmute(u32)fresh.slots[0].cost[p] ||
			   cached.next[p] != fresh.slots[0].next[p] {
				mismatches += 1
			}
		}
	}
	testing.expectf(t, mismatches == 0, "%v entries differ between cached and fresh fields", mismatches)
	testing.expect(t, nav.field(&fields, nav.NO_POLY) == nil)
}

// A walker on a field: steer, then move at most `speed * dt` toward where it heads.
@(private = "file")
Walker :: struct {
	poly:    nav.Poly,
	pos:     [3]f32,
	arrived: bool,
}

@(private = "file")
walk :: proc(mesh: ^nav.Mesh, fields: ^nav.Fields, walker: ^Walker, goal: [3]f32, goal_poly: nav.Poly) -> f32 {
	field := nav.field(fields, goal_poly)
	target := nav.steer(mesh, field, walker.poly, walker.pos, goal)
	step := target.xz - walker.pos.xz
	SPEED :: f32(4)
	DT :: f32(1.0 / 64)
	step = dmath.clamp_length2(step, SPEED * DT)
	before := walker.pos.y
	walker.poly, walker.pos = nav.move(mesh, walker.poly, walker.pos, walker.pos + {step.x, 0, step.y})
	if dmath.dist_sq3(walker.pos, goal) < 0.01 do walker.arrived = true
	return abs(walker.pos.y - before)
}

// The yard's walkers and their goals: from the deck to the far corner of the yard (down the ramp), from under the deck
// onto it (up the ramp), from the corridor under the bridge onto the bridge (up a ramp at either end), and from the
// bridge down into the corridor.
@(private = "file")
Trip :: struct {
	from, to: [3]f32,
}

@(private = "file")
TRIPS := []Trip {
	{{6, 4, 10}, {-20, 0, 20}},
	{{10, 4, 6}, {20, 0, -20}},
	{{6, 0, 10}, {8, 4, 12}},
	{{-8, 0, -14}, {-8, 3.3, -10}},
	{{-8, 3.3, -10}, {-8, 0, -6}},
	{{-20, 0, 20}, {12, 4, 12}},
	{{18, 0, 18}, {-16, 0, -18}},
	{{0, 0, -20}, {-8, 3.3, -10}},
}

// Every trip arrives, never changing height by more than the bake's max climb (0.3 m) in a tick (no walker falls through
// a floor or climbs a wall), and the run's positions hash to the pinned value on every platform.
WALK_HASH :: u64(0x2a45bb4c29108cf1)

@(test)
walkers_reach_their_goals_and_reproduce :: proc(t: ^testing.T) {
	mesh, _, ok := yard(t)
	if !ok do return
	defer nav.destroy(&mesh)
	fields := nav.fields_make(&mesh, 4)
	defer nav.fields_destroy(&fields)
	walkers := make([]Walker, len(TRIPS))
	defer delete(walkers)
	goals := make([][3]f32, len(TRIPS))
	defer delete(goals)
	goal_polys := make([]nav.Poly, len(TRIPS))
	defer delete(goal_polys)
	for trip, i in TRIPS {
		// both ends on the mesh: the floor's point under them
		walkers[i].poly, walkers[i].pos = nav.nearest(&mesh, trip.from, 1)
		goal_polys[i], goals[i] = nav.nearest(&mesh, trip.to, 1)
		testing.expectf(t, walkers[i].poly != nav.NO_POLY && goal_polys[i] != nav.NO_POLY, "trip %d is on the mesh", i)
	}
	hash := u64(0xCBF29CE484222325)
	largest_jump: f32 = 0
	for _ in 0 ..< 64 * 30 {
		for &walker, i in walkers {
			if walker.arrived || walker.poly == nav.NO_POLY do continue
			largest_jump = dmath.max(largest_jump, walk(&mesh, &fields, &walker, goals[i], goal_polys[i]))
			for value in walker.pos do hash = (hash ~ u64(transmute(u32)value)) * 0x100000001B3
		}
	}
	for walker, i in walkers {
		testing.expectf(t, walker.arrived, "trip %d (%v to %v) ended at %v", i, TRIPS[i].from, TRIPS[i].to, walker.pos)
	}
	testing.expectf(t, largest_jump < 0.3, "a walker's height jumped %v in one tick", largest_jump)
	log.infof("%v: walk %016x", ODIN_ARCH, hash)
	testing.expectf(t, hash == WALK_HASH, "walk hash %016x, pinned %016x", hash, WALK_HASH)
}
