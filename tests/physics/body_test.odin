// The Bodies group (src/physics/SPEC.md, What physics covers): every body proc once, through physics. Setters are
// read back through their getters. The api_* helpers serve the other per-group files (shape, world, geometry,
// queries).
package test_physics

import "core:testing"

import "unified:physics"

// A world with Box3D's defaults (gravity nil) or the given gravity.
api_world :: proc(gravity: Maybe([3]f32) = nil, hit_event_threshold: f32 = 0) -> ^physics.World {
	return physics.create({gravity = gravity, hit_event_threshold = hit_event_threshold})
}

// A body with one box shape (density 1, Box3D's default being water's 1000, unless the def says otherwise).
api_box :: proc(
	world: ^physics.World,
	pos, half: [3]f32,
	type: physics.Body_Type = .Dynamic,
	tag: u64 = 0,
	shape_def: ^physics.Shape_Def = nil,
) -> (
	body: physics.Body_Ref,
	shape: physics.Shape_Ref,
) {
	body_def := physics.default_body_def()
	body_def.type = type
	body_def.position = pos
	body = physics.create_body(world, &body_def, tag)
	default_def := physics.default_shape_def()
	default_def.density = 1
	hull := physics.make_box_hull(half.x, half.y, half.z)
	shape = physics.create_hull_shape(world, body, shape_def != nil ? shape_def : &default_def, &hull.base)
	return
}


// A quarter turn about +y: x goes to −z.
QUARTER_Y :: [4]f32{0, 0.70710677, 0, 0.70710677}

@(test)
body_type_and_set_type :: proc(t: ^testing.T) {
	world := api_world()
	defer physics.destroy(world)
	body, _ := api_box(world, {}, {0.5, 0.5, 0.5}, .Static)
	testing.expect_value(t, physics.body_type(world, body), physics.Body_Type.Static)
	physics.body_set_type(world, body, .Kinematic)
	testing.expect_value(t, physics.body_type(world, body), physics.Body_Type.Kinematic)
	physics.body_set_type(world, body, .Dynamic)
	testing.expect_value(t, physics.body_type(world, body), physics.Body_Type.Dynamic)
	testing.expect(t, physics.body_mass(world, body) > 0, "a dynamic body gets its shapes' mass")
}

@(test)
body_transform_points_and_vectors :: proc(t: ^testing.T) {
	world := api_world([3]f32{})
	defer physics.destroy(world)
	body, _ := api_box(world, {}, {0.5, 0.5, 0.5})
	physics.body_set_transform(world, body, {1, 2, 3}, QUARTER_Y)
	testing.expect_value(t, physics.body_position(world, body), [3]f32{1, 2, 3})
	testing.expect_value(t, physics.body_rotation(world, body), QUARTER_Y)
	testing.expect_value(t, physics.body_transform(world, body), physics.Transform{{1, 2, 3}, QUARTER_Y})
	testing.expect(t, near(physics.body_world_vector(world, body, {1, 0, 0}), {0, 0, -1}, 1e-6))
	testing.expect(t, near(physics.body_local_vector(world, body, {0, 0, -1}), {1, 0, 0}, 1e-6))
	testing.expect(t, near(physics.body_world_point(world, body, {1, 0, 0}), {1, 2, 2}, 1e-6))
	testing.expect(t, near(physics.body_local_point(world, body, {1, 2, 2}), {1, 0, 0}, 1e-6))

	// A kinematic body reaches its target in the step it was given.
	platform, _ := api_box(world, {}, {1, 0.1, 1}, .Kinematic)
	physics.body_set_target_transform(world, platform, {{2, 0, 0}, {0, 0, 0, 1}}, DT)
	testing.expect(t, near(physics.body_linear_velocity(world, platform), {2 / DT, 0, 0}, 1e-2))
	steps(world, 1)
	position := physics.body_position(world, platform)
	testing.expectf(t, near(position, {2, 0, 0}, 1e-4), "kinematic target: %v", position)
}

@(test)
body_velocities :: proc(t: ^testing.T) {
	world := api_world([3]f32{})
	defer physics.destroy(world)
	body, _ := api_box(world, {}, {0.5, 0.5, 0.5})
	physics.body_set_linear_velocity(world, body, {1, 0, 0})
	physics.body_set_angular_velocity(world, body, {0, 2, 0})
	testing.expect_value(t, physics.body_linear_velocity(world, body), [3]f32{1, 0, 0})
	testing.expect_value(t, physics.body_angular_velocity(world, body), [3]f32{0, 2, 0})
	// v + ω × r at r = (1, 0, 0): (1, 0, 0) + (0, 0, −2).
	testing.expect(t, near(physics.body_local_point_velocity(world, body, {1, 0, 0}), {1, 0, -2}, 1e-6))
	testing.expect(t, near(physics.body_world_point_velocity(world, body, {1, 0, 0}), {1, 0, -2}, 1e-6))
}

@(test)
body_forces_and_impulses :: proc(t: ^testing.T) {
	world := api_world([3]f32{})
	defer physics.destroy(world)
	// Unit cubes at density 1: mass 1, so an impulse is the velocity it adds.
	pushed, _ := api_box(world, {0, 0, 0}, {0.5, 0.5, 0.5})
	physics.body_apply_linear_impulse_to_center(world, pushed, {0, 0, 3})
	testing.expect(t, near(physics.body_linear_velocity(world, pushed), {0, 0, 3}))
	testing.expect_value(t, physics.body_angular_velocity(world, pushed), [3]f32{})

	off_center, _ := api_box(world, {5, 0, 0}, {0.5, 0.5, 0.5})
	physics.body_apply_linear_impulse(world, off_center, {1, 0, 0}, {5, 0.5, 0})
	testing.expect(t, near(physics.body_linear_velocity(world, off_center), {1, 0, 0}))
	testing.expect(t, physics.body_angular_velocity(world, off_center).z < 0, "pushed above its centre: it tips")

	spun, _ := api_box(world, {10, 0, 0}, {0.5, 0.5, 0.5})
	physics.body_apply_angular_impulse(world, spun, {0, 1, 0})
	// A unit cube's inertia is m(1² + 1²)/12 = 1/6.
	testing.expect(t, near(physics.body_angular_velocity(world, spun), {0, 6, 0}, 1e-3))

	forced, _ := api_box(world, {15, 0, 0}, {0.5, 0.5, 0.5})
	physics.body_apply_force_to_center(world, forced, {0, 64, 0})
	tipped, _ := api_box(world, {20, 0, 0}, {0.5, 0.5, 0.5})
	physics.body_apply_force(world, tipped, {64, 0, 0}, {20, 0.5, 0})
	twisted, _ := api_box(world, {25, 0, 0}, {0.5, 0.5, 0.5})
	physics.body_apply_torque(world, twisted, {0, 64, 0})
	steps(world, 1)
	// A force F over one step adds F · dt.
	testing.expect(t, near(physics.body_linear_velocity(world, forced), {0, 1, 0}, 1e-4))
	testing.expect(t, near(physics.body_linear_velocity(world, tipped), {1, 0, 0}, 1e-4))
	testing.expect(t, physics.body_angular_velocity(world, tipped).z < 0)
	testing.expect(t, near(physics.body_angular_velocity(world, twisted), {0, 6, 0}, 1e-2))
	// The force is used up by the step.
	steps(world, 1)
	testing.expect(t, near(physics.body_linear_velocity(world, forced), {0, 1, 0}, 1e-4))
}

@(test)
body_mass_inertia_and_mass_data :: proc(t: ^testing.T) {
	world := api_world([3]f32{})
	defer physics.destroy(world)
	body, _ := api_box(world, {0, 3, 0}, {1, 0.5, 0.5}) // 2 × 1 × 1 at density 1: mass 2
	testing.expect(t, near_f32(physics.body_mass(world, body), 2))
	testing.expect(t, near_f32(physics.body_inverse_mass(world, body), 0.5))
	// Box inertia: m(b² + c²)/12 per axis, full sizes (2, 1, 1).
	inertia := physics.body_local_rotational_inertia(world, body)
	testing.expectf(
		t,
		near({inertia.cx.x, inertia.cy.y, inertia.cz.z}, {1.0 / 3, 10.0 / 12, 10.0 / 12}),
		"%v",
		inertia,
	)
	testing.expect(t, inertia.cx.y == 0 && inertia.cy.z == 0 && inertia.cz.x == 0)
	inverse := physics.body_world_inverse_rotational_inertia(world, body)
	testing.expectf(t, near({inverse.cx.x, inverse.cy.y, inverse.cz.z}, {3, 1.2, 1.2}, 1e-3), "%v", inverse)
	testing.expect_value(t, physics.body_local_center(world, body), [3]f32{})
	testing.expect_value(t, physics.body_world_center(world, body), [3]f32{0, 3, 0})
	data := physics.body_mass_data(world, body)
	testing.expect(t, near_f32(data.mass, 2) && data.center == {} && data.inertia == inertia)

	set := physics.Mass_Data {
		mass    = 5,
		center  = {0, 1, 0},
		inertia = {{1, 0, 0}, {0, 2, 0}, {0, 0, 3}},
	}
	physics.body_set_mass_data(world, body, set)
	testing.expect_value(t, physics.body_mass(world, body), 5)
	testing.expect_value(t, physics.body_local_center(world, body), [3]f32{0, 1, 0})
	testing.expect_value(t, physics.body_world_center(world, body), [3]f32{0, 4, 0})
	got := physics.body_mass_data(world, body)
	testing.expectf(t, got == set, "mass data %v", got)
	physics.body_apply_mass_from_shapes(world, body)
	testing.expect(t, near_f32(physics.body_mass(world, body), 2))
	testing.expect_value(t, physics.body_local_center(world, body), [3]f32{})
}

@(test)
body_damping_and_gravity_scale :: proc(t: ^testing.T) {
	world := api_world()
	defer physics.destroy(world)
	body, _ := api_box(world, {}, {0.5, 0.5, 0.5})
	physics.body_set_linear_damping(world, body, 0.25)
	physics.body_set_angular_damping(world, body, 0.75)
	physics.body_set_gravity_scale(world, body, -0.5)
	testing.expect_value(t, physics.body_linear_damping(world, body), 0.25)
	testing.expect_value(t, physics.body_angular_damping(world, body), 0.75)
	testing.expect_value(t, physics.body_gravity_scale(world, body), -0.5)
	steps(world, 1)
	testing.expect(t, physics.body_linear_velocity(world, body).y > 0, "negative gravity scale: it rises")
}

@(test)
body_sleep_and_enable :: proc(t: ^testing.T) {
	world := api_world()
	defer physics.destroy(world)
	body, _ := api_box(world, {}, {0.5, 0.5, 0.5})
	other, _ := api_box(world, {5, 0, 0}, {0.5, 0.5, 0.5})
	testing.expect(t, physics.body_is_awake(world, body))
	physics.body_set_awake(world, body, false)
	testing.expect(t, !physics.body_is_awake(world, body))
	physics.body_set_awake(world, body, true)
	testing.expect(t, physics.body_is_awake(world, body))
	testing.expect(t, physics.body_is_sleep_enabled(world, body))
	physics.body_enable_sleep(world, body, false)
	testing.expect(t, !physics.body_is_sleep_enabled(world, body))
	physics.body_set_sleep_threshold(world, body, 0.125)
	testing.expect_value(t, physics.body_sleep_threshold(world, body), 0.125)

	testing.expect(t, physics.body_is_enabled(world, other))
	physics.body_disable(world, other)
	testing.expect(t, !physics.body_is_enabled(world, other))
	steps(world, 4)
	testing.expect_value(t, physics.body_position(world, other), [3]f32{5, 0, 0}) // out of the simulation
	physics.body_enable(world, other)
	testing.expect(t, physics.body_is_enabled(world, other))
	steps(world, 4)
	testing.expect(t, physics.body_position(world, other).y < 0)
}

@(test)
body_motion_flags :: proc(t: ^testing.T) {
	world := api_world()
	defer physics.destroy(world)
	body, shape := api_box(world, {}, {0.5, 0.5, 0.5})
	locks := physics.Motion_Locks {
		linear_x  = true,
		angular_z = true,
	}
	physics.body_set_motion_locks(world, body, locks)
	testing.expect_value(t, physics.body_motion_locks(world, body), locks)
	physics.body_set_bullet(world, body, true)
	testing.expect(t, physics.body_is_bullet(world, body))
	physics.body_set_bullet(world, body, false)
	testing.expect(t, !physics.body_is_bullet(world, body))
	physics.body_allow_fast_rotation(world, body, true)
	testing.expect(t, physics.body_is_fast_rotation_allowed(world, body))
	physics.body_enable_contact_recycling(world, body, true)
	testing.expect(t, physics.body_is_contact_recycling_enabled(world, body))
	physics.body_enable_contact_recycling(world, body, false)
	testing.expect(t, !physics.body_is_contact_recycling_enabled(world, body))
	physics.body_set_safety_factor(world, body, 0.375)
	testing.expect_value(t, physics.body_safety_factor(world, body), 0.375)
	testing.expect(t, !physics.shape_are_hit_events_enabled(world, shape))
	physics.body_enable_hit_events(world, body, true)
	testing.expect(t, physics.shape_are_hit_events_enabled(world, shape))
}

@(test)
body_shapes_joints_and_extents :: proc(t: ^testing.T) {
	world := api_world()
	defer physics.destroy(world)
	body_def := physics.default_body_def()
	body_def.type = .Dynamic
	body_def.position = {0, 5, 0}
	body := physics.create_body(world, &body_def)
	shape_def := physics.default_shape_def()
	shape_def.density = 1
	hull := physics.make_offset_box_hull(1, 0.5, 0.5, {0, 1, 0})
	made: [3]physics.Shape_Ref
	made[0] = physics.create_hull_shape(world, body, &shape_def, &hull.base)
	made[1] = physics.create_sphere_shape(world, body, &shape_def, {{0, 1, 0}, 0.25})
	made[2] = physics.create_capsule_shape(world, body, &shape_def, {{0, 0.75, 0}, {0, 1.25, 0}, 0.25})
	testing.expect_value(t, physics.body_shape_count(world, body), 3)
	shapes: [dynamic]physics.Shape_Ref
	defer delete(shapes)
	append(&shapes, physics.Shape_Ref{index1 = 99}) // replaced, not appended to
	physics.body_shapes(world, body, &shapes)
	testing.expect_value(t, len(shapes), 3)
	if len(shapes) == 3 {
		testing.expect(t, shapes[0].index1 < shapes[1].index1 && shapes[1].index1 < shapes[2].index1, "by index")
		testing.expect(t, shapes[0] == made[0] && shapes[1] == made[1] && shapes[2] == made[2])
	}

	other, _ := api_box(world, {3, 5, 0}, {0.5, 0.5, 0.5})
	testing.expect_value(t, physics.body_joint_count(world, body), 0)
	joint_def := physics.default_motor_joint_def()
	first := physics.create_motor_joint(world, physics.link(body), physics.link(other), &joint_def)
	joint_def = physics.default_motor_joint_def()
	second := physics.create_motor_joint(world, physics.link(other), physics.link(body), &joint_def)
	testing.expect_value(t, physics.body_joint_count(world, body), 2)
	joints: [dynamic]physics.Joint_Ref
	defer delete(joints)
	append(&joints, physics.Joint_Ref{index1 = 99})
	physics.body_joints(world, body, &joints)
	testing.expect_value(t, len(joints), 2)
	if len(joints) == 2 do testing.expect(t, joints[0] == first.joint && joints[1] == second.joint)

	// The hull is 2 × 1 × 1 centred 1 m above the origin; the sphere and capsule stay inside it. Shape AABBs carry
	// Box3D's small margin.
	aabb := physics.body_compute_aabb(world, body)
	testing.expect_value(t, aabb, physics.shape_aabb(world, made[0]))
	testing.expectf(t, near(aabb.lower_bound, {-1, 5.5, -0.5}, 0.025), "aabb %v", aabb)
	testing.expectf(t, near(aabb.upper_bound, {1, 6.5, 0.5}, 0.025), "aabb %v", aabb)
	min_extent := physics.body_min_extent(world, body)
	testing.expectf(t, min_extent > 0 && min_extent <= 0.5 + 1e-4, "min extent %v", min_extent)
	center := physics.body_local_center(world, body)
	extent := physics.body_max_extent(world, body)
	testing.expectf(t, extent.x >= 1 - 1e-4 && extent.y >= 0.5 - 1e-4, "max extent %v", extent)
	testing.expect_value(
		t,
		physics.body_max_extent_origin(world, body),
		extent + [3]f32{abs(center.x), abs(center.y), abs(center.z)},
	)
}

// The defaults physics re-exports are Box3D's.
@(test)
body_and_shape_defaults :: proc(t: ^testing.T) {
	body_def := physics.default_body_def()
	testing.expect_value(t, body_def.type, physics.Body_Type.Static)
	testing.expect_value(t, body_def.rotation, [4]f32{0, 0, 0, 1})
	testing.expect_value(t, body_def.gravity_scale, 1)
	testing.expect(t, body_def.enable_sleep && body_def.is_awake && body_def.is_enabled)
	testing.expect(t, body_def.internal_value != 0 && body_def.name == nil && body_def.user_data == nil)
	shape_def := physics.default_shape_def()
	testing.expect_value(t, shape_def.density, 1000)
	testing.expect(t, shape_def.base_material.friction > 0 && shape_def.filter.mask == max(u64))
	testing.expect(
		t,
		shape_def.filter.category == max(u64) && shape_def.update_body_mass && shape_def.internal_value != 0,
	)
}

// Names are copied into the world (Box3D's names table): a def's name and the setters read back, and a name rolls back
// with the world, so a def may carry one (user_data may not: a pointer).
@(test)
body_and_shape_names :: proc(t: ^testing.T) {
	world := api_world()
	defer physics.destroy(world)
	Named :: struct {
		body: physics.Body_Ref,
	}
	named: Named
	extra := physics.extra(world, Named)
	body_def := physics.default_body_def()
	body_def.name = "crate"
	named.body = physics.create_body(world, &body_def)
	testing.expect_value(t, string(physics.body_name(world, named.body)), "crate")
	shape_def := physics.default_shape_def()
	shape_def.name = "lid"
	hull := physics.make_box_hull(0.5, 0.5, 0.5)
	shape := physics.create_hull_shape(world, named.body, &shape_def, &hull.base)
	testing.expect_value(t, string(physics.shape_name(world, shape)), "lid")
	extra.save(extra.data, 0)
	physics.body_set_name(world, named.body, "barrel")
	physics.shape_set_name(world, shape, "hoop")
	testing.expect_value(t, string(physics.body_name(world, named.body)), "barrel")
	testing.expect_value(t, string(physics.shape_name(world, shape)), "hoop")
	testing.expect(t, extra.restore(extra.data, 0))
	testing.expect_value(t, string(physics.body_name(world, named.body)), "crate")
	testing.expect_value(t, string(physics.shape_name(world, shape)), "lid")
}
