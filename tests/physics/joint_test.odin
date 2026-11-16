// src/physics/joint.odin: every joint type created between two bodies and stepped, joint_as, the generic procs on
// any joint ref, each type's setters read back through its getters (and its "current" getters after a step), and
// joints under save/restore through physics.extra.
package test_physics

import "core:math"
import "core:testing"

import "unified:physics"

JOINT_SUBSTEPS :: 4

// A sphere body (radius 0.25, density 1) at `pos`: bodies 1 m apart don't touch.
joint_body :: proc(world: ^physics.World, pos: [3]f32, type: physics.Body_Type = .Dynamic_Body) -> physics.Body_Ref {
	body_def := physics.default_body_def()
	body_def.type = type
	body_def.position = pos
	ref := physics.create_body(world, &body_def)
	shape_def := physics.default_shape_def()
	shape_def.density = 1
	physics.create_sphere_shape(world, ref, &shape_def, {radius = 0.25})
	return ref
}

// A static body A at `pos` and a dynamic body B 1 m along +x: the pair every joint below connects.
joint_pair :: proc(world: ^physics.World, pos: [3]f32) -> (body_a, body_b: physics.Body_Ref) {
	return joint_body(world, pos, .Static_Body), joint_body(world, pos + {1, 0, 0})
}

joint_steps :: proc(world: ^physics.World, count: int) {
	for _ in 0 ..< count do physics.step(world, DT, JOINT_SUBSTEPS)
}

joint_finite :: proc(value: f32) -> bool {
	return value == value && abs(value) < 1e30
}

joint_near :: proc(a, b: [3]f32, tolerance: f32) -> bool {
	delta := a - b
	return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z <= tolerance * tolerance
}

joint_length :: proc(vector: [3]f32) -> f32 {
	return math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
}

// B's frame on A sits at B's origin, so the joints start satisfied.
JOINT_FRAME_AT_B :: physics.Transform{{1, 0, 0}, {0, 0, 0, 1}}

// Every joint type, created between two bodies (the motor, mover and pogo on the World's anchor), stepped half a
// second: each is alive, of its type, on its bodies; the rigid ones hold B, the filter joint lets it fall.
@(test)
joint_every_type_steps :: proc(t: ^testing.T) {
	world := physics.create({anchor = true})
	defer physics.destroy(world)
	anchor := physics.world_anchor(world)
	testing.expect(t, physics.body_valid(world, anchor))

	distance_a, distance_b := joint_pair(world, {0, 5, 0})
	distance_def := physics.default_distance_joint_def()
	distance_def.length = 1
	distance := physics.create_distance_joint(world, physics.link(distance_a), physics.link(distance_b), &distance_def)

	filter_a, filter_b := joint_pair(world, {4, 5, 0})
	filter_def := physics.default_filter_joint_def()
	filter := physics.create_filter_joint(world, physics.link(filter_a), physics.link(filter_b), &filter_def)

	motor_b := joint_body(world, {8, 5, 0})
	motor_def := physics.default_motor_joint_def()
	motor := physics.create_motor_joint(world, anchor, physics.link(motor_b), &motor_def)

	mover_b := joint_body(world, {12, 5, 0})
	mover_def := physics.default_mover_joint_def()
	mover := physics.create_mover_joint(world, anchor, physics.link(mover_b), &mover_def)

	parallel_a, parallel_b := joint_pair(world, {16, 5, 0})
	parallel_def := physics.default_parallel_joint_def()
	parallel := physics.create_parallel_joint(world, physics.link(parallel_a), physics.link(parallel_b), &parallel_def)

	pogo_b := joint_body(world, {20, 5, 0})
	pogo_def := physics.default_pogo_joint_def()
	pogo := physics.create_pogo_joint(world, anchor, physics.link(pogo_b), &pogo_def)

	prismatic_a, prismatic_b := joint_pair(world, {24, 5, 0})
	prismatic_def := physics.default_prismatic_joint_def()
	prismatic_def.base.local_frame_a = JOINT_FRAME_AT_B
	prismatic := physics.create_prismatic_joint(
		world,
		physics.link(prismatic_a),
		physics.link(prismatic_b),
		&prismatic_def,
	)

	revolute_a, revolute_b := joint_pair(world, {28, 5, 0})
	revolute_def := physics.default_revolute_joint_def()
	revolute_def.base.local_frame_a = JOINT_FRAME_AT_B
	revolute := physics.create_revolute_joint(world, physics.link(revolute_a), physics.link(revolute_b), &revolute_def)

	spherical_a, spherical_b := joint_pair(world, {32, 5, 0})
	spherical_def := physics.default_spherical_joint_def()
	spherical_def.base.local_frame_a = JOINT_FRAME_AT_B
	spherical := physics.create_spherical_joint(
		world,
		physics.link(spherical_a),
		physics.link(spherical_b),
		&spherical_def,
	)

	weld_a, weld_b := joint_pair(world, {36, 5, 0})
	weld_def := physics.default_weld_joint_def()
	weld_def.base.local_frame_a = JOINT_FRAME_AT_B
	weld := physics.create_weld_joint(world, physics.link(weld_a), physics.link(weld_b), &weld_def)

	wheel_a, wheel_b := joint_pair(world, {40, 5, 0})
	wheel_def := physics.default_wheel_joint_def()
	wheel_def.base.local_frame_a = JOINT_FRAME_AT_B
	wheel := physics.create_wheel_joint(world, physics.link(wheel_a), physics.link(wheel_b), &wheel_def)

	joint_steps(world, 32)

	testing.expect_value(t, physics.joint_type(world, distance), physics.Joint_Type.Distance_Joint)
	testing.expect_value(t, physics.joint_type(world, filter), physics.Joint_Type.Filter_Joint)
	testing.expect_value(t, physics.joint_type(world, motor), physics.Joint_Type.Motor_Joint)
	testing.expect_value(t, physics.joint_type(world, mover), physics.Joint_Type.Mover_Joint)
	testing.expect_value(t, physics.joint_type(world, parallel), physics.Joint_Type.Parallel_Joint)
	testing.expect_value(t, physics.joint_type(world, pogo), physics.Joint_Type.Pogo_Joint)
	testing.expect_value(t, physics.joint_type(world, prismatic), physics.Joint_Type.Prismatic_Joint)
	testing.expect_value(t, physics.joint_type(world, revolute), physics.Joint_Type.Revolute_Joint)
	testing.expect_value(t, physics.joint_type(world, spherical), physics.Joint_Type.Spherical_Joint)
	testing.expect_value(t, physics.joint_type(world, weld), physics.Joint_Type.Weld_Joint)
	testing.expect_value(t, physics.joint_type(world, wheel), physics.Joint_Type.Wheel_Joint)
	for joint in ([]physics.Joint_Ref {
			distance.joint,
			filter.joint,
			motor.joint,
			mover.joint,
			parallel.joint,
			pogo.joint,
			prismatic.joint,
			revolute.joint,
			spherical.joint,
			weld.joint,
			wheel.joint,
		}) {
		testing.expect(t, physics.joint_valid(world, joint))
	}
	testing.expect_value(t, physics.joint_body_a(world, weld), physics.link(weld_a))
	testing.expect_value(t, physics.joint_body_b(world, weld), physics.link(weld_b))
	testing.expect_value(t, physics.joint_body_a(world, pogo), anchor)
	testing.expect_value(t, physics.joint_body_b(world, pogo), physics.link(pogo_b))

	// The distance joint keeps its length; the anchored ones keep B where it was (y), the filter joint doesn't.
	distance_now := physics.body_position(world, distance_b) - physics.body_position(world, distance_a)
	testing.expectf(t, abs(joint_length(distance_now) - 1) < 0.05, "distance: %v", distance_now)
	for body, i in ([]physics.Body_Ref{prismatic_b, revolute_b, spherical_b, weld_b, wheel_b}) {
		start := [3]f32{f32(24 + 4 * i) + 1, 5, 0}
		testing.expectf(
			t,
			joint_near(physics.body_position(world, body), start, 0.05),
			"body %d: %v",
			i,
			physics.body_position(world, body),
		)
	}
	testing.expect(t, physics.body_position(world, filter_b).y < 4.5)
}

// A world without the anchor has none to give.
@(test)
joint_world_anchor_without_one :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	testing.expect_value(t, physics.world_anchor(world), physics.Body_Link{})
	testing.expect(t, !physics.body_valid(world, physics.world_anchor(world)))
}

// joint_as converts an untyped ref to its own type only, and never a zero or dead one.
@(test)
joint_as_checks_the_type :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	body_a, body_b := joint_pair(world, {})
	def := physics.default_revolute_joint_def()
	hinge := physics.create_revolute_joint(world, physics.link(body_a), physics.link(body_b), &def)
	untyped := hinge.joint
	as_revolute, is_revolute := physics.joint_as(world, untyped, physics.Revolute_Joint_Ref)
	testing.expect(t, is_revolute)
	testing.expect_value(t, as_revolute, hinge)
	_, is_weld := physics.joint_as(world, untyped, physics.Weld_Joint_Ref)
	testing.expect(t, !is_weld)
	_, zero_ok := physics.joint_as(world, physics.Joint_Ref{}, physics.Revolute_Joint_Ref)
	testing.expect(t, !zero_ok)
	physics.destroy_joint(world, &hinge)
	_, dead_ok := physics.joint_as(world, untyped, physics.Revolute_Joint_Ref)
	testing.expect(t, !dead_ok)
}

// The generic procs, on a typed ref and an untyped one alike.
@(test)
joint_generic_procs :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	body_a, body_b := joint_pair(world, {0, 5, 0})
	// The weld point is A's origin, 1 m from B's centre: it holds B's weight with a force and a torque.
	def := physics.default_weld_joint_def()
	def.base.local_frame_b = {{-1, 0, 0}, {0, 0, 0, 1}}
	weld := physics.create_weld_joint(world, physics.link(body_a), physics.link(body_b), &def)
	untyped := weld.joint

	frame_a := physics.Transform{{0.5, 0, 0}, {0, 0, 0, 1}}
	frame_b := physics.Transform{{-0.5, 0, 0}, {0, 0, 0, 1}}
	physics.joint_set_local_frame_a(world, weld, frame_a)
	physics.joint_set_local_frame_b(world, untyped, frame_b)
	testing.expect_value(t, physics.joint_local_frame_a(world, untyped), frame_a)
	testing.expect_value(t, physics.joint_local_frame_b(world, weld), frame_b)
	physics.joint_set_local_frame_a(world, weld, physics.Transform{{0, 0, 0}, {0, 0, 0, 1}})
	physics.joint_set_local_frame_b(world, weld, def.base.local_frame_b)

	physics.joint_set_collide_connected(world, weld, true)
	testing.expect(t, physics.joint_collide_connected(world, weld))
	physics.joint_set_collide_connected(world, untyped, false)
	testing.expect(t, !physics.joint_collide_connected(world, untyped))

	physics.joint_set_constraint_tuning(world, weld, 30, 2)
	hertz, damping_ratio := physics.joint_constraint_tuning(world, weld)
	testing.expect_value(t, hertz, 30)
	testing.expect_value(t, damping_ratio, 2)
	physics.joint_set_force_threshold(world, weld, 12.5)
	testing.expect_value(t, physics.joint_force_threshold(world, weld), 12.5)
	physics.joint_set_torque_threshold(world, untyped, 7.25)
	testing.expect_value(t, physics.joint_torque_threshold(world, untyped), 7.25)

	joint_steps(world, 16)
	weight := physics.body_mass(world, body_b) * 10
	force := joint_length(physics.joint_constraint_force(world, weld))
	torque := joint_length(physics.joint_constraint_torque(world, weld))
	testing.expectf(t, abs(force - weight) < 0.2 * weight, "force %v, weight %v", force, weight)
	testing.expectf(t, abs(torque - weight) < 0.2 * weight, "torque %v, weight·1 m %v", torque, weight)
	linear := physics.joint_linear_separation(world, weld)
	angular := physics.joint_angular_separation(world, weld)
	testing.expectf(t, linear >= 0 && linear < 0.05, "linear separation %v", linear)
	testing.expectf(t, angular >= 0 && angular < 0.05, "angular separation %v", angular)

	// Held still, B falls asleep; waking the joint wakes it.
	testing.expect(t, physics.joint_is_awake(world, weld))
	joint_steps(world, 128)
	testing.expect(t, !physics.joint_is_awake(world, weld))
	physics.joint_wake_bodies(world, untyped)
	testing.expect(t, physics.joint_is_awake(world, untyped))
}

@(test)
joint_distance_procs :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	body_a, body_b := joint_pair(world, {0, 5, 0})
	def := physics.default_distance_joint_def()
	def.length = 1
	joint := physics.create_distance_joint(world, physics.link(body_a), physics.link(body_b), &def)
	physics.distance_joint_set_length(world, joint, 1.5)
	testing.expect_value(t, physics.distance_joint_length(world, joint), 1.5)
	physics.distance_joint_enable_spring(world, joint, false)
	testing.expect(t, !physics.distance_joint_is_spring_enabled(world, joint))
	physics.distance_joint_enable_spring(world, joint, true)
	testing.expect(t, physics.distance_joint_is_spring_enabled(world, joint))
	physics.distance_joint_set_spring_force_range(world, joint, -10, 20)
	lower_force, upper_force := physics.distance_joint_spring_force_range(world, joint)
	testing.expect_value(t, lower_force, -10)
	testing.expect_value(t, upper_force, 20)
	physics.distance_joint_set_spring_hertz(world, joint, 4)
	testing.expect_value(t, physics.distance_joint_spring_hertz(world, joint), 4)
	physics.distance_joint_set_spring_damping_ratio(world, joint, 0.5)
	testing.expect_value(t, physics.distance_joint_spring_damping_ratio(world, joint), 0.5)
	physics.distance_joint_enable_limit(world, joint, false)
	testing.expect(t, !physics.distance_joint_is_limit_enabled(world, joint))
	physics.distance_joint_enable_limit(world, joint, true)
	testing.expect(t, physics.distance_joint_is_limit_enabled(world, joint))
	physics.distance_joint_set_length_range(world, joint, 0.5, 2)
	testing.expect_value(t, physics.distance_joint_min_length(world, joint), 0.5)
	testing.expect_value(t, physics.distance_joint_max_length(world, joint), 2)
	physics.distance_joint_enable_motor(world, joint, false)
	testing.expect(t, !physics.distance_joint_is_motor_enabled(world, joint))
	physics.distance_joint_enable_motor(world, joint, true)
	testing.expect(t, physics.distance_joint_is_motor_enabled(world, joint))
	physics.distance_joint_set_motor_speed(world, joint, 0.25)
	testing.expect_value(t, physics.distance_joint_motor_speed(world, joint), 0.25)
	physics.distance_joint_set_max_motor_force(world, joint, 30)
	testing.expect_value(t, physics.distance_joint_max_motor_force(world, joint), 30)
	joint_steps(world, 4)
	between := physics.body_position(world, body_b) - physics.body_position(world, body_a)
	current := physics.distance_joint_current_length(world, joint)
	testing.expectf(t, abs(current - joint_length(between)) < 1e-3, "current %v, between %v", current, between)
	motor_force := physics.distance_joint_motor_force(world, joint)
	testing.expectf(t, joint_finite(motor_force) && abs(motor_force) <= 30.01, "motor force %v", motor_force)
}

@(test)
joint_motor_procs :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	body_a, body_b := joint_pair(world, {})
	def := physics.default_motor_joint_def()
	joint := physics.create_motor_joint(world, physics.link(body_a), physics.link(body_b), &def)
	physics.motor_joint_set_linear_velocity(world, joint, {1, 0, 0})
	testing.expect_value(t, physics.motor_joint_linear_velocity(world, joint), [3]f32{1, 0, 0})
	physics.motor_joint_set_angular_velocity(world, joint, {0, 1, 0})
	testing.expect_value(t, physics.motor_joint_angular_velocity(world, joint), [3]f32{0, 1, 0})
	physics.motor_joint_set_max_velocity_force(world, joint, 50)
	testing.expect_value(t, physics.motor_joint_max_velocity_force(world, joint), 50)
	physics.motor_joint_set_max_velocity_torque(world, joint, 20)
	testing.expect_value(t, physics.motor_joint_max_velocity_torque(world, joint), 20)
	physics.motor_joint_set_linear_hertz(world, joint, 3)
	testing.expect_value(t, physics.motor_joint_linear_hertz(world, joint), 3)
	physics.motor_joint_set_linear_damping_ratio(world, joint, 0.7)
	testing.expect_value(t, physics.motor_joint_linear_damping_ratio(world, joint), 0.7)
	physics.motor_joint_set_angular_hertz(world, joint, 2)
	testing.expect_value(t, physics.motor_joint_angular_hertz(world, joint), 2)
	physics.motor_joint_set_angular_damping_ratio(world, joint, 0.6)
	testing.expect_value(t, physics.motor_joint_angular_damping_ratio(world, joint), 0.6)
	physics.motor_joint_set_max_spring_force(world, joint, 100)
	testing.expect_value(t, physics.motor_joint_max_spring_force(world, joint), 100)
	physics.motor_joint_set_max_spring_torque(world, joint, 40)
	testing.expect_value(t, physics.motor_joint_max_spring_torque(world, joint), 40)
}

@(test)
joint_mover_procs :: proc(t: ^testing.T) {
	world := physics.create({anchor = true})
	defer physics.destroy(world)
	body := joint_body(world, {0, 1, 0})
	def := physics.default_mover_joint_def()
	joint := physics.create_mover_joint(world, physics.world_anchor(world), physics.link(body), &def)
	physics.mover_joint_set_linear_velocity(world, joint, {0, 0, 2})
	testing.expect_value(t, physics.mover_joint_linear_velocity(world, joint), [3]f32{0, 0, 2})
	physics.mover_joint_set_max_velocity_force(world, joint, 75)
	testing.expect_value(t, physics.mover_joint_max_velocity_force(world, joint), 75)
}

@(test)
joint_parallel_procs :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	body_a, body_b := joint_pair(world, {})
	def := physics.default_parallel_joint_def()
	joint := physics.create_parallel_joint(world, physics.link(body_a), physics.link(body_b), &def)
	physics.parallel_joint_set_spring_hertz(world, joint, 2)
	testing.expect_value(t, physics.parallel_joint_spring_hertz(world, joint), 2)
	physics.parallel_joint_set_spring_damping_ratio(world, joint, 0.5)
	testing.expect_value(t, physics.parallel_joint_spring_damping_ratio(world, joint), 0.5)
	physics.parallel_joint_set_max_torque(world, joint, 12)
	testing.expect_value(t, physics.parallel_joint_max_torque(world, joint), 12)
}

@(test)
joint_pogo_procs :: proc(t: ^testing.T) {
	world := physics.create({anchor = true})
	defer physics.destroy(world)
	body := joint_body(world, {0, 1, 0})
	def := physics.default_pogo_joint_def()
	def.rest_length = 1
	def.max_compression_force = 1000
	joint := physics.create_pogo_joint(world, physics.world_anchor(world), physics.link(body), &def)
	physics.pogo_joint_set_rest_length(world, joint, 0.8)
	testing.expect_value(t, physics.pogo_joint_rest_length(world, joint), 0.8)
	physics.pogo_joint_set_spring_hertz(world, joint, 3)
	testing.expect_value(t, physics.pogo_joint_spring_hertz(world, joint), 3)
	physics.pogo_joint_set_spring_damping_ratio(world, joint, 0.4)
	testing.expect_value(t, physics.pogo_joint_spring_damping_ratio(world, joint), 0.4)
	physics.pogo_joint_set_max_tension_force(world, joint, 10)
	testing.expect_value(t, physics.pogo_joint_max_tension_force(world, joint), 10)
	physics.pogo_joint_set_max_compression_force(world, joint, 200)
	testing.expect_value(t, physics.pogo_joint_max_compression_force(world, joint), 200)
	physics.pogo_joint_set_normal(world, joint, {0, 1, 0})
	testing.expect_value(t, physics.pogo_joint_normal(world, joint), [3]f32{0, 1, 0})
	joint_steps(world, 4)
	testing.expect(t, joint_finite(physics.pogo_joint_current_length(world, joint)))
	testing.expect(t, joint_finite(physics.pogo_joint_current_speed(world, joint)))
	testing.expect(t, joint_finite(physics.pogo_joint_impulse(world, joint)))
}

@(test)
joint_prismatic_procs :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	body_a, body_b := joint_pair(world, {0, 5, 0})
	def := physics.default_prismatic_joint_def()
	def.base.local_frame_a = JOINT_FRAME_AT_B
	joint := physics.create_prismatic_joint(world, physics.link(body_a), physics.link(body_b), &def)
	physics.prismatic_joint_enable_spring(world, joint, false)
	testing.expect(t, !physics.prismatic_joint_is_spring_enabled(world, joint))
	physics.prismatic_joint_enable_spring(world, joint, true)
	testing.expect(t, physics.prismatic_joint_is_spring_enabled(world, joint))
	physics.prismatic_joint_set_spring_hertz(world, joint, 2)
	testing.expect_value(t, physics.prismatic_joint_spring_hertz(world, joint), 2)
	physics.prismatic_joint_set_spring_damping_ratio(world, joint, 0.3)
	testing.expect_value(t, physics.prismatic_joint_spring_damping_ratio(world, joint), 0.3)
	physics.prismatic_joint_set_target_translation(world, joint, 0.2)
	testing.expect_value(t, physics.prismatic_joint_target_translation(world, joint), 0.2)
	physics.prismatic_joint_enable_limit(world, joint, false)
	testing.expect(t, !physics.prismatic_joint_is_limit_enabled(world, joint))
	physics.prismatic_joint_enable_limit(world, joint, true)
	testing.expect(t, physics.prismatic_joint_is_limit_enabled(world, joint))
	physics.prismatic_joint_set_limits(world, joint, -0.5, 0.5)
	testing.expect_value(t, physics.prismatic_joint_lower_limit(world, joint), -0.5)
	testing.expect_value(t, physics.prismatic_joint_upper_limit(world, joint), 0.5)
	physics.prismatic_joint_enable_motor(world, joint, false)
	testing.expect(t, !physics.prismatic_joint_is_motor_enabled(world, joint))
	physics.prismatic_joint_enable_motor(world, joint, true)
	testing.expect(t, physics.prismatic_joint_is_motor_enabled(world, joint))
	physics.prismatic_joint_set_motor_speed(world, joint, 0.1)
	testing.expect_value(t, physics.prismatic_joint_motor_speed(world, joint), 0.1)
	physics.prismatic_joint_set_max_motor_force(world, joint, 25)
	testing.expect_value(t, physics.prismatic_joint_max_motor_force(world, joint), 25)
	joint_steps(world, 8)
	translation := physics.prismatic_joint_translation(world, joint)
	testing.expectf(t, translation > 0 && translation <= 0.51, "translation %v", translation)
	testing.expect(t, joint_finite(physics.prismatic_joint_speed(world, joint)))
	motor_force := physics.prismatic_joint_motor_force(world, joint)
	testing.expectf(t, joint_finite(motor_force) && abs(motor_force) <= 25.01, "motor force %v", motor_force)
}

@(test)
joint_revolute_procs :: proc(t: ^testing.T) {
	world := physics.create({gravity = [3]f32{}})
	defer physics.destroy(world)
	body_a, body_b := joint_pair(world, {})
	def := physics.default_revolute_joint_def()
	def.base.local_frame_a = JOINT_FRAME_AT_B
	joint := physics.create_revolute_joint(world, physics.link(body_a), physics.link(body_b), &def)
	physics.revolute_joint_enable_spring(world, joint, true)
	testing.expect(t, physics.revolute_joint_is_spring_enabled(world, joint))
	physics.revolute_joint_enable_spring(world, joint, false)
	testing.expect(t, !physics.revolute_joint_is_spring_enabled(world, joint))
	physics.revolute_joint_set_spring_hertz(world, joint, 2)
	testing.expect_value(t, physics.revolute_joint_spring_hertz(world, joint), 2)
	physics.revolute_joint_set_spring_damping_ratio(world, joint, 0.3)
	testing.expect_value(t, physics.revolute_joint_spring_damping_ratio(world, joint), 0.3)
	physics.revolute_joint_set_target_angle(world, joint, 0.3)
	testing.expect_value(t, physics.revolute_joint_target_angle(world, joint), 0.3)
	physics.revolute_joint_enable_limit(world, joint, false)
	testing.expect(t, !physics.revolute_joint_is_limit_enabled(world, joint))
	physics.revolute_joint_enable_limit(world, joint, true)
	testing.expect(t, physics.revolute_joint_is_limit_enabled(world, joint))
	physics.revolute_joint_set_limits(world, joint, -0.5, 0.5)
	testing.expect_value(t, physics.revolute_joint_lower_limit(world, joint), -0.5)
	testing.expect_value(t, physics.revolute_joint_upper_limit(world, joint), 0.5)
	physics.revolute_joint_enable_motor(world, joint, false)
	testing.expect(t, !physics.revolute_joint_is_motor_enabled(world, joint))
	physics.revolute_joint_enable_motor(world, joint, true)
	testing.expect(t, physics.revolute_joint_is_motor_enabled(world, joint))
	physics.revolute_joint_set_motor_speed(world, joint, 1)
	testing.expect_value(t, physics.revolute_joint_motor_speed(world, joint), 1)
	physics.revolute_joint_set_max_motor_torque(world, joint, 5)
	testing.expect_value(t, physics.revolute_joint_max_motor_torque(world, joint), 5)
	// The motor turns B about the hinge (z) at 1 rad/s, up to the limit.
	joint_steps(world, 16)
	angle := physics.revolute_joint_angle(world, joint)
	testing.expectf(t, angle > 0.1 && angle <= 0.51, "angle %v", angle)
	motor_torque := physics.revolute_joint_motor_torque(world, joint)
	testing.expectf(t, joint_finite(motor_torque) && abs(motor_torque) <= 5.01, "motor torque %v", motor_torque)
}

@(test)
joint_spherical_procs :: proc(t: ^testing.T) {
	world := physics.create({gravity = [3]f32{}})
	defer physics.destroy(world)
	body_a, body_b := joint_pair(world, {})
	def := physics.default_spherical_joint_def()
	def.base.local_frame_a = JOINT_FRAME_AT_B
	joint := physics.create_spherical_joint(world, physics.link(body_a), physics.link(body_b), &def)
	physics.spherical_joint_enable_cone_limit(world, joint, false)
	testing.expect(t, !physics.spherical_joint_is_cone_limit_enabled(world, joint))
	physics.spherical_joint_enable_cone_limit(world, joint, true)
	testing.expect(t, physics.spherical_joint_is_cone_limit_enabled(world, joint))
	physics.spherical_joint_set_cone_limit(world, joint, 0.7)
	testing.expect_value(t, physics.spherical_joint_cone_limit(world, joint), 0.7)
	physics.spherical_joint_enable_twist_limit(world, joint, false)
	testing.expect(t, !physics.spherical_joint_is_twist_limit_enabled(world, joint))
	physics.spherical_joint_enable_twist_limit(world, joint, true)
	testing.expect(t, physics.spherical_joint_is_twist_limit_enabled(world, joint))
	physics.spherical_joint_set_twist_limits(world, joint, -0.4, 0.4)
	testing.expect_value(t, physics.spherical_joint_lower_twist_limit(world, joint), -0.4)
	testing.expect_value(t, physics.spherical_joint_upper_twist_limit(world, joint), 0.4)
	physics.spherical_joint_enable_spring(world, joint, true)
	testing.expect(t, physics.spherical_joint_is_spring_enabled(world, joint))
	physics.spherical_joint_enable_spring(world, joint, false)
	testing.expect(t, !physics.spherical_joint_is_spring_enabled(world, joint))
	physics.spherical_joint_set_spring_hertz(world, joint, 3)
	testing.expect_value(t, physics.spherical_joint_spring_hertz(world, joint), 3)
	physics.spherical_joint_set_spring_damping_ratio(world, joint, 0.6)
	testing.expect_value(t, physics.spherical_joint_spring_damping_ratio(world, joint), 0.6)
	target := [4]f32{0, 0.6, 0, 0.8}
	physics.spherical_joint_set_target_rotation(world, joint, target)
	testing.expect_value(t, physics.spherical_joint_target_rotation(world, joint), target)
	physics.spherical_joint_enable_motor(world, joint, false)
	testing.expect(t, !physics.spherical_joint_is_motor_enabled(world, joint))
	physics.spherical_joint_enable_motor(world, joint, true)
	testing.expect(t, physics.spherical_joint_is_motor_enabled(world, joint))
	physics.spherical_joint_set_motor_velocity(world, joint, {0, 0, 1})
	testing.expect_value(t, physics.spherical_joint_motor_velocity(world, joint), [3]f32{0, 0, 1})
	physics.spherical_joint_set_max_motor_torque(world, joint, 3)
	testing.expect_value(t, physics.spherical_joint_max_motor_torque(world, joint), 3)
	// The motor turns B about z, the cone's axis: a twist, up to the twist limit.
	joint_steps(world, 16)
	cone_angle := physics.spherical_joint_cone_angle(world, joint)
	twist_angle := physics.spherical_joint_twist_angle(world, joint)
	testing.expectf(t, joint_finite(cone_angle) && cone_angle >= 0 && cone_angle <= 0.71, "cone %v", cone_angle)
	testing.expectf(t, abs(twist_angle) > 0.1 && abs(twist_angle) <= 0.41, "twist %v", twist_angle)
	motor_torque := physics.spherical_joint_motor_torque(world, joint)
	testing.expectf(
		t,
		joint_finite(motor_torque.x) && joint_finite(motor_torque.y) && joint_finite(motor_torque.z),
		"motor torque %v",
		motor_torque,
	)
}

@(test)
joint_weld_procs :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	body_a, body_b := joint_pair(world, {})
	def := physics.default_weld_joint_def()
	joint := physics.create_weld_joint(world, physics.link(body_a), physics.link(body_b), &def)
	physics.weld_joint_set_linear_hertz(world, joint, 5)
	testing.expect_value(t, physics.weld_joint_linear_hertz(world, joint), 5)
	physics.weld_joint_set_linear_damping_ratio(world, joint, 0.7)
	testing.expect_value(t, physics.weld_joint_linear_damping_ratio(world, joint), 0.7)
	physics.weld_joint_set_angular_hertz(world, joint, 6)
	testing.expect_value(t, physics.weld_joint_angular_hertz(world, joint), 6)
	physics.weld_joint_set_angular_damping_ratio(world, joint, 0.8)
	testing.expect_value(t, physics.weld_joint_angular_damping_ratio(world, joint), 0.8)
}

@(test)
joint_wheel_procs :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	body_a, body_b := joint_pair(world, {0, 5, 0})
	def := physics.default_wheel_joint_def()
	def.base.local_frame_a = JOINT_FRAME_AT_B
	joint := physics.create_wheel_joint(world, physics.link(body_a), physics.link(body_b), &def)
	physics.wheel_joint_enable_suspension(world, joint, false)
	testing.expect(t, !physics.wheel_joint_is_suspension_enabled(world, joint))
	physics.wheel_joint_enable_suspension(world, joint, true)
	testing.expect(t, physics.wheel_joint_is_suspension_enabled(world, joint))
	physics.wheel_joint_set_suspension_hertz(world, joint, 5)
	testing.expect_value(t, physics.wheel_joint_suspension_hertz(world, joint), 5)
	physics.wheel_joint_set_suspension_damping_ratio(world, joint, 0.7)
	testing.expect_value(t, physics.wheel_joint_suspension_damping_ratio(world, joint), 0.7)
	physics.wheel_joint_enable_suspension_limit(world, joint, false)
	testing.expect(t, !physics.wheel_joint_is_suspension_limit_enabled(world, joint))
	physics.wheel_joint_enable_suspension_limit(world, joint, true)
	testing.expect(t, physics.wheel_joint_is_suspension_limit_enabled(world, joint))
	physics.wheel_joint_set_suspension_limits(world, joint, -0.2, 0.3)
	testing.expect_value(t, physics.wheel_joint_lower_suspension_limit(world, joint), -0.2)
	testing.expect_value(t, physics.wheel_joint_upper_suspension_limit(world, joint), 0.3)
	physics.wheel_joint_enable_spin_motor(world, joint, false)
	testing.expect(t, !physics.wheel_joint_is_spin_motor_enabled(world, joint))
	physics.wheel_joint_enable_spin_motor(world, joint, true)
	testing.expect(t, physics.wheel_joint_is_spin_motor_enabled(world, joint))
	physics.wheel_joint_set_spin_motor_speed(world, joint, 2)
	testing.expect_value(t, physics.wheel_joint_spin_motor_speed(world, joint), 2)
	physics.wheel_joint_set_max_spin_torque(world, joint, 10)
	testing.expect_value(t, physics.wheel_joint_max_spin_torque(world, joint), 10)
	physics.wheel_joint_enable_steering(world, joint, false)
	testing.expect(t, !physics.wheel_joint_is_steering_enabled(world, joint))
	physics.wheel_joint_enable_steering(world, joint, true)
	testing.expect(t, physics.wheel_joint_is_steering_enabled(world, joint))
	physics.wheel_joint_set_steering_hertz(world, joint, 4)
	testing.expect_value(t, physics.wheel_joint_steering_hertz(world, joint), 4)
	physics.wheel_joint_set_steering_damping_ratio(world, joint, 0.9)
	testing.expect_value(t, physics.wheel_joint_steering_damping_ratio(world, joint), 0.9)
	physics.wheel_joint_set_max_steering_torque(world, joint, 15)
	testing.expect_value(t, physics.wheel_joint_max_steering_torque(world, joint), 15)
	physics.wheel_joint_enable_steering_limit(world, joint, false)
	testing.expect(t, !physics.wheel_joint_is_steering_limit_enabled(world, joint))
	physics.wheel_joint_enable_steering_limit(world, joint, true)
	testing.expect(t, physics.wheel_joint_is_steering_limit_enabled(world, joint))
	physics.wheel_joint_set_steering_limits(world, joint, -0.6, 0.6)
	testing.expect_value(t, physics.wheel_joint_lower_steering_limit(world, joint), -0.6)
	testing.expect_value(t, physics.wheel_joint_upper_steering_limit(world, joint), 0.6)
	physics.wheel_joint_set_target_steering_angle(world, joint, 0.2)
	testing.expect_value(t, physics.wheel_joint_target_steering_angle(world, joint), 0.2)
	// The spin motor spins the wheel up; the steering spring turns it towards its target.
	joint_steps(world, 16)
	spin_speed := physics.wheel_joint_spin_speed(world, joint)
	testing.expectf(t, spin_speed > 0 && spin_speed <= 2.01, "spin speed %v", spin_speed)
	spin_torque := physics.wheel_joint_spin_torque(world, joint)
	testing.expectf(t, joint_finite(spin_torque) && abs(spin_torque) <= 10.01, "spin torque %v", spin_torque)
	steering_angle := physics.wheel_joint_steering_angle(world, joint)
	testing.expectf(t, steering_angle > 0 && steering_angle <= 0.61, "steering angle %v", steering_angle)
	steering_torque := physics.wheel_joint_steering_torque(world, joint)
	testing.expectf(
		t,
		joint_finite(steering_torque) && abs(steering_torque) <= 15.01,
		"steering torque %v",
		steering_torque,
	)
}

// A block with joints, as a game keeps them.
Joint_Block :: struct {
	base:  physics.Body_Ref,
	arm:   physics.Body_Ref,
	bob:   physics.Body_Ref,
	hinge: physics.Revolute_Joint_Ref,
	rope:  physics.Distance_Joint_Ref,
}

// Joints are part of the snapshot: one destroyed (its index then reused by a new joint) and one changed after a
// save are back, alive and with their settings, after the restore, and the new joint is gone.
@(test)
joint_save_restore :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	block: Joint_Block
	extra := physics.extra(world, Joint_Block)
	block.base = joint_body(world, {0, 5, 0}, .Static_Body)
	block.arm = joint_body(world, {1, 5, 0})
	block.bob = joint_body(world, {0, 3.5, 0})
	hinge_def := physics.default_revolute_joint_def()
	hinge_def.base.local_frame_a = JOINT_FRAME_AT_B
	hinge_def.enable_motor = true
	hinge_def.max_motor_torque = 100
	hinge_def.motor_speed = 2
	block.hinge = physics.create_revolute_joint(world, physics.link(block.base), physics.link(block.arm), &hinge_def)
	rope_def := physics.default_distance_joint_def()
	rope_def.length = 1.5
	block.rope = physics.create_distance_joint(world, physics.link(block.base), physics.link(block.bob), &rope_def)
	joint_steps(world, 4)
	testing.expect_value(t, extra.check(extra.data, &block), "")
	extra.save(extra.data, 0)
	saved := block
	arm_at_save := physics.body_position(world, block.arm)

	stale_rope := block.rope
	physics.destroy_joint(world, &block.rope)
	weld_def := physics.default_weld_joint_def()
	weld := physics.create_weld_joint(world, physics.link(block.arm), physics.link(block.bob), &weld_def)
	testing.expect_value(t, weld.index1, stale_rope.index1) // Box3D reused the index
	testing.expect(t, !physics.joint_valid(world, stale_rope))
	physics.revolute_joint_set_motor_speed(world, block.hinge, -5)
	joint_steps(world, 8)

	testing.expect(t, extra.restore(extra.data, 0))
	block = saved
	testing.expect_value(t, extra.check(extra.data, &block), "")
	testing.expect(t, physics.joint_valid(world, block.rope))
	testing.expect(t, !physics.joint_valid(world, weld))
	testing.expect_value(t, physics.joint_type(world, block.rope), physics.Joint_Type.Distance_Joint)
	testing.expect_value(t, physics.distance_joint_length(world, block.rope), 1.5)
	testing.expect_value(t, physics.joint_body_b(world, block.rope), physics.link(block.bob))
	testing.expect_value(t, physics.revolute_joint_motor_speed(world, block.hinge), 2)
	testing.expect(t, physics.revolute_joint_is_motor_enabled(world, block.hinge))
	testing.expect_value(t, physics.body_position(world, block.arm), arm_at_save)
}
