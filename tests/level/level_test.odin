// src/level/README.md: the UNLV file round-trips every record and property type, bad files are refused,
// and physics builds a level's bodies (create_with_levels, level_change), meshes and height fields included.
package test_level

import "core:math"
import "core:testing"

import "unified:dmath"
import "unified:level"
import "unified:physics"

// The fixture's navigation mesh: a square and a triangle beside it, sharing an edge.
NAV_VERTICES := [5][3]f32{{0, 0, 0}, {0, 0, 4}, {4, 0, 4}, {4, 0, 0}, {8, 0, 2}}

nav_polygons :: proc() -> [][]u32 {
	@(static) square := [4]u32{0, 1, 2, 3}
	@(static) triangle := [3]u32{3, 2, 4}
	@(static) polygons: [2][]u32
	polygons = {square[:], triangle[:]}
	return polygons[:]
}

fixture :: proc() -> []u8 {
	hull := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 1}}
	mesh_points := [][3]f32{{10, 0, -2}, {14, 2, -2}, {14, 2, 2}, {10, 0, 2}}
	mesh_triangles := [][3]u32{{0, 2, 1}, {0, 3, 2}}
	ramp := curve_ramp()
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
			kind = .Sphere,
			pos = {3, 1, 0},
			radius = 0.5,
			rot = {0, 0, 0, 1},
			surface = {friction = 0.9, rolling_resistance = 0.1, tangent_velocity = {2, 0, 0}, material = 78},
		},
		{
			kind        = .Capsule,
			pos         = {-3, 1, 0},
			radius      = 0.25,
			half_height = 0.5,
			rot         = {0, 0, 0.70710677, 0.70710677},
		},
		{
			kind = .Hull,
			points = hull,
			rot = {0, 0, 0, 1},
			surface = {friction = 0.9, rolling_resistance = 0.1, tangent_velocity = {2, 0, 0}, material = 78},
		},
		// a ramp mesh on the far side: two triangles rising from x = 10 (y 0) to x = 14 (y 2), its second triangle
		// of material 1 (an extra surface)
		{
			kind               = .Mesh,
			rot                = {0, 0, 0, 1},
			points             = mesh_points,
			triangles          = mesh_triangles,
			triangle_materials = {0, 1},
			materials          = {{}, {friction = 0.1, material = 91}},
		},
		// a 3 x 2 height field from (-14, 0, -2), 2 m cells: flat at 1 except its middle column at 3
		{
			kind    = .Height_Field,
			pos     = {-14, 0, -2},
			rot     = {0, 0, 0, 1},
			count_x = 3,
			count_z = 2,
			scale   = {2, 1, 4},
			heights = {1, 3, 1, 1, 3, 1},
		},
	}
	bodies := []level.Body {
		{
			name = "floor",
			pos = {0, -0.5, 0},
			rot = {0, 0, 0, 1},
			surface = {friction = 0.6},
			shapes = shapes[:1],
		},
		{
			name = "props",
			pos = {0, 0, 5},
			rot = {0, 0, 0, 1},
			surface = {friction = 0.4, restitution = 0.2, material = 77},
			category = 4,
			shapes = shapes[1:],
		},
	}
	props := []level.Prop {
		{key = "running", value = true},
		{key = "count", value = i32(-3)},
		{key = "speed", value = f32(2.5)},
		{key = "push", value = [3]f32{1, 2, 3}},
		{key = "label", value = "lift"},
		{key = "gate", value = level.Marker_Ref(1)},
		{key = "falloff", value = level.Curve_Samples(&ramp)},
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
	return encode(
		bodies,
		markers,
		scene = "res://levels/fixture.tscn",
		nav_vertices = NAV_VERTICES[:],
		nav_polygons = nav_polygons(),
	)
}

// A curve's samples rising from 0 to 1.
curve_ramp :: proc() -> (samples: [level.CURVE_SAMPLES]f32) {
	for &sample, i in samples do sample = f32(i) / (level.CURVE_SAMPLES - 1)
	return
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
	testing.expect_value(t, loaded.scene, "res://levels/fixture.tscn")
	testing.expect_value(t, level.scene_of(data), "res://levels/fixture.tscn")
	testing.expect_value(t, loaded.bodies[1].name, "props")
	testing.expect_value(t, loaded.bodies[1].surface.material, 77)
	testing.expect_value(t, loaded.bodies[1].category, 4)
	props := loaded.bodies[1].shapes
	testing.expect_value(t, len(props), 6)
	testing.expect_value(t, props[2].half_height, 0.5)
	testing.expect_value(t, len(props[3].points), 5)
	testing.expect(t, props[3].points[4] == {1, 1, 1})
	testing.expect(t, props[0].surface == loaded.bodies[1].surface, "a shape without its own surface has its body's")
	testing.expect(t, props[1].surface.material == 78 && props[1].surface.tangent_velocity == {2, 0, 0})
	mesh := props[4]
	testing.expect(t, mesh.kind == .Mesh && len(mesh.points) == 4 && len(mesh.triangles) == 2)
	testing.expect(t, mesh.triangles[1] == {0, 3, 2} && len(mesh.triangle_materials) == 2)
	testing.expect(
		t,
		len(mesh.materials) == 2 && mesh.materials[0] == mesh.surface && mesh.materials[1].material == 91,
	)
	field := props[5]
	testing.expect(t, field.kind == .Height_Field && field.count_x == 3 && field.count_z == 2)
	testing.expect(t, field.scale == {2, 1, 4} && len(field.heights) == 6 && field.heights[4] == 3)
	marker := level.find_named(&loaded, "Lift")
	testing.expect(t, marker != nil)
	if marker == nil do return
	testing.expect(t, level.prop_bool(marker, "running"))
	testing.expect_value(t, level.prop_int(marker, "count"), -3)
	testing.expect_value(t, level.prop_f32(marker, "speed"), 2.5)
	testing.expect_value(t, level.prop_f32(marker, "count"), -3) // ints read as floats too
	testing.expect(t, level.prop_vec3(marker, "push") == {1, 2, 3})
	testing.expect_value(t, level.prop_string(marker, "label"), "lift")
	Label :: enum u8 {
		Ferry,
		Lift,
		Big_Lift,
	}
	label, known := level.prop_enum(marker, "label", Label.Ferry)
	testing.expect(t, label == .Lift && known, "\"lift\": the lowercased name")
	label, known = level.prop_enum(marker, "count", Label.Big_Lift)
	testing.expect(t, label == .Big_Lift && !known, "an int is no member's name")
	label, known = level.prop_enum(marker, "nope", Label.Big_Lift)
	testing.expect(t, label == .Big_Lift && known, "missing: the default, known")
	testing.expect_value(t, level.prop_enum(marker, "label", Label.Ferry), Label.Lift) // #optional_ok: the value alone
	Other :: enum {
		Crate,
	}
	other, other_known := level.prop_enum(marker, "label", Other.Crate)
	testing.expect(t, other == .Crate && !other_known, "\"lift\" names no Other: the default, unknown")
	testing.expect_value(t, level.prop_ref(marker, "gate"), 1)
	testing.expect_value(t, level.prop_ref(marker, "nope"), -1)
	testing.expect_value(t, level.prop_f32(marker, "nope", 9), 9)
	testing.expect_value(t, len(marker.path), 2)
	falloff := marker.props[len(marker.props) - 1]
	curve, is_curve := falloff.value.(level.Curve_Samples)
	testing.expect(t, falloff.key == "falloff" && is_curve, "a Curve property")
	testing.expect(t, is_curve && curve^ == curve_ramp(), "a Curve property's samples")
	ramp, has_ramp := level.prop_curve(marker, "falloff")
	testing.expect(t, has_ramp && ramp.samples == curve_ramp(), "prop_curve: the samples as a dmath.Curve")
	testing.expect_value(t, dmath.curve_sample(ramp, 0.5), 0.5)
	_, has_missing := level.prop_curve(marker, "nope")
	testing.expect(t, !has_missing, "prop_curve: no such property")
	_, has_other := level.prop_curve(marker, "gate")
	testing.expect(t, !has_other, "prop_curve: a property of another type")
	platforms: [dynamic]string
	defer delete(platforms)
	for &each in loaded.markers {
		if each.kind == "platform" do append(&platforms, each.name)
	}
	testing.expect_value(t, len(platforms), 2)
	if len(platforms) == 2 do testing.expect_value(t, platforms[1], "Ferry")
	testing.expect_value(t, len(loaded.nav_vertices), 5)
	testing.expect_value(t, len(loaded.nav_polygons), 2)
	if len(loaded.nav_polygons) == 2 {
		testing.expect(t, loaded.nav_vertices[4] == {8, 0, 2})
		testing.expect(t, slice_equal(loaded.nav_polygons[0], []u32{0, 1, 2, 3}))
		testing.expect(t, slice_equal(loaded.nav_polygons[1], []u32{3, 2, 4}))
	}
	// Encoding what was read gives the same bytes.
	again := encode(
		loaded.bodies,
		loaded.markers,
		scene = loaded.scene,
		nav_vertices = loaded.nav_vertices,
		nav_polygons = loaded.nav_polygons,
	)
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
	// An index past its table: a mesh triangle naming a vertex it lacks, a triangle material past its surfaces,
	// a height field under 2 x 2.
	mesh_points := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 0, 1}}
	good_triangles := [][3]u32{{0, 2, 1}}
	bad_triangles := [][3]u32{{0, 1, 4}}
	good_materials := []u8{1}
	bad_materials := []u8{2}
	surfaces := []level.Surface{{}, {material = 5}}
	heights := []f32{0, 0, 0, 0}
	for broken in 0 ..< 4 {
		shapes := []level.Shape {
			{
				kind               = .Mesh,
				rot                = {0, 0, 0, 1},
				points             = mesh_points,
				triangles          = bad_triangles if broken == 1 else good_triangles,
				triangle_materials = bad_materials if broken == 2 else good_materials,
				materials          = surfaces,
			},
			{
				kind    = .Height_Field,
				rot     = {0, 0, 0, 1},
				count_x = 1 if broken == 3 else 2,
				count_z = 2,
				scale   = 1,
				heights = heights[:2] if broken == 3 else heights,
			},
		}
		bodies := []level.Body{{name = "ground", rot = {0, 0, 0, 1}, shapes = shapes}}
		encoded := encode(bodies, nil)
		defer delete(encoded)
		loaded, loaded_ok := level.load(encoded)
		testing.expectf(t, loaded_ok == (broken == 0), "case %d loaded: %v", broken, loaded_ok)
		level.destroy(&loaded)
	}
	// A navigation polygon under 3 vertices, naming a vertex past the table, or one vertex twice.
	nav_vertices := [][3]f32{{0, 0, 0}, {0, 0, 1}, {1, 0, 1}, {1, 0, 0}}
	for polygon, broken in ([][]u32{{0, 1, 2, 3}, {0, 1}, {0, 1, 4}, {0, 1, 1, 2}}) {
		encoded := encode(nil, nil, nav_vertices = nav_vertices, nav_polygons = [][]u32{polygon})
		defer delete(encoded)
		loaded, loaded_ok := level.load(encoded)
		testing.expectf(t, loaded_ok == (broken == 0), "navigation case %d loaded: %v", broken, loaded_ok)
		level.destroy(&loaded)
	}
	// Trailing bytes are refused too.
	long := make([]u8, len(data) + 1)
	defer delete(long)
	copy(long, data)
	_, ok = level.load(long)
	testing.expect(t, !ok)
}

@(test)
level_bodies :: proc(t: ^testing.T) {
	data := fixture()
	defer delete(data)
	session := show(data)
	defer show_end(session)
	world := session.world.phys
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
	// The sphere has its own surface; the mesh ramp rises 1 in 2 from x = 10, its second triangle of material 91; the
	// height field's middle column stands at 3, its others at 1.
	hit, _ = physics.world_cast_ray_closest(world, {3, 10, 5}, {0, -20, 0})
	testing.expect_value(t, hit.material, 78)
	expect_top(t, world, 13, 4, 1.5)
	expect_top(t, world, 11, 6, 0.5)
	hit, _ = physics.world_cast_ray_closest(world, {13, 10, 4}, {0, -20, 0})
	testing.expect_value(t, hit.material, 77)
	hit, _ = physics.world_cast_ray_closest(world, {11, 10, 6}, {0, -20, 0})
	testing.expect_value(t, hit.material, 91)
	expect_top(t, world, -12, 5, 3)
	expect_top(t, world, -13, 5, 2)
	expect_top(t, world, -11, 5, 2)
}

// create_with_levels: every level parsed and built, no body made until a level is entered; no level: a problem, no
// world.
@(test)
create_with_levels_parses_and_builds :: proc(t: ^testing.T) {
	data := fixture()
	defer delete(data)
	phys, problem := physics.create_with_levels({tick_hz = 64}, {{"a", data}, {"b", data}})
	defer physics.destroy(phys)
	testing.expect_value(t, problem, "")
	testing.expect(t, phys != nil && len(physics.level_data(phys, 1).bodies) == 2)
	_, ok := physics.world_cast_ray_closest(phys, {0, 10, 0}, {0, -20, 0})
	testing.expect(t, !ok, "no level is entered yet")
	none, refused := physics.create_with_levels({tick_hz = 64}, {{"a", data}, {"cut", data[:8]}})
	testing.expect(
		t,
		none == nil && refused == `level "cut": not a level file of this version (src/level/README.md)`,
		refused,
	)
}

// A shape Box3D refuses is never a silent hole: build_level_shape says so, and create_with_levels names the first one
// with its level, body and shape.
@(test)
create_with_levels_names_a_refused_shape :: proc(t: ^testing.T) {
	world := physics.create({tick_hz = 64})
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
	body_def := physics.default_body_def()
	body := physics.create_body(world, body_def)
	shape_def := physics.default_shape_def()
	box, box_ok := physics.build_level_shape(world, &shapes[0])
	testing.expect(t, box_ok)
	physics.create_level_shape(world, body, shape_def, box)
	_, few_ok := physics.build_level_shape(world, &shapes[1])
	testing.expect(t, !few_ok)
	_, many_ok := physics.build_level_shape(world, &shapes[2])
	testing.expect(t, !many_ok)
	good := fixture()
	defer delete(good)
	rocks := encode(bodies, nil)
	defer delete(rocks)
	none, problem := physics.create_with_levels({tick_hz = 64}, {{"yard", good}, {"quarry", rocks}})
	testing.expect(t, none == nil)
	testing.expect_value(t, problem, `level "quarry", body 0 "rocks", shape 1 (Hull of 3 points): Box3D refused it`)
}

// One bad float in a level file, per field: load refuses each (before, some hung Box3D entering the level, one
// segfaulted, the rest built invisible or wrong geometry with no problem named).
@(test)
a_bad_float_in_a_level_file_is_refused_at_load :: proc(t: ^testing.T) {
	nan := math.nan_f32()
	inf := math.inf_f32(1)
	for which in 0 ..< 30 {
		hull := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 1}}
		mesh_points := [][3]f32{{10, 0, -2}, {14, 2, -2}, {14, 2, 2}, {10, 0, 2}}
		heights := []f32{1, 3, 1, 1, 3, 1}
		shapes := []level.Shape {
			{kind = .Box, half = {10, 0.5, 10}, rot = {0, 0, 0, 1}},
			{kind = .Sphere, pos = {3, 1, 0}, radius = 0.5, rot = {0, 0, 0, 1}},
			{
				kind        = .Capsule,
				pos         = {-3, 1, 0},
				radius      = 0.25,
				half_height = 0.5,
				rot         = {0, 0, 0.70710677, 0.70710677},
			},
			{kind = .Hull, points = hull, rot = {0, 0, 0, 1}},
			{kind = .Mesh, rot = {0, 0, 0, 1}, points = mesh_points, triangles = {{0, 2, 1}, {0, 3, 2}}},
			{
				kind    = .Height_Field,
				pos     = {-14, 0, -2},
				rot     = {0, 0, 0, 1},
				count_x = 3,
				count_z = 2,
				scale   = {2, 1, 4},
				heights = heights,
			},
		}
		bodies := []level.Body {
			{name = "floor", pos = {0, -0.5, 0}, rot = {0, 0, 0, 1}, surface = {friction = 0.6}, shapes = shapes},
		}
		name := ""
		switch which {
		case 0:
			name = "none (control)"
		case 1:
			name, bodies[0].pos = "body pos NaN", {nan, 0, 0}
		case 2:
			name, bodies[0].pos = "body pos inf", {inf, 0, 0}
		case 3:
			name, bodies[0].rot = "body rot NaN", {nan, nan, nan, nan}
		case 4:
			name, bodies[0].rot = "body rot zero", {0, 0, 0, 0}
		case 5:
			name, bodies[0].rot = "body rot not unit", {0, 3, 0, 1}
		case 6:
			name, bodies[0].rot = "body rot huge", {0, -1.7e38, 0, 1}
		case 7:
			name, shapes[0].pos = "box pos NaN", {nan, 0, 0}
		case 8:
			name, shapes[0].rot = "box rot NaN", {nan, nan, nan, nan}
		case 9:
			name, shapes[0].rot = "box rot zero", {0, 0, 0, 0}
		case 10:
			name, shapes[0].half = "box half NaN", {nan, 0.5, 10}
		case 11:
			name, shapes[0].half = "box half zero", {0, 0, 0}
		case 12:
			name, shapes[0].half = "box half negative", {-10, 0.5, 10}
		case 13:
			name, shapes[1].radius = "sphere radius NaN", nan
		case 14:
			name, shapes[1].radius = "sphere radius 0", 0
		case 15:
			name, shapes[1].radius = "sphere radius negative", -1
		case 16:
			name, shapes[2].half_height = "capsule half_height NaN", nan
		case 17:
			name, hull[4] = "hull point NaN", {nan, 1, 1}
		case 18:
			name, hull[4] = "hull point inf", {inf, 1, 1}
		case 19:
			name, mesh_points[1] = "mesh point NaN", {nan, 2, -2}
		case 20:
			name, mesh_points[1] = "mesh point inf", {inf, 2, -2}
		case 21:
			name, heights[1] = "height NaN", nan
		case 22:
			name, heights[1] = "height inf", inf
		case 23:
			name, shapes[5].scale = "height scale 0", {0, 0, 0}
		case 24:
			name, shapes[5].scale = "height scale NaN", {nan, 1, 4}
		case 25:
			name, bodies[0].surface.friction = "friction NaN", nan
		case 26:
			name, shapes[4].rot = "mesh rot NaN", {nan, nan, nan, nan}
		case 27:
			name, shapes[5].rot = "height field rot zero", {0, 0, 0, 0}
		case 28:
			name, shapes[2].rot = "capsule rot NaN", {nan, nan, nan, nan}
		case 29:
			name, shapes[5].scale = "height scale negative", {-2, 1, 4}
		}
		data := encode(bodies, nil)
		loaded, ok := level.load(data)
		testing.expectf(t, ok == (which == 0), "%s: load %v", name, ok)
		level.destroy(&loaded)
		delete(data)
	}
}

// A marker's NodePath property names a marker of the file or none (-1): any other index is refused at load, as every
// other index is.
@(test)
a_marker_ref_out_of_range_is_refused :: proc(t: ^testing.T) {
	for ref in ([]i32{-1, 0, 1, 2, 1000, -2, min(i32)}) {
		props := []level.Prop{{key = "gate", value = level.Marker_Ref(ref)}}
		markers := []level.Marker {
			{kind = "a", name = "A", rot = {0, 0, 0, 1}, scale = 1, props = props},
			{kind = "b", name = "B", rot = {0, 0, 0, 1}, scale = 1},
		}
		data := encode(nil, markers)
		loaded, ok := level.load(data)
		testing.expectf(t, ok == (ref >= -1 && ref < 2), "ref %d: loaded %v", ref, ok)
		level.destroy(&loaded)
		delete(data)
	}
}

@(private = "file")
slice_equal :: proc(a, b: []u32) -> bool {
	if len(a) != len(b) do return false
	for value, i in a do if value != b[i] do return false
	return true
}
