// src/level/SPEC.md, 2D levels: version 2 records px_per_m, other versions are refused, Vector2 props read
// back, and the exporter's 2D fixture (tests/godot/levels/level_2d.tscn, exported by `uni test --suite godot-bindings`)
// builds the bodies it was drawn with: metres, z = 0, rotations about +Z.
package test_level

import "core:math"
import "core:testing"

import "unified:level"
import "unified:physics"

// tests/godot/levels/level_2d.tscn as exported (32 px per metre, 0.5 m deep).
FIXTURE_2D :: #load("../godot/levels/level_2d.level")

@(test)
round_trip_2d :: proc(t: ^testing.T) {
	square := [][3]f32{{-1, -1, -0.5}, {-1, -1, 0.5}, {1, -1, -0.5}, {1, -1, 0.5}, {0, 1, -0.5}, {0, 1, 0.5}}
	shapes := []level.Shape {
		{
			kind   = .Hull,
			rot    = {0, 0, 0, 1},
			points = square,
		},
	}
	bodies := []level.Body {
		{
			name   = "wall",
			pos    = {2, 3, 0},
			rot    = {0, 0, 0.38268343, 0.9238795},
			shapes = shapes,
		},
	}
	props := []level.Prop {
		{
			key  = "dir",
			type = .Vec3,
			v    = {1.5, -2, 0},
		},
	}
	markers := []level.Marker {
		{
			kind  = "spawn",
			name  = "S",
			rot   = {0, 0, 0, 1},
			scale = {1, 1, 1},
			props = props,
		},
	}
	data := level.encode(bodies, markers, 64)
	defer delete(data)
	loaded, ok := level.load(data)
	defer level.destroy(&loaded)
	testing.expect(t, ok)
	if !ok do return
	testing.expect_value(t, loaded.px_per_m, 64)
	marker := &loaded.markers[0]
	testing.expect(t, level.prop_vec2(marker, "dir") == {1.5, -2})
	testing.expect(t, level.prop_vec3(marker, "dir") == {1.5, -2, 0})
	testing.expect(t, level.prop_vec2(marker, "nope", {7, 8}) == {7, 8})
	again := level.encode(loaded.bodies, loaded.markers, loaded.px_per_m)
	defer delete(again)
	testing.expect(t, string(again) == string(data))
}

// Readers accept only the current version (src/sim/SPEC.md, format versions): 1 (no px_per_m) and the next one are
// refused.
@(test)
other_versions_refused :: proc(t: ^testing.T) {
	file := fixture()
	defer delete(file)
	for version in ([]u8{0, 1, 3}) {
		bad := make([]u8, len(file), context.temp_allocator)
		copy(bad, file)
		bad[4] = version
		_, bad_ok := level.load(bad)
		testing.expectf(t, !bad_ok, "version %d loaded", version)
	}
}

near :: proc(a, b: [3]f32, eps: f32 = 1e-4) -> bool {
	return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
}

qz :: proc(angle: f64) -> [4]f32 {
	return {0, 0, f32(math.sin(angle / 2)), f32(math.cos(angle / 2))}
}

// The same rotation: q or -q.
near_q :: proc(a, b: [4]f32) -> bool {
	return near(a.xyz, b.xyz) && abs(a.w - b.w) < 1e-4 || near(a.xyz, -b.xyz) && abs(a.w + b.w) < 1e-4
}

// The fixture's records, as drawn (the scene's numbers in pixels / 32).
@(test)
exported_2d_fixture :: proc(t: ^testing.T) {
	loaded, ok := level.load(FIXTURE_2D)
	defer level.destroy(&loaded)
	testing.expect(t, ok)
	if !ok do return
	testing.expect_value(t, loaded.px_per_m, 32)
	testing.expect_value(t, len(loaded.bodies), 4) // Ground, Shapes, Walls, Tiles (Decor has no collision)
	testing.expect_value(t, len(loaded.markers), 2)
	if len(loaded.bodies) != 4 || len(loaded.markers) != 2 do return

	ground := &loaded.bodies[0]
	testing.expect_value(t, ground.name, "Ground")
	testing.expect(t, ground.pos == {0, 10, 0} && ground.rot == {0, 0, 0, 1})
	testing.expect(
		t,
		abs(ground.friction - 0.8) < 1e-6 &&
		ground.restitution == 0.25 &&
		ground.category == 4 &&
		ground.material == 7,
	)
	testing.expect(
		t,
		len(ground.shapes) == 1 && ground.shapes[0].kind == .Box && ground.shapes[0].half == {10, 0.5, 0.25},
	)

	// Under a parent at (320, 0) px turned 90° and scaled 2: the body is at (10, 4) m turned 90°, the scale
	// baked into its shapes.
	shapes_body := &loaded.bodies[1]
	testing.expect_value(t, shapes_body.name, "Shapes")
	testing.expectf(t, near(shapes_body.pos, {10, 4, 0}), "%v", shapes_body.pos)
	testing.expectf(t, near_q(shapes_body.rot, qz(math.PI / 2)), "%v", shapes_body.rot)
	testing.expect_value(t, len(shapes_body.shapes), 4)
	if len(shapes_body.shapes) == 4 {
		ball, pill, wedge, box :=
			shapes_body.shapes[0], shapes_body.shapes[1], shapes_body.shapes[2], shapes_body.shapes[3]
		testing.expect(t, ball.kind == .Sphere && abs(ball.radius - 1) < 1e-6 && ball.pos == {})
		testing.expect(t, pill.kind == .Capsule && near(pill.pos, {2, 0, 0}) && near_q(pill.rot, {0, 0, 0, 1}))
		testing.expectf(t, abs(pill.radius - 0.5) < 1e-6 && abs(pill.half_height - 1) < 1e-6, "%v", pill)
		testing.expect(t, wedge.kind == .Hull && len(wedge.points) == 6)
		if len(wedge.points) == 6 {
			testing.expectf(t, near(wedge.points[0], {-3, -1, -0.25}), "%v", wedge.points)
			testing.expect(t, near(wedge.points[1], {-3, -1, 0.25}))
		}
		testing.expect(t, box.kind == .Box && near(box.pos, {0, 2, 0}) && near(box.half, {0.5, 1, 0.25}))
		testing.expectf(t, near_q(box.rot, qz(math.PI / 4)), "%v", box.rot)
	}

	walls := &loaded.bodies[2]
	testing.expect_value(t, walls.name, "Walls")
	testing.expect(t, walls.pos == {-10, 0, 0})
	testing.expectf(t, len(walls.shapes) >= 2, "the L splits into convex parts: %d", len(walls.shapes))
	for shape in walls.shapes do testing.expect(t, shape.kind == .Hull)

	tiles := &loaded.bodies[3]
	testing.expect_value(t, tiles.name, "Tiles")
	testing.expect(t, tiles.pos == {0, 0.5, 0} && tiles.category == 2 && abs(tiles.friction - 0.3) < 1e-6)
	testing.expect_value(t, len(tiles.shapes), 4) // one convex polygon per cell
	if len(tiles.shapes) == 4 {
		// Cells sorted by (y, x): (4, 7) first, then (-1, 8): a square centred at (-16, 272) px in the layer.
		testing.expect_value(t, len(tiles.shapes[0].points), 6)
		lo, hi := [3]f32{1e9, 1e9, 1e9}, [3]f32{-1e9, -1e9, -1e9}
		for point in tiles.shapes[1].points {
			lo = {min(lo.x, point.x), min(lo.y, point.y), min(lo.z, point.z)}
			hi = {max(hi.x, point.x), max(hi.y, point.y), max(hi.z, point.z)}
		}
		testing.expectf(t, near(lo, {-1, 8, -0.25}) && near(hi, {0, 9, 0.25}), "%v %v", lo, hi)
	}

	spawn := &loaded.markers[0]
	testing.expect(t, spawn.kind == "spawn" && spawn.name == "Spawn")
	testing.expectf(t, near(spawn.pos, {6, 0, 0}), "%v", spawn.pos)
	testing.expectf(t, near_q(spawn.rot, qz(math.PI / 2 + 0.25)), "%v", spawn.rot)
	testing.expectf(t, near(spawn.scale, {2, 2, 1}), "%v", spawn.scale)
	testing.expect(t, level.prop_vec2(spawn, "push") == {1.5, -2}) // raw, not in metres
	testing.expect_value(t, level.prop_f32(spawn, "speed"), 2.5)
	testing.expect_value(t, level.prop_int(spawn, "lives"), 3)
	testing.expect_value(t, level.prop_string(spawn, "label"), "left")
	testing.expect_value(t, level.prop_ref(spawn, "goal"), 1)
	testing.expect_value(t, len(spawn.path), 3)
	if len(spawn.path) == 3 {
		// The Path2D's points in world metres: (32, 0) px through the spawn's transform (scale 2).
		angle := math.PI / 2 + 0.25
		want := [3]f32{6 + f32(2 * math.cos(angle)), f32(2 * math.sin(angle)), 0}
		testing.expect(t, near(spawn.path[0], {6, 0, 0}))
		testing.expectf(t, near(spawn.path[1], want), "%v, want %v", spawn.path[1], want)
	}
	goal := &loaded.markers[1]
	testing.expect(t, goal.kind == "goal" && near(goal.pos, {-2, 1, 0}))
	// Mirrored on x: Godot's decomposition reads it as a half turn with y mirrored.
	testing.expectf(t, near(goal.scale, {1, -1, 1}) && near_q(goal.rot, qz(math.PI)), "%v %v", goal.scale, goal.rot)
}

// physics.create_static on the fixture: ordinary static bodies at z = 0, each where the scene drew it.
@(test)
create_static_2d :: proc(t: ^testing.T) {
	loaded, ok := level.load(FIXTURE_2D)
	defer level.destroy(&loaded)
	testing.expect(t, ok)
	if !ok do return
	world := physics.create()
	defer physics.destroy(world)
	count, problem := physics.create_static(world, &loaded)
	testing.expect_value(t, count, 4)
	testing.expect_value(t, problem, "")
	// A ray into the plane (+z) at (x, y): the front face it hits (z = -depth/2 for boxes and hulls).
	front :: proc(world: ^physics.World, x, y: f32) -> (z: f32, hit: physics.Hit, ok: bool) {
		hit, ok = physics.world_cast_ray_closest(world, {x, y, -5}, {0, 0, 10})
		return hit.point.z, hit, ok
	}
	expect_front :: proc(t: ^testing.T, world: ^physics.World, x, y, want: f32, loc := #caller_location) {
		z, _, ok := front(world, x, y)
		testing.expectf(t, ok && abs(z - want) < 1e-3, "at (%v, %v): %v %v, want %v", x, y, ok, z, want, loc = loc)
	}
	expect_miss :: proc(t: ^testing.T, world: ^physics.World, x, y: f32, loc := #caller_location) {
		z, _, ok := front(world, x, y)
		testing.expectf(t, !ok, "at (%v, %v): hit at z %v, want nothing", x, y, z, loc = loc)
	}
	// Ground: 20 x 1 m centred at (0, 10).
	expect_front(t, world, -9.9, 9.6, -0.25)
	expect_miss(t, world, 0, 10.6)
	_, ground_hit, _ := front(world, 0, 10)
	testing.expect_value(t, ground_hit.material, 7)
	ground, _ := physics.resolve(world, ground_hit.body)
	ground_pos := physics.body_position(world, ground)
	testing.expect(t, ground_pos == {0, 10, 0})
	// Shapes, turned 90° at (10, 4): the ball (radius 1) at its origin, the capsule's centre 2 m along the
	// body's +x = world +y, lying along world x (the body's local y), the wedge's tip at (9, 2), the box (0.5 x 1
	// half, turned 45° more) 2 m along the body's +y = world -x.
	expect_front(t, world, 10, 4, -1)
	expect_front(t, world, 10, 6, -0.5)
	expect_front(t, world, 11.3, 6, -0.4) // 0.3 m past the segment's end
	expect_miss(t, world, 10, 6.7)
	expect_front(t, world, 9.2, 2, -0.25)
	expect_miss(t, world, 8.8, 2)
	expect_front(t, world, 8, 4, -0.25)
	shapes_body, _ := physics.resolve(world, front_body(world, 10, 4))
	sid := physics.body_rotation(world, shapes_body)
	testing.expectf(t, near_q(sid, qz(math.PI / 2)), "%v", sid)
	// Walls: the L at (-10, 0): its top arm and its stem, not the notch.
	expect_front(t, world, -8.5, 0.5, -0.25)
	expect_front(t, world, -9.5, 2.5, -0.25)
	expect_miss(t, world, -8.5, 2)
	// Tiles: squares centred at (-0.5, 9), (2.5, 9), (3.5, 9); the flipped slope fills the lower left of
	// (4..5, 7.5..8.5).
	expect_front(t, world, -0.5, 9, -0.25)
	expect_front(t, world, 3.5, 9, -0.25)
	expect_miss(t, world, 1.5, 9)
	expect_front(t, world, 4.2, 8.3, -0.25)
	expect_miss(t, world, 4.8, 7.7)
}

front_body :: proc(world: ^physics.World, x, y: f32) -> physics.Body_Link {
	hit, _ := physics.world_cast_ray_closest(world, {x, y, -5}, {0, 0, 10})
	return hit.body
}
