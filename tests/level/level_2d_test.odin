// src/level/SPEC.md, 2D levels: version 2 records px_per_m, version 1 still loads, Vector2 props read
// back, and the exporter's 2D fixture (tests/godot/levels/level_2d.tscn, exported by `uni test --suite godot-bindings`)
// builds the bodies it was drawn with: metres, z = 0, rotations about +Z.
package test_level

import "core:math"
import "core:testing"

import b3 "unified:box3d"
import "unified:level"
import "unified:physics"

// tests/godot/levels/level_2d.tscn as exported (32 px per metre, 0.5 m deep).
FIXTURE_2D :: #load("../godot/levels/level_2d.level")

@(test)
round_trip_2d :: proc(t: ^testing.T) {
	sq := [][3]f32{{-1, -1, -0.5}, {-1, -1, 0.5}, {1, -1, -0.5}, {1, -1, 0.5}, {0, 1, -0.5}, {0, 1, 0.5}}
	shapes := []level.Shape{{kind = .Hull, rot = {0, 0, 0, 1}, points = sq}}
	bodies := []level.Body{{name = "wall", pos = {2, 3, 0}, rot = {0, 0, 0.38268343, 0.9238795}, shapes = shapes}}
	props := []level.Prop{{key = "dir", type = .Vec3, v = {1.5, -2, 0}}}
	markers := []level.Marker{{kind = "spawn", name = "S", rot = {0, 0, 0, 1}, scale = {1, 1, 1}, props = props}}
	data := level.encode(bodies, markers, 64)
	defer delete(data)
	l, ok := level.load(data)
	defer level.destroy(&l)
	testing.expect(t, ok)
	if !ok do return
	testing.expect_value(t, l.px_per_m, 64)
	m := &l.markers[0]
	testing.expect(t, level.prop_vec2(m, "dir") == {1.5, -2})
	testing.expect(t, level.prop_vec3(m, "dir") == {1.5, -2, 0})
	testing.expect(t, level.prop_vec2(m, "nope", {7, 8}) == {7, 8})
	again := level.encode(l.bodies, l.markers, l.px_per_m)
	defer delete(again)
	testing.expect(t, string(again) == string(data))
}

// A version 1 file (no px_per_m) loads as a 3D level.
@(test)
version_1_loads :: proc(t: ^testing.T) {
	v2 := fixture()
	defer delete(v2)
	v1 := make([]u8, len(v2) - 4)
	defer delete(v1)
	copy(v1, v2[:4])
	v1[4] = 1
	copy(v1[6:], v2[10:])
	l, ok := level.load(v1)
	defer level.destroy(&l)
	testing.expect(t, ok)
	testing.expect_value(t, l.px_per_m, 0)
	testing.expect_value(t, len(l.bodies), 2)
	testing.expect_value(t, len(l.markers), 3)
	// Re-encoded, it is the version 2 file.
	again := level.encode(l.bodies, l.markers)
	defer delete(again)
	testing.expect(t, string(again) == string(v2))
	for version in ([]u8{0, 3}) {
		bad := make([]u8, len(v1), context.temp_allocator)
		copy(bad, v1)
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
	l, ok := level.load(FIXTURE_2D)
	defer level.destroy(&l)
	testing.expect(t, ok)
	if !ok do return
	testing.expect_value(t, l.px_per_m, 32)
	testing.expect_value(t, len(l.bodies), 4) // Ground, Shapes, Walls, Tiles (Decor has no collision)
	testing.expect_value(t, len(l.markers), 2)
	if len(l.bodies) != 4 || len(l.markers) != 2 do return

	g := &l.bodies[0]
	testing.expect_value(t, g.name, "Ground")
	testing.expect(t, g.pos == {0, 10, 0} && g.rot == {0, 0, 0, 1})
	testing.expect(t, abs(g.friction - 0.8) < 1e-6 && g.restitution == 0.25 && g.category == 4 && g.material == 7)
	testing.expect(t, len(g.shapes) == 1 && g.shapes[0].kind == .Box && g.shapes[0].half == {10, 0.5, 0.25})

	// Under a parent at (320, 0) px turned 90° and scaled 2: the body is at (10, 4) m turned 90°, the scale
	// baked into its shapes.
	s := &l.bodies[1]
	testing.expect_value(t, s.name, "Shapes")
	testing.expectf(t, near(s.pos, {10, 4, 0}), "%v", s.pos)
	testing.expectf(t, near_q(s.rot, qz(math.PI / 2)), "%v", s.rot)
	testing.expect_value(t, len(s.shapes), 4)
	if len(s.shapes) == 4 {
		ball, pill, wedge, box := s.shapes[0], s.shapes[1], s.shapes[2], s.shapes[3]
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

	w := &l.bodies[2]
	testing.expect_value(t, w.name, "Walls")
	testing.expect(t, w.pos == {-10, 0, 0})
	testing.expectf(t, len(w.shapes) >= 2, "the L splits into convex parts: %d", len(w.shapes))
	for sh in w.shapes do testing.expect(t, sh.kind == .Hull)

	tl := &l.bodies[3]
	testing.expect_value(t, tl.name, "Tiles")
	testing.expect(t, tl.pos == {0, 0.5, 0} && tl.category == 2 && abs(tl.friction - 0.3) < 1e-6)
	testing.expect_value(t, len(tl.shapes), 4) // one convex polygon per cell
	if len(tl.shapes) == 4 {
		// Cells sorted by (y, x): (4, 7) first, then (-1, 8): a square centred at (-16, 272) px in the layer.
		testing.expect_value(t, len(tl.shapes[0].points), 6)
		lo, hi := [3]f32{1e9, 1e9, 1e9}, [3]f32{-1e9, -1e9, -1e9}
		for p in tl.shapes[1].points {
			lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
			hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
		}
		testing.expectf(t, near(lo, {-1, 8, -0.25}) && near(hi, {0, 9, 0.25}), "%v %v", lo, hi)
	}

	sp := &l.markers[0]
	testing.expect(t, sp.kind == "spawn" && sp.name == "Spawn")
	testing.expectf(t, near(sp.pos, {6, 0, 0}), "%v", sp.pos)
	testing.expectf(t, near_q(sp.rot, qz(math.PI / 2 + 0.25)), "%v", sp.rot)
	testing.expectf(t, near(sp.scale, {2, 2, 1}), "%v", sp.scale)
	testing.expect(t, level.prop_vec2(sp, "push") == {1.5, -2}) // raw, not in metres
	testing.expect_value(t, level.prop_f32(sp, "speed"), 2.5)
	testing.expect_value(t, level.prop_int(sp, "lives"), 3)
	testing.expect_value(t, level.prop_string(sp, "label"), "left")
	testing.expect_value(t, level.prop_ref(sp, "goal"), 1)
	testing.expect_value(t, len(sp.path), 3)
	if len(sp.path) == 3 {
		// The Path2D's points in world metres: (32, 0) px through the spawn's transform (scale 2).
		a := math.PI / 2 + 0.25
		want := [3]f32{6 + f32(2 * math.cos(a)), f32(2 * math.sin(a)), 0}
		testing.expect(t, near(sp.path[0], {6, 0, 0}))
		testing.expectf(t, near(sp.path[1], want), "%v, want %v", sp.path[1], want)
	}
	goal := &l.markers[1]
	testing.expect(t, goal.kind == "goal" && near(goal.pos, {-2, 1, 0}))
	// Mirrored on x: Godot's decomposition reads it as a half turn with y mirrored.
	testing.expectf(t, near(goal.scale, {1, -1, 1}) && near_q(goal.rot, qz(math.PI)), "%v %v", goal.scale, goal.rot)
}

// physics.create_static on the fixture: ordinary static bodies at z = 0, each where the scene drew it.
@(test)
create_static_2d :: proc(t: ^testing.T) {
	l, ok := level.load(FIXTURE_2D)
	defer level.destroy(&l)
	testing.expect(t, ok)
	if !ok do return
	w := physics.create()
	defer physics.destroy(w)
	testing.expect_value(t, physics.create_static(w, &l), 4)
	// A ray into the plane (+z) at (x, y): the front face it hits (z = -depth/2 for boxes and hulls).
	front :: proc(w: ^physics.World, x, y: f32) -> (z: f32, hit: physics.Ray_Hit, ok: bool) {
		hit, ok = physics.ray_closest(w, {x, y, -5}, {0, 0, 10})
		return hit.point.z, hit, ok
	}
	expect_front :: proc(t: ^testing.T, w: ^physics.World, x, y, want: f32, loc := #caller_location) {
		z, _, ok := front(w, x, y)
		testing.expectf(t, ok && abs(z - want) < 1e-3, "at (%v, %v): %v %v, want %v", x, y, ok, z, want, loc = loc)
	}
	expect_miss :: proc(t: ^testing.T, w: ^physics.World, x, y: f32, loc := #caller_location) {
		z, _, ok := front(w, x, y)
		testing.expectf(t, !ok, "at (%v, %v): hit at z %v, want nothing", x, y, z, loc = loc)
	}
	// Ground: 20 x 1 m centred at (0, 10).
	expect_front(t, w, -9.9, 9.6, -0.25)
	expect_miss(t, w, 0, 10.6)
	_, gh, _ := front(w, 0, 10)
	testing.expect_value(t, gh.material, 7)
	gid := physics.link_id(w, gh.body)
	gp := b3.Body_GetPosition(gid)
	testing.expect(t, gp == {0, 10, 0})
	// Shapes, turned 90° at (10, 4): the ball (radius 1) at its origin, the capsule's centre 2 m along the
	// body's +x = world +y, lying along world x (the body's local y), the wedge's tip at (9, 2), the box (0.5 x 1
	// half, turned 45° more) 2 m along the body's +y = world -x.
	expect_front(t, w, 10, 4, -1)
	expect_front(t, w, 10, 6, -0.5)
	expect_front(t, w, 11.3, 6, -0.4) // 0.3 m past the segment's end
	expect_miss(t, w, 10, 6.7)
	expect_front(t, w, 9.2, 2, -0.25)
	expect_miss(t, w, 8.8, 2)
	expect_front(t, w, 8, 4, -0.25)
	sid := b3.Body_GetRotation(physics.link_id(w, front_body(w, 10, 4)))
	testing.expectf(t, near_q({sid.v.x, sid.v.y, sid.v.z, sid.s}, qz(math.PI / 2)), "%v", sid)
	// Walls: the L at (-10, 0): its top arm and its stem, not the notch.
	expect_front(t, w, -8.5, 0.5, -0.25)
	expect_front(t, w, -9.5, 2.5, -0.25)
	expect_miss(t, w, -8.5, 2)
	// Tiles: squares centred at (-0.5, 9), (2.5, 9), (3.5, 9); the flipped slope fills the lower left of
	// (4..5, 7.5..8.5).
	expect_front(t, w, -0.5, 9, -0.25)
	expect_front(t, w, 3.5, 9, -0.25)
	expect_miss(t, w, 1.5, 9)
	expect_front(t, w, 4.2, 8.3, -0.25)
	expect_miss(t, w, 4.8, 7.7)
}

front_body :: proc(w: ^physics.World, x, y: f32) -> physics.Body_Link {
	hit, _ := physics.ray_closest(w, {x, y, -5}, {0, 0, 10})
	return hit.body
}
