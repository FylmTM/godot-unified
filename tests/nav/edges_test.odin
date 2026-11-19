// unified:nav at its edges: moves along a shared edge, from corners and edges, from off the polygon; steer without a
// way; welding in build.
package test_nav

import "core:testing"

import "unified:dmath"
import "unified:nav"
import "unified:sim"

// Moves along a skewed edge two triangles share: each triangle's side test of the edge is the other's exact opposite,
// so a point near the line is never beyond it from both and every move arrives (a stall bounced between them).
@(test)
moves_along_a_shared_edge_arrive :: proc(t: ^testing.T) {
	vertices := [][3]f32{{0.1, 0, 0.3}, {5.7, 0, 3.9}, {0, 0, 4}, {6, 0, 0}}
	mesh, err := nav.build(vertices, {{0, 1, 2}, {0, 3, 1}})
	defer nav.destroy(&mesh)
	testing.expect_value(t, err, nav.Build_Error.None)
	rng := sim.rng_seed(11)
	misses := 0
	for _ in 0 ..< 10_000 {
		from := vertices[0] + (vertices[1] - vertices[0]) * sim.rng_f32(&rng)
		to := vertices[0] + (vertices[1] - vertices[0]) * sim.rng_f32(&rng)
		start := nav.Poly(sim.rng_below(&rng, 2))
		_, end := nav.move(&mesh, start, from, to)
		if dmath.dist_sq2(end.xz, to.xz) > 1e-8 do misses += 1
	}
	testing.expectf(t, misses == 0, "%v of 10000 moves along the shared edge fell short", misses)
}

// A walker something else moved off its polygon (a push, a crowd's separation) is moved from the polygon's nearest
// point: it ends inside the polygon move reports.
@(test)
a_move_from_off_the_polygon_ends_on_the_mesh :: proc(t: ^testing.T) {
	mesh, _, ok := yard(t)
	if !ok do return
	defer nav.destroy(&mesh)
	rng := sim.rng_seed(13)
	failures := 0
	for _ in 0 ..< 2000 {
		poly := nav.Poly(sim.rng_below(&rng, u32(nav.poly_count(&mesh))))
		from := mesh.centers[poly] + {sim.rng_f32(&rng) * 4 - 2, 0, sim.rng_f32(&rng) * 4 - 2}
		to := from + {sim.rng_f32(&rng) * 2 - 1, 0, sim.rng_f32(&rng) * 2 - 1}
		end_poly, end := nav.move(&mesh, poly, from, to)
		if !nav.contains(&mesh, end_poly, end) do failures += 1
	}
	testing.expectf(t, failures == 0, "%v moves from off their polygon ended off the mesh", failures)
}

// Moves that start on a corner or an edge: into each polygon around a corner, along and across an edge, and outward
// from a border corner; each ends inside the polygon it reports, and where it was headed when nothing is in the way.
@(test)
moves_from_corners_and_edges :: proc(t: ^testing.T) {
	mesh, _ := nav.build(STRIP_VERTICES, {{0, 1, 2, 3}, {2, 1, 4, 5}, {4, 6, 5}})
	defer nav.destroy(&mesh)
	Case :: struct {
		poly:     nav.Poly,
		from, to: [3]f32,
		ends_on:  nav.Poly,
		arrives:  bool,
	}
	cases := []Case {
		{0, {1, 0, 1}, {1.5, 0, 0.5}, 1, true}, // from the corner the squares share, into the second
		{1, {1, 0, 1}, {0.5, 0, 0.5}, 0, true}, // and back into the first
		{0, {1, 0, 0}, {1, 0, 1}, 0, true}, // along the shared edge
		{0, {1, 0, 0.5}, {2.5, 0, 0.5}, 2, true}, // from the edge, across the second square into the triangle
		{2, {2, 0, 0}, {0.5, 0, 0.9}, 0, true}, // from the triangle's corner, back across both
		{0, {0, 0, 0}, {-1, 0, 0.5}, 0, false}, // from a border corner outward: it slides and stays
	}
	for c, i in cases {
		end_poly, end := nav.move(&mesh, c.poly, c.from, c.to)
		testing.expectf(t, end_poly == c.ends_on, "case %d ends on %v, want %v", i, end_poly, c.ends_on)
		testing.expectf(t, nav.contains(&mesh, end_poly, end), "case %d ends inside its polygon: %v", i, end)
		if c.arrives do testing.expectf(t, dmath.dist_sq2(end.xz, c.to.xz) < 1e-8, "case %d arrives: %v", i, end)
	}
}

// steer without a field or a polygon, and toward a goal it can't reach, stays where it is; on the goal's polygon it
// heads straight for the goal.
@(test)
steer_stays_without_a_way :: proc(t: ^testing.T) {
	// a square, and another apart from it: an island
	vertices := [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}, {5, 0, 0}, {6, 0, 0}, {6, 0, 1}, {5, 0, 1}}
	mesh, _ := nav.build(vertices, {{0, 1, 2, 3}, {4, 5, 6, 7}})
	defer nav.destroy(&mesh)
	fields := nav.fields_make(&mesh, 1)
	defer nav.fields_destroy(&fields)
	pos := [3]f32{0.5, 0, 0.5}
	goal := [3]f32{5.5, 0, 0.5}
	testing.expect_value(t, nav.steer(&mesh, nil, 0, pos, goal), pos)
	island := nav.field(&fields, 1)
	testing.expect_value(t, nav.steer(&mesh, island, nav.NO_POLY, pos, goal), pos)
	testing.expect_value(t, island.cost[0], nav.UNREACHABLE)
	testing.expect_value(t, nav.steer(&mesh, island, 0, pos, goal), pos)
	testing.expect_value(t, nav.steer(&mesh, island, 1, {5.2, 0, 0.2}, goal), goal)
}

// build welds vertices at exactly the same position, so a generated mesh that repeats them still links.
@(test)
build_welds_repeated_vertices :: proc(t: ^testing.T) {
	// two squares side by side, each with its own copy of the shared edge's vertices
	vertices := [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}, {1, 0, 0}, {2, 0, 0}, {2, 0, 1}, {1, 0, 1}}
	mesh, err := nav.build(vertices, {{0, 1, 2, 3}, {4, 5, 6, 7}})
	defer nav.destroy(&mesh)
	testing.expect_value(t, err, nav.Build_Error.None)
	links := 0
	for across in mesh.across do links += int(across != nav.NO_POLY)
	testing.expect_value(t, links, 2)
	end_poly, _ := nav.move(&mesh, 0, {0.5, 0, 0.5}, {1.5, 0, 0.5})
	testing.expect_value(t, end_poly, nav.Poly(1))
}
