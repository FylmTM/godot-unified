// spec/level.md: the UNLV file round-trips every record and property type, bad files are refused,
// and physics.create_static builds the bodies.
package test_level

import "core:testing"

import "unified:level"
import "unified:physics"

fixture :: proc() -> []u8 {
	hull := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 1}}
	shapes := []level.Shape {
		{kind = .Box, half = {10, 0.5, 10}, rot = {0, 0, 0, 1}},
		{kind = .Box, pos = {0, 1, 0}, half = {1, 0.5, 1}, rot = {0, 0.38268343, 0, 0.9238795}},
		{kind = .Sphere, pos = {3, 1, 0}, radius = 0.5, rot = {0, 0, 0, 1}},
		{kind = .Capsule, pos = {-3, 1, 0}, radius = 0.25, half_height = 0.5, rot = {0, 0, 0.70710677, 0.70710677}},
		{kind = .Hull, points = hull, rot = {0, 0, 0, 1}},
	}
	bodies := []level.Body {
		{name = "floor", pos = {0, -0.5, 0}, rot = {0, 0, 0, 1}, friction = 0.6, shapes = shapes[:1]},
		{
			name = "props",
			pos = {0, 0, 5},
			rot = {0, 0, 0, 1},
			friction = 0.4,
			restitution = 0.2,
			category = 4,
			material = 77,
			shapes = shapes[1:],
		},
	}
	props := []level.Prop {
		{key = "running", type = .Bool, b = true},
		{key = "count", type = .Int, i = -3},
		{key = "speed", type = .Float, f = 2.5},
		{key = "push", type = .Vec3, v = {1, 2, 3}},
		{key = "label", type = .String, s = "lift"},
		{key = "gate", type = .Ref, i = 1},
	}
	path := [][3]f32{{0, 0, 0}, {0, 3, 0}}
	markers := []level.Marker {
		{
			kind = "platform",
			name = "Lift",
			pos = {1, 2, 3},
			rot = {0, 0, 0, 1},
			scale = {1, 1, 1},
			props = props,
			path = path,
		},
		{kind = "gate", name = "Gate", pos = {4, 0, 0}, rot = {0, 0, 0, 1}, scale = {2, 2, 2}},
		{kind = "platform", name = "Ferry", rot = {0, 0, 0, 1}, scale = {1, 1, 1}},
	}
	return level.encode(bodies, markers)
}

@(test)
round_trip :: proc(t: ^testing.T) {
	data := fixture()
	defer delete(data)
	l, ok := level.load(data)
	defer level.destroy(&l)
	testing.expect(t, ok)
	if !ok do return
	testing.expect_value(t, len(l.bodies), 2)
	testing.expect_value(t, len(l.markers), 3)
	testing.expect_value(t, l.bodies[1].name, "props")
	testing.expect_value(t, l.bodies[1].material, 77)
	testing.expect_value(t, l.bodies[1].category, 4)
	testing.expect_value(t, len(l.bodies[1].shapes), 4)
	testing.expect_value(t, l.bodies[1].shapes[2].half_height, 0.5)
	testing.expect_value(t, len(l.bodies[1].shapes[3].points), 5)
	testing.expect(t, l.bodies[1].shapes[3].points[4] == {1, 1, 1})
	m := level.find_named(&l, "Lift")
	testing.expect(t, m != nil)
	if m == nil do return
	testing.expect(t, level.prop_bool(m, "running"))
	testing.expect_value(t, level.prop_int(m, "count"), -3)
	testing.expect_value(t, level.prop_f32(m, "speed"), 2.5)
	testing.expect_value(t, level.prop_f32(m, "count"), -3) // ints read as floats too
	testing.expect(t, level.prop_vec3(m, "push") == {1, 2, 3})
	testing.expect_value(t, level.prop_string(m, "label"), "lift")
	testing.expect_value(t, level.prop_ref(m, "gate"), 1)
	testing.expect_value(t, level.prop_ref(m, "nope"), -1)
	testing.expect_value(t, level.prop_f32(m, "nope", 9), 9)
	testing.expect_value(t, len(m.path), 2)
	plats := level.find_all(&l, "platform")
	testing.expect_value(t, len(plats), 2)
	if len(plats) == 2 do testing.expect_value(t, plats[1].name, "Ferry")
	// Encoding what was read gives the same bytes.
	again := level.encode(l.bodies, l.markers)
	defer delete(again)
	testing.expect(t, string(again) == string(data))
}

@(test)
bad_files :: proc(t: ^testing.T) {
	data := fixture()
	defer delete(data)
	for n in 0 ..< len(data) {
		l, ok := level.load(data[:n])
		testing.expectf(t, !ok, "a %d-byte prefix loaded", n)
		level.destroy(&l)
	}
	bad := make([]u8, len(data))
	defer delete(bad)
	copy(bad, data)
	bad[4] = 9 // version
	_, ok := level.load(bad)
	testing.expect(t, !ok)
	copy(bad, data)
	bad[0] = 'X'
	_, ok = level.load(bad)
	testing.expect(t, !ok)
	// Trailing bytes are refused too.
	long := make([]u8, len(data) + 1)
	defer delete(long)
	copy(long, data)
	_, ok = level.load(long)
	testing.expect(t, !ok)
}

@(test)
create_static_bodies :: proc(t: ^testing.T) {
	data := fixture()
	defer delete(data)
	l, ok := level.load(data)
	defer level.destroy(&l)
	testing.expect(t, ok)
	w := physics.create()
	defer physics.destroy(w)
	testing.expect_value(t, physics.create_static(w, &l), 2)
	// A ray down at the origin hits the floor's top; the rotated box (pos (0,1,5) local (0,1,0)) is hit
	// at y = 1.5; the sphere at (3,1,5) on top at y = 1.5; the capsule lies along x at (-3,1,5): top 1.25.
	expect_top :: proc(t: ^testing.T, w: ^physics.World, x, z, want: f32) {
		h, ok := physics.ray_closest(w, {x, 10, z}, {0, -20, 0})
		testing.expectf(t, ok && abs(h.point.y - want) < 1e-3, "at (%v, %v): %v, want %v", x, z, h.point.y, want)
	}
	expect_top(t, w, 0, 0, 0)
	expect_top(t, w, 0, 5, 1.5)
	expect_top(t, w, 3, 5, 1.5)
	expect_top(t, w, -3.2, 5, 1.25) // along x from -3.5 to -2.5
	h, _ := physics.ray_closest(w, {0, 10, 5}, {0, -20, 0})
	testing.expect_value(t, h.material, 77)
}
