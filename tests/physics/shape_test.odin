// The Shapes group (src/physics/SPEC.md, What physics covers): every shape proc once, through physics (the mesh,
// height field and compound creators with their geometry in geometry_test.odin, the per-shape queries and contact
// data in queries_test.odin).
package test_physics

import "core:testing"

import "unified:physics"

@(test)
shape_create_and_destroy :: proc(t: ^testing.T) {
	world := api_world([3]f32{})
	defer physics.destroy(world)
	body_def := physics.default_body_def()
	body_def.type = .Dynamic_Body
	body := physics.create_body(world, &body_def)
	shape_def := physics.default_shape_def()
	shape_def.density = 1
	sphere := physics.create_sphere_shape(world, body, &shape_def, {{1, 0, 0}, 0.5})
	capsule := physics.create_capsule_shape(world, body, &shape_def, {{0, -1, 0}, {0, 1, 0}, 0.25})
	cube := physics.make_cube_hull(0.5)
	hull := physics.create_hull_shape(world, body, &shape_def, &cube.base)
	// The unit cube moved to x = 10 and stretched to 2 × 1 × 1.
	moved := physics.create_transformed_hull_shape(
		world,
		body,
		&shape_def,
		&cube.base,
		{{10, 0, 0}, {0, 0, 0, 1}},
		{2, 1, 1},
	)
	for shape in ([]physics.Shape_Ref{sphere, capsule, hull, moved}) {
		testing.expect(t, physics.shape_valid(world, shape))
		testing.expect_value(t, physics.shape_body(world, shape), physics.link(body))
	}
	testing.expect_value(t, physics.shape_type(world, sphere), physics.Shape_Type.Sphere_Shape)
	testing.expect_value(t, physics.shape_type(world, capsule), physics.Shape_Type.Capsule_Shape)
	testing.expect_value(t, physics.shape_type(world, hull), physics.Shape_Type.Hull_Shape)
	testing.expect_value(t, physics.shape_type(world, moved), physics.Shape_Type.Hull_Shape)
	moved_mass := physics.shape_compute_mass_data(world, moved)
	testing.expectf(t, api_near_f32(moved_mass.mass, 2) && api_near(moved_mass.center, {10, 0, 0}), "%v", moved_mass)

	// Destroying a shape updates the body's mass and clears the ref; a stale ref is a no-op.
	mass := physics.body_mass(world, body)
	stale := moved
	physics.destroy_shape(world, &moved)
	testing.expect(t, moved == physics.Shape_Ref{})
	testing.expect(t, !physics.shape_valid(world, stale))
	testing.expect(t, api_near_f32(physics.body_mass(world, body), mass - 2))
	again := physics.create_sphere_shape(world, body, &shape_def, {{}, 0.1}) // may reuse the index
	physics.destroy_shape(world, &stale)
	testing.expect(t, stale == physics.Shape_Ref{})
	testing.expect(t, physics.shape_valid(world, again))
	testing.expect_value(t, physics.body_shape_count(world, body), 4)
}

@(test)
shape_geometry_get_and_set :: proc(t: ^testing.T) {
	world := api_world([3]f32{})
	defer physics.destroy(world)
	body_def := physics.default_body_def()
	body_def.type = .Dynamic_Body
	body_def.position = {0, 2, 0}
	body := physics.create_body(world, &body_def)
	shape_def := physics.default_shape_def()
	shape_def.density = 1
	shape := physics.create_sphere_shape(world, body, &shape_def, {{0, 1, 0}, 1})
	testing.expect_value(t, physics.shape_sphere(world, shape), physics.Sphere{{0, 1, 0}, 1})
	testing.expect(t, !physics.shape_is_sensor(world, shape))
	mass := physics.shape_compute_mass_data(world, shape)
	testing.expectf(t, api_near_f32(mass.mass, 4.1887903, 1e-3) && mass.center == {0, 1, 0}, "%v", mass)
	aabb := physics.shape_aabb(world, shape)
	testing.expectf(
		t,
		api_near(aabb.lower_bound, {-1, 2, -1}, 0.025) && api_near(aabb.upper_bound, {1, 4, 1}, 0.025),
		"%v",
		aabb,
	)

	physics.shape_set_capsule(world, shape, {{0, -1, 0}, {0, 1, 0}, 0.5})
	testing.expect_value(t, physics.shape_type(world, shape), physics.Shape_Type.Capsule_Shape)
	testing.expect_value(t, physics.shape_capsule(world, shape), physics.Capsule{{0, -1, 0}, {0, 1, 0}, 0.5})
	physics.shape_set_sphere(world, shape, {{0, 0, 1}, 0.5})
	testing.expect_value(t, physics.shape_type(world, shape), physics.Shape_Type.Sphere_Shape)
	testing.expect_value(t, physics.shape_sphere(world, shape), physics.Sphere{{0, 0, 1}, 0.5})
	box := physics.make_box_hull(1, 2, 3)
	physics.shape_set_hull(world, shape, &box.base)
	testing.expect_value(t, physics.shape_type(world, shape), physics.Shape_Type.Hull_Shape)
	got_hull := physics.shape_hull(world, shape)
	testing.expect(t, got_hull != nil && got_hull != &box.base, "Box3D's copy")
	if got_hull != nil do testing.expectf(t, got_hull.vertexCount == 8 && api_near_f32(got_hull.volume, 48, 1e-3), "%v", got_hull.volume)
	mesh := physics.create_box_mesh({}, {1, 1, 1})
	defer physics.destroy_mesh(mesh)
	physics.shape_set_mesh(world, shape, mesh, {2, 1, 1})
	testing.expect_value(t, physics.shape_type(world, shape), physics.Shape_Type.Mesh_Shape)
	got_mesh := physics.shape_mesh(world, shape)
	testing.expect_value(t, got_mesh.scale, [3]f32{2, 1, 1})
	testing.expect(t, got_mesh.data != nil && got_mesh.data.triangleCount == mesh.triangleCount)
	aabb = physics.shape_aabb(world, shape)
	testing.expectf(
		t,
		api_near(aabb.lower_bound, {-2, 1, -1}, 0.025) && api_near(aabb.upper_bound, {2, 3, 1}, 0.025),
		"%v",
		aabb,
	)

	shape_def.is_sensor = true
	sensor := physics.create_sphere_shape(world, body, &shape_def, {{}, 1})
	testing.expect(t, physics.shape_is_sensor(world, sensor))
}

@(test)
shape_materials_and_density :: proc(t: ^testing.T) {
	world := api_world([3]f32{})
	defer physics.destroy(world)
	body, shape := api_box(world, {}, {0.5, 0.5, 0.5})
	physics.shape_set_density(world, shape, 3)
	testing.expect_value(t, physics.shape_density(world, shape), 3)
	testing.expect(t, api_near_f32(physics.body_mass(world, body), 3), "update_body_mass by default")
	physics.shape_set_density(world, shape, 5, update_body_mass = false)
	testing.expect(t, api_near_f32(physics.body_mass(world, body), 3))
	physics.shape_set_friction(world, shape, 0.25)
	testing.expect_value(t, physics.shape_friction(world, shape), 0.25)
	physics.shape_set_restitution(world, shape, 0.5)
	testing.expect_value(t, physics.shape_restitution(world, shape), 0.5)
	material := physics.Surface_Material {
		friction           = 0.75,
		restitution        = 0.125,
		rolling_resistance = 0.25,
		tangent_velocity   = {1, 0, 0},
		user_material_id   = 42,
	}
	physics.shape_set_surface_material(world, shape, material)
	testing.expect_value(t, physics.shape_surface_material(world, shape), material)
	testing.expect_value(t, physics.shape_mesh_material_count(world, shape), 1)

	// A mesh with a material per triangle (materials 0 and 1 from the def).
	mesh := physics.create_grid_mesh(4, 4, 1, material_count = 2)
	defer physics.destroy_mesh(mesh)
	materials := [2]physics.Surface_Material {
		{friction = 0.1, user_material_id = 10},
		{friction = 0.2, user_material_id = 11},
	}
	mesh_def := physics.default_shape_def()
	mesh_def.materials = &materials[0]
	mesh_def.material_count = 2
	ground_def := physics.default_body_def()
	ground := physics.create_body(world, &ground_def)
	floor := physics.create_mesh_shape(world, ground, &mesh_def, mesh)
	testing.expect_value(t, physics.shape_type(world, floor), physics.Shape_Type.Mesh_Shape)
	testing.expect_value(t, physics.shape_mesh_material_count(world, floor), 2)
	testing.expect_value(t, physics.shape_mesh_surface_material(world, floor, 1).user_material_id, 11)
	physics.shape_set_mesh_material(world, floor, material, 1)
	testing.expect_value(t, physics.shape_mesh_surface_material(world, floor, 1), material)
	testing.expect_value(t, physics.shape_mesh_surface_material(world, floor, 0).user_material_id, 10)
}

@(test)
shape_filter_and_event_switches :: proc(t: ^testing.T) {
	world := api_world()
	defer physics.destroy(world)
	_, shape := api_box(world, {}, {0.5, 0.5, 0.5})
	filter := physics.Filter {
		category_bits = 1 << 3,
		mask_bits     = 1 << 1 | 1 << 2,
		group_index   = -2,
	}
	physics.shape_set_filter(world, shape, filter)
	testing.expect_value(t, physics.shape_filter(world, shape), filter)
	for flag in ([]bool{true, false}) {
		physics.shape_enable_sensor_events(world, shape, flag)
		testing.expect_value(t, physics.shape_are_sensor_events_enabled(world, shape), flag)
		physics.shape_enable_contact_events(world, shape, flag)
		testing.expect_value(t, physics.shape_are_contact_events_enabled(world, shape), flag)
		physics.shape_enable_hit_events(world, shape, flag)
		testing.expect_value(t, physics.shape_are_hit_events_enabled(world, shape), flag)
	}
}

@(test)
shape_apply_wind :: proc(t: ^testing.T) {
	world := api_world([3]f32{})
	defer physics.destroy(world)
	body_def := physics.default_body_def()
	body_def.type = .Dynamic_Body
	body := physics.create_body(world, &body_def)
	shape_def := physics.default_shape_def()
	shape_def.density = 1
	ball := physics.create_sphere_shape(world, body, &shape_def, {{}, 0.5})
	physics.shape_apply_wind(world, ball, {10, 0, 0}, drag = 1, lift = 0, max_speed = 20)
	api_steps(world, 1)
	velocity := physics.body_linear_velocity(world, body)
	testing.expectf(t, velocity.x > 0 && velocity.y == 0 && velocity.z == 0, "blown downwind: %v", velocity)
}
