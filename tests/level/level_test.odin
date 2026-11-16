// src/level/SPEC.md: the UNLV file round-trips every record and property type, bad files are refused,
// and physics.create_static builds the bodies.
package test_level

import "core:math"
import "core:testing"

import "unified:level"
import "unified:physics"

fixture :: proc() -> []u8 {
	hull := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 1}}
	shapes := []level.Shape {
		{
			kind = .Box,
			half = {10, 0.5, 10},
			rot  = {0, 0, 0, 1},
		},
		{
			kind = .Box,
			pos  = {0, 1, 0},
			half = {1, 0.5, 1},
			rot  = {0, 0.38268343, 0, 0.9238795},
		},
		{
			kind   = .Sphere,
			pos    = {3, 1, 0},
			radius = 0.5,
			rot    = {0, 0, 0, 1},
		},
		{
			kind        = .Capsule,
			pos         = {-3, 1, 0},
			radius      = 0.25,
			half_height = 0.5,
			rot         = {0, 0, 0.70710677, 0.70710677},
		},
		{
			kind   = .Hull,
			points = hull,
			rot    = {0, 0, 0, 1},
		},
	}
	bodies := []level.Body {
		{
			name     = "floor",
			pos      = {0, -0.5, 0},
			rot      = {0, 0, 0, 1},
			friction = 0.6,
			shapes   = shapes[:1],
		},
		{
			name        = "props",
			pos         = {0, 0, 5},
			rot         = {0, 0, 0, 1},
			friction    = 0.4,
			restitution = 0.2,
			category    = 4,
			material    = 77,
			shapes      = shapes[1:],
		},
	}
	props := []level.Prop {
		{
			key  = "running",
			type = .Bool,
			b    = true,
		},
		{
			key  = "count",
			type = .Int,
			i    = -3,
		},
		{
			key  = "speed",
			type = .Float,
			f    = 2.5,
		},
		{
			key  = "push",
			type = .Vec3,
			v    = {1, 2, 3},
		},
		{
			key  = "label",
			type = .String,
			s    = "lift",
		},
		{
			key  = "gate",
			type = .Ref,
			i    = 1,
		},
	}
	path := [][3]f32{{0, 0, 0}, {0, 3, 0}}
	markers := []level.Marker {
		{
			kind  = "platform",
			name  = "Lift",
			pos   = {1, 2, 3},
			rot   = {0, 0, 0, 1},
			scale = {1, 1, 1},
			props = props,
			path  = path,
		},
		{
			kind  = "gate",
			name  = "Gate",
			pos   = {4, 0, 0},
			rot   = {0, 0, 0, 1},
			scale = {2, 2, 2},
		},
		{
			kind  = "platform",
			name  = "Ferry",
			rot   = {0, 0, 0, 1},
			scale = {1, 1, 1},
		},
	}
	return level.encode(bodies, markers)
}

@(test)
round_trip :: proc(t: ^testing.T) {
	data := fixture()
	defer delete(data)
	loaded, ok := level.load(data)
	defer level.destroy(&loaded)
	testing.expect(t, ok)
	if !ok do return
	testing.expect_value(t, len(loaded.bodies), 2)
	testing.expect_value(t, len(loaded.markers), 3)
	testing.expect_value(t, loaded.bodies[1].name, "props")
	testing.expect_value(t, loaded.bodies[1].material, 77)
	testing.expect_value(t, loaded.bodies[1].category, 4)
	testing.expect_value(t, len(loaded.bodies[1].shapes), 4)
	testing.expect_value(t, loaded.bodies[1].shapes[2].half_height, 0.5)
	testing.expect_value(t, len(loaded.bodies[1].shapes[3].points), 5)
	testing.expect(t, loaded.bodies[1].shapes[3].points[4] == {1, 1, 1})
	marker := level.find_named(&loaded, "Lift")
	testing.expect(t, marker != nil)
	if marker == nil do return
	testing.expect(t, level.prop_bool(marker, "running"))
	testing.expect_value(t, level.prop_int(marker, "count"), -3)
	testing.expect_value(t, level.prop_f32(marker, "speed"), 2.5)
	testing.expect_value(t, level.prop_f32(marker, "count"), -3) // ints read as floats too
	testing.expect(t, level.prop_vec3(marker, "push") == {1, 2, 3})
	testing.expect_value(t, level.prop_string(marker, "label"), "lift")
	testing.expect_value(t, level.prop_ref(marker, "gate"), 1)
	testing.expect_value(t, level.prop_ref(marker, "nope"), -1)
	testing.expect_value(t, level.prop_f32(marker, "nope", 9), 9)
	testing.expect_value(t, len(marker.path), 2)
	plats := level.find_all(&loaded, "platform")
	testing.expect_value(t, len(plats), 2)
	if len(plats) == 2 do testing.expect_value(t, plats[1].name, "Ferry")
	// Encoding what was read gives the same bytes.
	again := level.encode(loaded.bodies, loaded.markers)
	defer delete(again)
	testing.expect(t, string(again) == string(data))
}

@(test)
bad_files :: proc(t: ^testing.T) {
	data := fixture()
	defer delete(data)
	for prefix_len in 0 ..< len(data) {
		loaded, ok := level.load(data[:prefix_len])
		testing.expectf(t, !ok, "a %d-byte prefix loaded", prefix_len)
		level.destroy(&loaded)
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
	loaded, ok := level.load(data)
	defer level.destroy(&loaded)
	testing.expect(t, ok)
	world := physics.create()
	defer physics.destroy(world)
	count, problem := physics.create_static(world, &loaded)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, problem, "")
	// A ray down at the origin hits the floor's top; the rotated box (pos (0,1,5) local (0,1,0)) is hit
	// at y = 1.5; the sphere at (3,1,5) on top at y = 1.5; the capsule lies along x at (-3,1,5): top 1.25.
	expect_top :: proc(t: ^testing.T, world: ^physics.World, x, z, want: f32) {
		hit, ok := physics.world_cast_ray_closest(world, {x, 10, z}, {0, -20, 0})
		testing.expectf(t, ok && abs(hit.point.y - want) < 1e-3, "at (%v, %v): %v, want %v", x, z, hit.point.y, want)
	}
	expect_top(t, world, 0, 0, 0)
	expect_top(t, world, 0, 5, 1.5)
	expect_top(t, world, 3, 5, 1.5)
	expect_top(t, world, -3.2, 5, 1.25) // along x from -3.5 to -2.5
	hit, _ := physics.world_cast_ray_closest(world, {0, 10, 5}, {0, -20, 0})
	testing.expect_value(t, hit.material, 77)
}

// A shape Box3D refuses is never a silent hole: create_level_shape says so, and create_static names the first one (#149).
@(test)
create_static_names_a_refused_shape :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	// 3 points: no hull. A cube's 7 x 7 x 7 surface lattice pushed onto a sphere: past Box3D's 128 hull edges at
	// the 64-vertex cap.
	sphere: [dynamic][3]f32
	defer delete(sphere)
	for x in -3 ..= 3 do for y in -3 ..= 3 do for z in -3 ..= 3 {
		if max(abs(x), abs(y), abs(z)) != 3 do continue
		point := [3]f32{f32(x), f32(y), f32(z)}
		append(&sphere, point / math.sqrt(point.x * point.x + point.y * point.y + point.z * point.z))
	}
	shapes := []level.Shape {
		{kind = .Box, rot = {0, 0, 0, 1}, half = {1, 1, 1}},
		{kind = .Hull, rot = {0, 0, 0, 1}, points = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}},
		{kind = .Hull, rot = {0, 0, 0, 1}, points = sphere[:]},
	}
	bodies := []level.Body{{name = "rocks", rot = {0, 0, 0, 1}, shapes = shapes}}
	loaded := level.Level {
		bodies = bodies,
	}
	body_def := physics.default_body_def()
	body := physics.create_body(world, &body_def)
	shape_def := physics.default_shape_def()
	testing.expect(t, physics.create_level_shape(world, body, &shape_def, &shapes[0]))
	testing.expect(t, !physics.create_level_shape(world, body, &shape_def, &shapes[1]))
	testing.expect(t, !physics.create_level_shape(world, body, &shape_def, &shapes[2]))
	count, problem := physics.create_static(world, &loaded)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, problem, `level body 0 "rocks", shape 1 (Hull of 3 points): Box3D refused it`)
}
