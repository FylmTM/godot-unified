// The Geometry group (src/physics/SPEC.md, What physics covers): hulls, meshes, height fields, compounds and their
// mass and bounds, through physics; and the mesh, height field and compound shapes, whose geometry a portable image
// carries into a second world.
package test_physics

import "core:testing"

import "unified:physics"
import "unified:sim"

// A vector of Box3D's geometry data (Hull_Data, Mesh_Data: Box3D's own structs, read only) as [3]f32.
api_vec :: proc(vector: $V) -> [3]f32 {
	return {vector.x, vector.y, vector.z}
}

@(test)
geometry_hulls :: proc(t: ^testing.T) {
	cube_points := [][3]f32 {
		{-1, -1, -1},
		{1, -1, -1},
		{1, 1, -1},
		{-1, 1, -1},
		{-1, -1, 1},
		{1, -1, 1},
		{1, 1, 1},
		{-1, 1, 1},
		{},
	}
	hull := physics.create_hull(cube_points)
	testing.expect(t, hull != nil)
	if hull == nil do return
	defer physics.destroy_hull(hull)
	testing.expect_value(t, hull.vertexCount, 8) // the inner point is dropped
	testing.expect(t, near_f32(hull.volume, 8, 1e-3))
	flat := [][3]f32{{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}}
	testing.expect(t, physics.create_hull(flat) == nil, "collinear points make no hull")

	clone := physics.clone_hull(hull)
	defer physics.destroy_hull(clone)
	testing.expect(t, clone != hull && clone.vertexCount == 8 && clone.volume == hull.volume)
	moved := physics.clone_and_transform_hull(hull, {{5, 0, 0}, {0, 0, 0, 1}}, {2, 1, 1})
	defer physics.destroy_hull(moved)
	testing.expect(t, near_f32(moved.volume, 16, 1e-3) && near(api_vec(moved.center), {5, 0, 0}))

	cube := physics.make_cube_hull(0.5)
	testing.expect(t, near_f32(cube.base.volume, 1, 1e-4))
	box := physics.make_box_hull({1, 2, 3})
	testing.expect(t, near_f32(box.base.volume, 48, 1e-3))
	offset := physics.make_offset_box_hull({1, 1, 1}, {0, 3, 0})
	testing.expect(t, near(api_vec(offset.base.center), {0, 3, 0}))
	transformed := physics.make_transformed_box_hull({1, 1, 1}, {{0, 0, 4}, QUARTER_Y})
	testing.expect(t, near(api_vec(transformed.base.center), {0, 0, 4}))
	scaled := physics.make_scaled_box_hull({1, 1, 1}, {{1, 0, 0}, {0, 0, 0, 1}}, {2, 1, 1})
	testing.expectf(
		t,
		near_f32(scaled.base.volume, 16, 1e-3) && near(api_vec(scaled.base.center), {2, 0, 0}),
		"%v %v",
		scaled.base.volume,
		scaled.base.center,
	)

	// A 16-sided cylinder and cone of radius 1: a little under the round ones' volumes (2π and π for height 2 and 3).
	cylinder := physics.create_cylinder(2, 1, 0, 16)
	defer physics.destroy_hull(cylinder)
	testing.expectf(t, cylinder.volume > 5.9 && cylinder.volume < 6.29, "cylinder %v", cylinder.volume)
	cone := physics.create_cone(3, 1, 0.5, 16)
	defer physics.destroy_hull(cone)
	// A frustum: πh(R² + Rr + r²)/3 = 1.75π ≈ 5.50 for round ones.
	testing.expectf(t, cone.volume > 5.2 && cone.volume < 5.5, "cone %v", cone.volume)
}

@(test)
geometry_meshes :: proc(t: ^testing.T) {
	// A unit quad in xz (two triangles facing up) and a degenerate (flat) third triangle.
	vertices := [][3]f32{{0, 0, 0}, {0, 0, 1}, {1, 0, 1}, {1, 0, 0}, {2, 0, 0}}
	indices := []i32{0, 1, 2, 0, 2, 3, 0, 3, 4}
	materials := []u8{0, 1, 0}
	def := physics.make_mesh_def(vertices, indices, materials)
	testing.expect(t, def.vertex_count == 5 && def.triangle_count == 3)
	degenerate: [4]i32
	mesh := physics.create_mesh(def, degenerate[:])
	testing.expect(t, mesh != nil)
	if mesh == nil do return
	defer physics.destroy_mesh(mesh)
	testing.expectf(
		t,
		mesh.degenerateCount == 1 && degenerate[0] == 2,
		"%d degenerate: %v",
		mesh.degenerateCount,
		degenerate,
	)
	testing.expect_value(t, mesh.materialCount, 2)
	aabb := physics.compute_mesh_aabb(mesh, {{0, 1, 0}, {0, 0, 0, 1}}, {2, 1, 1})
	testing.expectf(t, near(aabb.lower_bound, {0, 1, 0}, 0.01) && near(aabb.upper_bound, {2, 1, 1}, 0.01), "%v", aabb)

	box := physics.create_box_mesh({0, 1, 0}, {1, 1, 1})
	defer physics.destroy_mesh(box)
	testing.expect_value(t, box.triangleCount, 12)
	hollow := physics.create_hollow_box_mesh({}, {2, 2, 2})
	defer physics.destroy_mesh(hollow)
	testing.expect_value(t, hollow.triangleCount, 12)
	platform := physics.create_platform_mesh({}, 1, 2, 4)
	defer physics.destroy_mesh(platform)
	testing.expect(t, platform.triangleCount > 0)
	grid := physics.create_grid_mesh(4, 3, 0.5)
	defer physics.destroy_mesh(grid)
	testing.expect_value(t, grid.triangleCount, 4 * 3 * 2)
}

@(test)
geometry_height_fields :: proc(t: ^testing.T) {
	heights := [9]f32{0, 0, 0, 0, 0.5, 0, 0, 0, 0}
	cells := [4]u8{}
	def := physics.Height_Field_Def {
		heights               = &heights[0],
		material_indices      = &cells[0],
		scale                 = {2, 1, 2},
		count_x               = 3,
		count_z               = 3,
		global_minimum_height = 0,
		global_maximum_height = 1,
	}
	field := physics.create_height_field(def)
	testing.expect(t, field != nil)
	if field == nil do return
	defer physics.destroy_height_field(field)
	aabb := physics.compute_height_field_aabb(field, {{0, 1, 0}, {0, 0, 0, 1}})
	testing.expectf(
		t,
		near(aabb.lower_bound, {0, 1, 0}, 0.01) && near(aabb.upper_bound, {4, 1.5, 4}, 0.01),
		"%v",
		aabb,
	)
	grid := physics.create_grid(5, 4, {1, 1, 1})
	defer physics.destroy_height_field(grid)
	testing.expect(t, grid.rowCount > 0 && grid.columnCount > 0)
}

@(test)
geometry_compounds :: proc(t: ^testing.T) {
	compound, mesh := make_compound()
	defer physics.destroy_compound(compound)
	defer physics.destroy_mesh(mesh)
	testing.expect(
		t,
		compound.sphereCount == 1 && compound.capsuleCount == 1 && compound.hullCount == 1 && compound.meshCount == 1,
	)
	aabb := physics.compute_compound_aabb(compound, {{0, 10, 0}, {0, 0, 0, 1}})
	testing.expectf(
		t,
		near(aabb.lower_bound, {-3, 9, -0.5}, 0.01) && near(aabb.upper_bound, {3, 11.5, 0.5}, 0.01),
		"%v",
		aabb,
	)
}

// A compound of a sphere (x = −2.5), a capsule (x = 2.5), a unit cube (at the origin) and a box mesh (above it).
make_compound :: proc() -> (^physics.Compound_Data, ^physics.Mesh_Data) {
	mesh := physics.create_box_mesh({0, 1, 0}, {0.5, 0.5, 0.5})
	cube := physics.make_cube_hull(0.5)
	material := physics.Surface_Material {
		friction = 0.6,
	}
	spheres := [1]physics.Compound_Sphere_Def{{{{-2.5, 0, 0}, 0.5}, material}}
	capsules := [1]physics.Compound_Capsule_Def{{{{2.5, -0.5, 0}, {2.5, 0.5, 0}, 0.5}, material}}
	hulls := [1]physics.Compound_Hull_Def{{&cube.base, {{0, 0, 0}, {0, 0, 0, 1}}, material}}
	mesh_materials := [1]physics.Surface_Material{material}
	meshes := [1]physics.Compound_Mesh_Def{{mesh, {{0, 0, 0}, {0, 0, 0, 1}}, {1, 1, 1}, &mesh_materials[0], 1}}
	def := physics.Compound_Def {
		spheres       = &spheres[0],
		sphere_count  = 1,
		capsules      = &capsules[0],
		capsule_count = 1,
		hulls         = &hulls[0],
		hull_count    = 1,
		meshes        = &meshes[0],
		mesh_count    = 1,
	}
	return physics.create_compound(def), mesh
}

@(test)
geometry_mass_and_bounds :: proc(t: ^testing.T) {
	PI :: f32(3.14159265)
	sphere := physics.Sphere{{1, 0, 0}, 1}
	sphere_mass := physics.compute_sphere_mass(sphere, 3)
	testing.expectf(t, near_f32(sphere_mass.mass, 4 * PI, 1e-3) && sphere_mass.center == {1, 0, 0}, "%v", sphere_mass)
	capsule := physics.Capsule{{0, -1, 0}, {0, 1, 0}, 0.5}
	capsule_mass := physics.compute_capsule_mass(capsule, 1)
	// A cylinder 2 long plus a ball: π r² · 2 + 4/3 π r³.
	testing.expectf(t, near_f32(capsule_mass.mass, PI * 0.5 + PI / 6, 1e-3), "%v", capsule_mass.mass)
	cube := physics.make_cube_hull(0.5)
	hull_mass := physics.compute_hull_mass(&cube.base, 2)
	testing.expect(t, near_f32(hull_mass.mass, 2, 1e-4) && near_f32(hull_mass.inertia.cx.x, 2.0 / 6, 1e-4))

	at := physics.Transform{{0, 5, 0}, {0, 0, 0, 1}}
	sphere_aabb := physics.compute_sphere_aabb(sphere, at)
	testing.expect(t, near(sphere_aabb.lower_bound, {0, 4, -1}) && near(sphere_aabb.upper_bound, {2, 6, 1}))
	capsule_aabb := physics.compute_capsule_aabb(capsule, at)
	testing.expect(
		t,
		near(capsule_aabb.lower_bound, {-0.5, 3.5, -0.5}) && near(capsule_aabb.upper_bound, {0.5, 6.5, 0.5}),
	)
	hull_aabb := physics.compute_hull_aabb(&cube.base, at)
	testing.expect(t, near(hull_aabb.lower_bound, {-0.5, 4.5, -0.5}) && near(hull_aabb.upper_bound, {0.5, 5.5, 0.5}))
}

// The deep (whole world) hash of a physics Extra.
api_deep_hash :: proc(extra: ^sim.Extra) -> u64 {
	buffer: [dynamic]u8
	defer delete(buffer)
	extra.hash(extra.data, 0, &buffer)
	return sim.hash_bytes(buffer[:])
}

Geometry_Block :: struct {
	terrain: [3]physics.Body_Ref, // a mesh, a height field, a compound
	shapes:  [3]physics.Shape_Ref,
	balls:   [3]physics.Body_Ref, // one falling onto each
}

// A world with a static floor made before `extra`, as both sides of a late join have it.
geometry_world :: proc() -> (world: ^physics.World, extra: sim.Extra) {
	world = api_world()
	box(world, {0, -10, 0}, {50, 0.5, 50}, .Static)
	extra = physics.extra(world, Geometry_Block)
	return
}

// Mesh, height field and baked compound shapes made after tick 0: a portable image carries their geometry into a
// second world, which then answers queries and steps the same, and keeps answering once the first world and the
// host geometry its shapes point to are gone.
@(test)
geometry_shapes_cross_in_an_image :: proc(t: ^testing.T) {
	block: Geometry_Block
	world, extra := geometry_world()
	shape_def := physics.default_shape_def()
	body_def := physics.default_body_def()

	// Unlike hulls, these shapes keep a pointer to the caller's geometry: it lives as long as the world.
	mesh := physics.create_box_mesh({}, {2, 0.5, 2})
	body_def.position = {-10, 0, 0}
	block.terrain[0] = physics.create_body(world, body_def, 100)
	block.shapes[0] = physics.create_mesh_shape(world, block.terrain[0], shape_def, mesh, {1, 1, 1})

	heights := [9]f32{0, 0, 0, 0, 0.5, 0, 0, 0, 0}
	cells := [4]u8{}
	field_def := physics.Height_Field_Def {
		heights               = &heights[0],
		material_indices      = &cells[0],
		scale                 = {2, 1, 2},
		count_x               = 3,
		count_z               = 3,
		global_maximum_height = 1,
	}
	field := physics.create_height_field(field_def)
	body_def.position = {-2, 0, -2}
	block.terrain[1] = physics.create_body(world, body_def, 101)
	block.shapes[1] = physics.create_height_field_shape(world, block.terrain[1], shape_def, field)

	compound, compound_mesh := make_compound()
	body_def.position = {10, 0, 0}
	block.terrain[2] = physics.create_body(world, body_def, 102)
	block.shapes[2] = physics.create_baked_compound_shape(world, block.terrain[2], shape_def, compound)

	for x, i in ([3]f32{-10, 0, 10}) {
		ball_def := physics.default_body_def()
		ball_def.type = .Dynamic
		ball_def.position = {x + 0.2, 3, 0.1}
		block.balls[i] = physics.create_body(world, ball_def, u64(200 + i))
		physics.create_sphere_shape(world, block.balls[i], shape_def, {{}, 0.3})
	}
	testing.expect_value(t, physics.check_refs(world, &block), "")
	testing.expect_value(t, physics.shape_type(world, block.shapes[0]), physics.Shape_Type.Mesh)
	testing.expect_value(t, physics.shape_type(world, block.shapes[1]), physics.Shape_Type.Height)
	testing.expect_value(t, physics.shape_type(world, block.shapes[2]), physics.Shape_Type.Compound)
	testing.expect(t, physics.shape_mesh(world, block.shapes[0]).data == mesh, "the caller's mesh, not a copy")
	testing.expect(t, physics.shape_height_field(world, block.shapes[1]) == field)
	testing.expect(t, physics.shape_compound(world, block.shapes[2]) == compound)
	steps(world, 10)
	extra.save(extra.data, 0)
	image := extra.image(extra.data, 0, true) // just saved: the live world is the slot's

	late, late_extra := geometry_world()
	defer physics.destroy(late)
	testing.expect(t, late_extra.load(late_extra.data, image))
	testing.expect_value(t, api_deep_hash(&late_extra), api_deep_hash(&extra))
	testing.expect_value(t, physics.check_refs(late, &block), "")
	for shape, i in block.shapes {
		testing.expect_value(t, physics.shape_type(late, shape), physics.shape_type(world, shape))
		testing.expect_value(t, physics.shape_aabb(late, shape), physics.shape_aabb(world, shape))
		testing.expect_value(t, physics.body_tag(late, block.terrain[i]), u64(100 + i))
	}
	late_mesh := physics.shape_mesh(late, block.shapes[0])
	testing.expect(t, late_mesh.data != nil && late_mesh.data != mesh && late_mesh.data.triangleCount == 12)
	for _ in 0 ..< 60 {
		steps(world, 1)
		steps(late, 1)
	}
	testing.expect_value(t, api_deep_hash(&late_extra), api_deep_hash(&extra))
	for ball in block.balls {
		testing.expect_value(t, physics.body_position(late, ball), physics.body_position(world, ball))
		testing.expect(t, physics.body_position(world, ball).y > -5, "every ball rests on its piece")
	}
	// Rays down onto each piece hit the same point of the same shape, with its body's tag.
	RAYS :: [?]f32{-11.5, -10, -1.5, 0, 7.6, 10, 12.5}
	hits: [len(RAYS)]physics.Hit
	for x, i in RAYS {
		ok: bool
		hits[i], ok = physics.world_cast_ray_closest(world, {x, 5, 0.45}, {0, -20, 0})
		late_hit, late_ok := physics.world_cast_ray_closest(late, {x, 5, 0.45}, {0, -20, 0})
		testing.expect(t, ok && late_ok && hits[i].tag != 0)
		testing.expectf(t, hits[i] == late_hit, "x %v: %v, late %v", x, hits[i], late_hit)
	}

	// The late world holds its own copies: it runs on with the first world and the host geometry gone.
	physics.destroy(world)
	physics.destroy_mesh(mesh)
	physics.destroy_height_field(field)
	physics.destroy_compound(compound)
	physics.destroy_mesh(compound_mesh)
	for x, i in RAYS {
		late_hit, late_ok := physics.world_cast_ray_closest(late, {x, 5, 0.45}, {0, -20, 0})
		testing.expect(t, late_ok && late_hit == hits[i])
	}
	steps(late, 10)
}
