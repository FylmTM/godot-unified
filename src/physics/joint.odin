// Joints (src/physics/SPEC.md, What physics covers): every Box3D joint proc on a joint ref, named by its names without
// `get_`. The generic joint_* procs take any joint ref; a per-type proc takes its typed ref, so a setter of another
// type does not compile. Creation takes the two bodies as links and fills the def's body ids itself.
package physics

import "base:intrinsics"
import "base:runtime"

import "unified:b3"

Joint_Type :: b3.Joint_Type
Distance_Joint_Def :: b3.Distance_Joint_Def
Filter_Joint_Def :: b3.Filter_Joint_Def
Parallel_Joint_Def :: b3.Parallel_Joint_Def
Prismatic_Joint_Def :: b3.Prismatic_Joint_Def
Revolute_Joint_Def :: b3.Revolute_Joint_Def
Spherical_Joint_Def :: b3.Spherical_Joint_Def
Weld_Joint_Def :: b3.Weld_Joint_Def
Wheel_Joint_Def :: b3.Wheel_Joint_Def

default_distance_joint_def :: b3.default_distance_joint_def
default_filter_joint_def :: b3.default_filter_joint_def
default_parallel_joint_def :: b3.default_parallel_joint_def
default_prismatic_joint_def :: b3.default_prismatic_joint_def
default_revolute_joint_def :: b3.default_revolute_joint_def
default_spherical_joint_def :: b3.default_spherical_joint_def
default_weld_joint_def :: b3.default_weld_joint_def
default_wheel_joint_def :: b3.default_wheel_joint_def

// The World's anchor body (Settings.anchor), for joints that hold a body to the world. Zero when there is none.
world_anchor :: proc(world: ^World) -> Body_Link {
	return link_of(world.anchor)
}

// ---- creation: the def's body ids come from the links (both must name live bodies); its user_data stays unset

// Creates a distance joint between two bodies.
create_distance_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Distance_Joint_Def,
	loc := #caller_location,
) -> Distance_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_distance_joint(world.id, def))}
}

// Creates a filter joint between two bodies (it only stops them colliding).
create_filter_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Filter_Joint_Def,
	loc := #caller_location,
) -> Filter_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_filter_joint(world.id, def))}
}

// Creates a motor joint between two bodies.
create_motor_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Motor_Joint_Def,
	loc := #caller_location,
) -> Motor_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_motor_joint(world.id, def))}
}

// Creates a mover joint between two bodies.
create_mover_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Mover_Joint_Def,
	loc := #caller_location,
) -> Mover_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_mover_joint(world.id, def))}
}

// Creates a parallel joint between two bodies.
create_parallel_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Parallel_Joint_Def,
	loc := #caller_location,
) -> Parallel_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_parallel_joint(world.id, def))}
}

// Creates a pogo joint between two bodies.
create_pogo_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Pogo_Joint_Def,
	loc := #caller_location,
) -> Pogo_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_pogo_joint(world.id, def))}
}

// Creates a prismatic joint between two bodies.
create_prismatic_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Prismatic_Joint_Def,
	loc := #caller_location,
) -> Prismatic_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_prismatic_joint(world.id, def))}
}

// Creates a revolute joint between two bodies.
create_revolute_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Revolute_Joint_Def,
	loc := #caller_location,
) -> Revolute_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_revolute_joint(world.id, def))}
}

// Creates a spherical joint between two bodies.
create_spherical_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Spherical_Joint_Def,
	loc := #caller_location,
) -> Spherical_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_spherical_joint(world.id, def))}
}

// Creates a weld joint between two bodies.
create_weld_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Weld_Joint_Def,
	loc := #caller_location,
) -> Weld_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_weld_joint(world.id, def))}
}

// Creates a wheel joint between two bodies.
create_wheel_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: ^Wheel_Joint_Def,
	loc := #caller_location,
) -> Wheel_Joint_Ref {
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(b3.create_wheel_joint(world.id, def))}
}

@(private)
set_joint_bodies :: proc(
	world: ^World,
	def: ^Joint_Def,
	body_a, body_b: Body_Link,
	loc: runtime.Source_Code_Location,
) {
	assert(body_valid(world, body_a) && body_valid(world, body_b), "physics: a joint's bodies must be alive", loc)
	assert(def.user_data == nil, "physics: a joint def's user_data stays unset", loc)
	def.body_id_a = link_id(world, body_a)
	def.body_id_b = link_id(world, body_b)
}

// ---- conversion

// The typed ref of an untyped joint (body_joints' results): not ok when the joint is gone or of another type.
joint_as :: proc(
	world: ^World,
	joint: Joint_Ref,
	$J: typeid,
) -> (
	J,
	bool,
) where intrinsics.type_is_subtype_of(J, Joint_Ref) {
	if !joint_valid(world, joint) || b3.joint_get_type(joint_id(world, joint)) != joint_type_of(J) do return {}, false
	return J{joint = joint}, true
}

// The Box3D joint type a typed joint ref stands for.
@(private)
joint_type_of :: proc "contextless" ($J: typeid) -> Joint_Type {
	when J == Distance_Joint_Ref {
		return .Distance_Joint
	} else when J == Filter_Joint_Ref {
		return .Filter_Joint
	} else when J == Motor_Joint_Ref {
		return .Motor_Joint
	} else when J == Mover_Joint_Ref {
		return .Mover_Joint
	} else when J == Parallel_Joint_Ref {
		return .Parallel_Joint
	} else when J == Pogo_Joint_Ref {
		return .Pogo_Joint
	} else when J == Prismatic_Joint_Ref {
		return .Prismatic_Joint
	} else when J == Revolute_Joint_Ref {
		return .Revolute_Joint
	} else when J == Spherical_Joint_Ref {
		return .Spherical_Joint
	} else when J == Weld_Joint_Ref {
		return .Weld_Joint
	} else when J == Wheel_Joint_Ref {
		return .Wheel_Joint
	} else {
		#panic("physics: not a typed joint ref")
	}
}

// ---- on any joint ref

// The joint's type.
joint_type :: proc(
	world: ^World,
	joint: $J,
) -> Joint_Type where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_type(joint_id(world, joint))
}

// The joint's first body.
joint_body_a :: proc(
	world: ^World,
	joint: $J,
) -> Body_Link where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return link_of(b3.joint_get_body_a(joint_id(world, joint)))
}

// The joint's second body.
joint_body_b :: proc(
	world: ^World,
	joint: $J,
) -> Body_Link where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return link_of(b3.joint_get_body_b(joint_id(world, joint)))
}

// Moves the joint's frame on body A (in A's frame).
joint_set_local_frame_a :: proc(
	world: ^World,
	joint: $J,
	local_frame: Transform,
) where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	b3.joint_set_local_frame_a(joint_id(world, joint), local_frame)
}

// The joint's frame on body A (in A's frame).
joint_local_frame_a :: proc(
	world: ^World,
	joint: $J,
) -> Transform where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_local_frame_a(joint_id(world, joint))
}

// Moves the joint's frame on body B (in B's frame).
joint_set_local_frame_b :: proc(
	world: ^World,
	joint: $J,
	local_frame: Transform,
) where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	b3.joint_set_local_frame_b(joint_id(world, joint), local_frame)
}

// The joint's frame on body B (in B's frame).
joint_local_frame_b :: proc(
	world: ^World,
	joint: $J,
) -> Transform where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_local_frame_b(joint_id(world, joint))
}

// Sets whether the joint's two bodies collide with each other.
joint_set_collide_connected :: proc(
	world: ^World,
	joint: $J,
	should_collide: bool,
) where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	b3.joint_set_collide_connected(joint_id(world, joint), should_collide)
}

// Whether the joint's two bodies collide with each other.
joint_collide_connected :: proc(
	world: ^World,
	joint: $J,
) -> bool where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_collide_connected(joint_id(world, joint))
}

// Wakes the joint's bodies.
joint_wake_bodies :: proc(
	world: ^World,
	joint: $J,
) where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	b3.joint_wake_bodies(joint_id(world, joint))
}

// Whether the joint is awake (an attached body is awake).
joint_is_awake :: proc(
	world: ^World,
	joint: $J,
) -> bool where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_is_awake(joint_id(world, joint))
}

// The current constraint force for this joint.
joint_constraint_force :: proc(
	world: ^World,
	joint: $J,
) -> [3]f32 where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_constraint_force(joint_id(world, joint))
}

// The current constraint torque for this joint.
joint_constraint_torque :: proc(
	world: ^World,
	joint: $J,
) -> [3]f32 where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_constraint_torque(joint_id(world, joint))
}

// The joint's current linear error (m), not counting the movement it allows.
joint_linear_separation :: proc(
	world: ^World,
	joint: $J,
) -> f32 where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_linear_separation(joint_id(world, joint))
}

// The joint's current angular error (radians), not counting the movement it allows.
joint_angular_separation :: proc(
	world: ^World,
	joint: $J,
) -> f32 where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_angular_separation(joint_id(world, joint))
}

// Sets the joint's constraint stiffness (Hz) and damping ratio (1: critical). Advanced.
joint_set_constraint_tuning :: proc(
	world: ^World,
	joint: $J,
	hertz: f32,
	damping_ratio: f32,
) where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	b3.joint_set_constraint_tuning(joint_id(world, joint), hertz, damping_ratio)
}

// The joint's constraint stiffness (Hz) and damping ratio. Advanced.
joint_constraint_tuning :: proc(
	world: ^World,
	joint: $J,
) -> (
	hertz: f32,
	damping_ratio: f32,
) where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_constraint_tuning(joint_id(world, joint))
}

// Sets the force (N) above which the joint reports a joint event.
joint_set_force_threshold :: proc(
	world: ^World,
	joint: $J,
	threshold: f32,
) where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	b3.joint_set_force_threshold(joint_id(world, joint), threshold)
}

// The force (N) above which the joint reports a joint event.
joint_force_threshold :: proc(
	world: ^World,
	joint: $J,
) -> f32 where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_force_threshold(joint_id(world, joint))
}

// Sets the torque (N·m) above which the joint reports a joint event.
joint_set_torque_threshold :: proc(
	world: ^World,
	joint: $J,
	threshold: f32,
) where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	b3.joint_set_torque_threshold(joint_id(world, joint), threshold)
}

// The torque (N·m) above which the joint reports a joint event.
joint_torque_threshold :: proc(
	world: ^World,
	joint: $J,
) -> f32 where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return b3.joint_get_torque_threshold(joint_id(world, joint))
}

// ---- parallel joints

// Sets the parallel joint's spring stiffness in Hertz.
parallel_joint_set_spring_hertz :: proc(world: ^World, joint: Parallel_Joint_Ref, hertz: f32) {
	b3.parallel_joint_set_spring_hertz(joint_id(world, joint), hertz)
}

// Sets the parallel joint's spring damping ratio, non-dimensional.
parallel_joint_set_spring_damping_ratio :: proc(world: ^World, joint: Parallel_Joint_Ref, damping_ratio: f32) {
	b3.parallel_joint_set_spring_damping_ratio(joint_id(world, joint), damping_ratio)
}

// The parallel joint's spring Hertz.
parallel_joint_spring_hertz :: proc(world: ^World, joint: Parallel_Joint_Ref) -> f32 {
	return b3.parallel_joint_get_spring_hertz(joint_id(world, joint))
}

// The parallel joint's spring damping ratio.
parallel_joint_spring_damping_ratio :: proc(world: ^World, joint: Parallel_Joint_Ref) -> f32 {
	return b3.parallel_joint_get_spring_damping_ratio(joint_id(world, joint))
}

// Sets the parallel joint's maximum spring torque, usually in newton-meters.
parallel_joint_set_max_torque :: proc(world: ^World, joint: Parallel_Joint_Ref, max_torque: f32) {
	b3.parallel_joint_set_max_torque(joint_id(world, joint), max_torque)
}

// The parallel joint's maximum spring torque, usually in newton-meters.
parallel_joint_max_torque :: proc(world: ^World, joint: Parallel_Joint_Ref) -> f32 {
	return b3.parallel_joint_get_max_torque(joint_id(world, joint))
}

// ---- distance joints

// Sets the rest length of a distance joint.
distance_joint_set_length :: proc(world: ^World, joint: Distance_Joint_Ref, length: f32) {
	b3.distance_joint_set_length(joint_id(world, joint), length)
}

// The rest length of a distance joint.
distance_joint_length :: proc(world: ^World, joint: Distance_Joint_Ref) -> f32 {
	return b3.distance_joint_get_length(joint_id(world, joint))
}

// Enables or disables the distance joint's spring (disabled: the joint is rigid).
distance_joint_enable_spring :: proc(world: ^World, joint: Distance_Joint_Ref, enable_spring: bool) {
	b3.distance_joint_enable_spring(joint_id(world, joint), enable_spring)
}

// Whether the distance joint's spring is enabled.
distance_joint_is_spring_enabled :: proc(world: ^World, joint: Distance_Joint_Ref) -> bool {
	return b3.distance_joint_is_spring_enabled(joint_id(world, joint))
}

// Sets the distance joint's force range for the spring.
distance_joint_set_spring_force_range :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	lower_force: f32,
	upper_force: f32,
) {
	b3.distance_joint_set_spring_force_range(joint_id(world, joint), lower_force, upper_force)
}

// The distance joint's force range for the spring.
distance_joint_spring_force_range :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
) -> (
	lower_force: f32,
	upper_force: f32,
) {
	return b3.distance_joint_get_spring_force_range(joint_id(world, joint))
}

// Sets the distance joint's spring stiffness in Hertz.
distance_joint_set_spring_hertz :: proc(world: ^World, joint: Distance_Joint_Ref, hertz: f32) {
	b3.distance_joint_set_spring_hertz(joint_id(world, joint), hertz)
}

// Sets the distance joint's spring damping ratio, non-dimensional.
distance_joint_set_spring_damping_ratio :: proc(world: ^World, joint: Distance_Joint_Ref, damping_ratio: f32) {
	b3.distance_joint_set_spring_damping_ratio(joint_id(world, joint), damping_ratio)
}

// The distance joint's spring Hertz.
distance_joint_spring_hertz :: proc(world: ^World, joint: Distance_Joint_Ref) -> f32 {
	return b3.distance_joint_get_spring_hertz(joint_id(world, joint))
}

// The distance joint's spring damping ratio.
distance_joint_spring_damping_ratio :: proc(world: ^World, joint: Distance_Joint_Ref) -> f32 {
	return b3.distance_joint_get_spring_damping_ratio(joint_id(world, joint))
}

// Enables or disables the distance joint's length limit (it acts only with the spring enabled; a rigid joint ignores it).
distance_joint_enable_limit :: proc(world: ^World, joint: Distance_Joint_Ref, enable_limit: bool) {
	b3.distance_joint_enable_limit(joint_id(world, joint), enable_limit)
}

// Whether the distance joint's limit is enabled.
distance_joint_is_limit_enabled :: proc(world: ^World, joint: Distance_Joint_Ref) -> bool {
	return b3.distance_joint_is_limit_enabled(joint_id(world, joint))
}

// Sets the minimum and maximum length parameters of a distance joint.
distance_joint_set_length_range :: proc(world: ^World, joint: Distance_Joint_Ref, min_length: f32, max_length: f32) {
	b3.distance_joint_set_length_range(joint_id(world, joint), min_length, max_length)
}

// The distance joint's minimum length.
distance_joint_min_length :: proc(world: ^World, joint: Distance_Joint_Ref) -> f32 {
	return b3.distance_joint_get_min_length(joint_id(world, joint))
}

// The distance joint's maximum length.
distance_joint_max_length :: proc(world: ^World, joint: Distance_Joint_Ref) -> f32 {
	return b3.distance_joint_get_max_length(joint_id(world, joint))
}

// The current length of a distance joint.
distance_joint_current_length :: proc(world: ^World, joint: Distance_Joint_Ref) -> f32 {
	return b3.distance_joint_get_current_length(joint_id(world, joint))
}

// Enables or disables the distance joint's motor.
distance_joint_enable_motor :: proc(world: ^World, joint: Distance_Joint_Ref, enable_motor: bool) {
	b3.distance_joint_enable_motor(joint_id(world, joint), enable_motor)
}

// Whether the distance joint's motor is enabled.
distance_joint_is_motor_enabled :: proc(world: ^World, joint: Distance_Joint_Ref) -> bool {
	return b3.distance_joint_is_motor_enabled(joint_id(world, joint))
}

// Sets the distance joint's motor speed, usually in meters per second.
distance_joint_set_motor_speed :: proc(world: ^World, joint: Distance_Joint_Ref, motor_speed: f32) {
	b3.distance_joint_set_motor_speed(joint_id(world, joint), motor_speed)
}

// The distance joint's motor speed, usually in meters per second.
distance_joint_motor_speed :: proc(world: ^World, joint: Distance_Joint_Ref) -> f32 {
	return b3.distance_joint_get_motor_speed(joint_id(world, joint))
}

// Sets the distance joint's maximum motor force, usually in newtons.
distance_joint_set_max_motor_force :: proc(world: ^World, joint: Distance_Joint_Ref, force: f32) {
	b3.distance_joint_set_max_motor_force(joint_id(world, joint), force)
}

// The distance joint's maximum motor force, usually in newtons.
distance_joint_max_motor_force :: proc(world: ^World, joint: Distance_Joint_Ref) -> f32 {
	return b3.distance_joint_get_max_motor_force(joint_id(world, joint))
}

// The distance joint's current motor force, usually in newtons.
distance_joint_motor_force :: proc(world: ^World, joint: Distance_Joint_Ref) -> f32 {
	return b3.distance_joint_get_motor_force(joint_id(world, joint))
}

// ---- motor joints

// Sets the motor joint's desired relative linear velocity in meters per second.
motor_joint_set_linear_velocity :: proc(world: ^World, joint: Motor_Joint_Ref, velocity: [3]f32) {
	b3.motor_joint_set_linear_velocity(joint_id(world, joint), velocity)
}

// The motor joint's desired relative linear velocity in meters per second.
motor_joint_linear_velocity :: proc(world: ^World, joint: Motor_Joint_Ref) -> [3]f32 {
	return b3.motor_joint_get_linear_velocity(joint_id(world, joint))
}

// Sets the motor joint's desired relative angular velocity in radians per second.
motor_joint_set_angular_velocity :: proc(world: ^World, joint: Motor_Joint_Ref, velocity: [3]f32) {
	b3.motor_joint_set_angular_velocity(joint_id(world, joint), velocity)
}

// The motor joint's desired relative angular velocity in radians per second.
motor_joint_angular_velocity :: proc(world: ^World, joint: Motor_Joint_Ref) -> [3]f32 {
	return b3.motor_joint_get_angular_velocity(joint_id(world, joint))
}

// Sets the motor joint's maximum force, usually in newtons.
motor_joint_set_max_velocity_force :: proc(world: ^World, joint: Motor_Joint_Ref, max_force: f32) {
	b3.motor_joint_set_max_velocity_force(joint_id(world, joint), max_force)
}

// The motor joint's maximum force, usually in newtons.
motor_joint_max_velocity_force :: proc(world: ^World, joint: Motor_Joint_Ref) -> f32 {
	return b3.motor_joint_get_max_velocity_force(joint_id(world, joint))
}

// Sets the motor joint's maximum torque, usually in newton-meters.
motor_joint_set_max_velocity_torque :: proc(world: ^World, joint: Motor_Joint_Ref, max_torque: f32) {
	b3.motor_joint_set_max_velocity_torque(joint_id(world, joint), max_torque)
}

// The motor joint's maximum torque, usually in newton-meters.
motor_joint_max_velocity_torque :: proc(world: ^World, joint: Motor_Joint_Ref) -> f32 {
	return b3.motor_joint_get_max_velocity_torque(joint_id(world, joint))
}

// Sets the motor joint's spring linear hertz stiffness.
motor_joint_set_linear_hertz :: proc(world: ^World, joint: Motor_Joint_Ref, hertz: f32) {
	b3.motor_joint_set_linear_hertz(joint_id(world, joint), hertz)
}

// The motor joint's spring linear hertz stiffness.
motor_joint_linear_hertz :: proc(world: ^World, joint: Motor_Joint_Ref) -> f32 {
	return b3.motor_joint_get_linear_hertz(joint_id(world, joint))
}

// Sets the motor joint's linear spring damping ratio (1: critical).
motor_joint_set_linear_damping_ratio :: proc(world: ^World, joint: Motor_Joint_Ref, damping: f32) {
	b3.motor_joint_set_linear_damping_ratio(joint_id(world, joint), damping)
}

// The motor joint's spring linear damping ratio.
motor_joint_linear_damping_ratio :: proc(world: ^World, joint: Motor_Joint_Ref) -> f32 {
	return b3.motor_joint_get_linear_damping_ratio(joint_id(world, joint))
}

// Sets the motor joint's spring angular hertz stiffness.
motor_joint_set_angular_hertz :: proc(world: ^World, joint: Motor_Joint_Ref, hertz: f32) {
	b3.motor_joint_set_angular_hertz(joint_id(world, joint), hertz)
}

// The motor joint's spring angular hertz stiffness.
motor_joint_angular_hertz :: proc(world: ^World, joint: Motor_Joint_Ref) -> f32 {
	return b3.motor_joint_get_angular_hertz(joint_id(world, joint))
}

// Sets the motor joint's angular spring damping ratio (1: critical).
motor_joint_set_angular_damping_ratio :: proc(world: ^World, joint: Motor_Joint_Ref, damping: f32) {
	b3.motor_joint_set_angular_damping_ratio(joint_id(world, joint), damping)
}

// The motor joint's spring angular damping ratio.
motor_joint_angular_damping_ratio :: proc(world: ^World, joint: Motor_Joint_Ref) -> f32 {
	return b3.motor_joint_get_angular_damping_ratio(joint_id(world, joint))
}

// Sets the motor joint's maximum spring force in newtons.
motor_joint_set_max_spring_force :: proc(world: ^World, joint: Motor_Joint_Ref, max_force: f32) {
	b3.motor_joint_set_max_spring_force(joint_id(world, joint), max_force)
}

// The motor joint's maximum spring force in newtons.
motor_joint_max_spring_force :: proc(world: ^World, joint: Motor_Joint_Ref) -> f32 {
	return b3.motor_joint_get_max_spring_force(joint_id(world, joint))
}

// Sets the motor joint's maximum spring torque in N·m.
motor_joint_set_max_spring_torque :: proc(world: ^World, joint: Motor_Joint_Ref, max_torque: f32) {
	b3.motor_joint_set_max_spring_torque(joint_id(world, joint), max_torque)
}

// The motor joint's maximum spring torque in N·m.
motor_joint_max_spring_torque :: proc(world: ^World, joint: Motor_Joint_Ref) -> f32 {
	return b3.motor_joint_get_max_spring_torque(joint_id(world, joint))
}

// ---- mover joints

// Sets the mover joint's target velocity of B relative to A, usually in meters per second.
mover_joint_set_linear_velocity :: proc(world: ^World, joint: Mover_Joint_Ref, velocity: [3]f32) {
	b3.mover_joint_set_linear_velocity(joint_id(world, joint), velocity)
}

// The mover joint's target velocity of B relative to A, usually in meters per second.
mover_joint_linear_velocity :: proc(world: ^World, joint: Mover_Joint_Ref) -> [3]f32 {
	return b3.mover_joint_get_linear_velocity(joint_id(world, joint))
}

// Sets the force cap of the mover joint's velocity drive (0: no drive), usually in newtons.
mover_joint_set_max_velocity_force :: proc(world: ^World, joint: Mover_Joint_Ref, max_force: f32) {
	b3.mover_joint_set_max_velocity_force(joint_id(world, joint), max_force)
}

// The force cap of the mover joint's velocity drive, usually in newtons.
mover_joint_max_velocity_force :: proc(world: ^World, joint: Mover_Joint_Ref) -> f32 {
	return b3.mover_joint_get_max_velocity_force(joint_id(world, joint))
}

// ---- pogo joints

// Sets the rest length of a pogo joint.
pogo_joint_set_rest_length :: proc(world: ^World, joint: Pogo_Joint_Ref, length: f32) {
	b3.pogo_joint_set_rest_length(joint_id(world, joint), length)
}

// The rest length of a pogo joint.
pogo_joint_rest_length :: proc(world: ^World, joint: Pogo_Joint_Ref) -> f32 {
	return b3.pogo_joint_get_rest_length(joint_id(world, joint))
}

// Sets the pogo spring's stiffness in Hertz.
pogo_joint_set_spring_hertz :: proc(world: ^World, joint: Pogo_Joint_Ref, hertz: f32) {
	b3.pogo_joint_set_spring_hertz(joint_id(world, joint), hertz)
}

// The pogo joint's spring Hertz.
pogo_joint_spring_hertz :: proc(world: ^World, joint: Pogo_Joint_Ref) -> f32 {
	return b3.pogo_joint_get_spring_hertz(joint_id(world, joint))
}

// Sets the pogo spring's damping ratio (1: critical).
pogo_joint_set_spring_damping_ratio :: proc(world: ^World, joint: Pogo_Joint_Ref, damping_ratio: f32) {
	b3.pogo_joint_set_spring_damping_ratio(joint_id(world, joint), damping_ratio)
}

// The pogo joint's spring damping ratio.
pogo_joint_spring_damping_ratio :: proc(world: ^World, joint: Pogo_Joint_Ref) -> f32 {
	return b3.pogo_joint_get_spring_damping_ratio(joint_id(world, joint))
}

// Sets the most force the pogo pulls with (0: it only pushes), usually in newtons.
pogo_joint_set_max_tension_force :: proc(world: ^World, joint: Pogo_Joint_Ref, force: f32) {
	b3.pogo_joint_set_max_tension_force(joint_id(world, joint), force)
}

// The most force the pogo pulls with, usually in newtons.
pogo_joint_max_tension_force :: proc(world: ^World, joint: Pogo_Joint_Ref) -> f32 {
	return b3.pogo_joint_get_max_tension_force(joint_id(world, joint))
}

// Sets the most force the pogo pushes with, usually in newtons.
pogo_joint_set_max_compression_force :: proc(world: ^World, joint: Pogo_Joint_Ref, force: f32) {
	b3.pogo_joint_set_max_compression_force(joint_id(world, joint), force)
}

// The most force the pogo pushes with, usually in newtons.
pogo_joint_max_compression_force :: proc(world: ^World, joint: Pogo_Joint_Ref) -> f32 {
	return b3.pogo_joint_get_max_compression_force(joint_id(world, joint))
}

// Sets the direction the pogo acts along (unit, world).
pogo_joint_set_normal :: proc(world: ^World, joint: Pogo_Joint_Ref, normal: [3]f32) {
	b3.pogo_joint_set_normal(joint_id(world, joint), normal)
}

// The direction the pogo acts along (unit, world).
pogo_joint_normal :: proc(world: ^World, joint: Pogo_Joint_Ref) -> [3]f32 {
	return b3.pogo_joint_get_normal(joint_id(world, joint))
}

// The pogo's current length.
pogo_joint_current_length :: proc(world: ^World, joint: Pogo_Joint_Ref) -> f32 {
	return b3.pogo_joint_get_current_length(joint_id(world, joint))
}

// The pogo's current extension speed.
pogo_joint_current_speed :: proc(world: ^World, joint: Pogo_Joint_Ref) -> f32 {
	return b3.pogo_joint_get_current_speed(joint_id(world, joint))
}

// The pogo's last impulse.
pogo_joint_impulse :: proc(world: ^World, joint: Pogo_Joint_Ref) -> f32 {
	return b3.pogo_joint_get_impulse(joint_id(world, joint))
}

// ---- prismatic joints

// Enables or disables the prismatic joint's spring.
prismatic_joint_enable_spring :: proc(world: ^World, joint: Prismatic_Joint_Ref, enable_spring: bool) {
	b3.prismatic_joint_enable_spring(joint_id(world, joint), enable_spring)
}

// Whether the prismatic joint's spring is enabled.
prismatic_joint_is_spring_enabled :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> bool {
	return b3.prismatic_joint_is_spring_enabled(joint_id(world, joint))
}

// Sets the prismatic joint's spring stiffness in Hertz (usually under a quarter of the step rate).
prismatic_joint_set_spring_hertz :: proc(world: ^World, joint: Prismatic_Joint_Ref, hertz: f32) {
	b3.prismatic_joint_set_spring_hertz(joint_id(world, joint), hertz)
}

// The prismatic joint's stiffness in Hertz.
prismatic_joint_spring_hertz :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> f32 {
	return b3.prismatic_joint_get_spring_hertz(joint_id(world, joint))
}

// Sets the prismatic joint's damping ratio (non-dimensional).
prismatic_joint_set_spring_damping_ratio :: proc(world: ^World, joint: Prismatic_Joint_Ref, damping_ratio: f32) {
	b3.prismatic_joint_set_spring_damping_ratio(joint_id(world, joint), damping_ratio)
}

// The prismatic joint's spring damping ratio (non-dimensional).
prismatic_joint_spring_damping_ratio :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> f32 {
	return b3.prismatic_joint_get_spring_damping_ratio(joint_id(world, joint))
}

// Sets the prismatic joint's target translation. Usually in meters.
prismatic_joint_set_target_translation :: proc(world: ^World, joint: Prismatic_Joint_Ref, target_translation: f32) {
	b3.prismatic_joint_set_target_translation(joint_id(world, joint), target_translation)
}

// The prismatic joint's target translation. Usually in meters.
prismatic_joint_target_translation :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> f32 {
	return b3.prismatic_joint_get_target_translation(joint_id(world, joint))
}

// Enables or disables the prismatic joint's limit.
prismatic_joint_enable_limit :: proc(world: ^World, joint: Prismatic_Joint_Ref, enable_limit: bool) {
	b3.prismatic_joint_enable_limit(joint_id(world, joint), enable_limit)
}

// Whether the prismatic joint's limit is enabled.
prismatic_joint_is_limit_enabled :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> bool {
	return b3.prismatic_joint_is_limit_enabled(joint_id(world, joint))
}

// The prismatic joint's lower limit.
prismatic_joint_lower_limit :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> f32 {
	return b3.prismatic_joint_get_lower_limit(joint_id(world, joint))
}

// The prismatic joint's upper limit.
prismatic_joint_upper_limit :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> f32 {
	return b3.prismatic_joint_get_upper_limit(joint_id(world, joint))
}

// Sets the prismatic joint's limits.
prismatic_joint_set_limits :: proc(world: ^World, joint: Prismatic_Joint_Ref, lower: f32, upper: f32) {
	b3.prismatic_joint_set_limits(joint_id(world, joint), lower, upper)
}

// Enables or disables the prismatic joint's motor.
prismatic_joint_enable_motor :: proc(world: ^World, joint: Prismatic_Joint_Ref, enable_motor: bool) {
	b3.prismatic_joint_enable_motor(joint_id(world, joint), enable_motor)
}

// Whether the prismatic joint's motor is enabled.
prismatic_joint_is_motor_enabled :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> bool {
	return b3.prismatic_joint_is_motor_enabled(joint_id(world, joint))
}

// Sets the prismatic joint's motor speed, usually in meters per second.
prismatic_joint_set_motor_speed :: proc(world: ^World, joint: Prismatic_Joint_Ref, motor_speed: f32) {
	b3.prismatic_joint_set_motor_speed(joint_id(world, joint), motor_speed)
}

// The prismatic joint's motor speed, usually in meters per second.
prismatic_joint_motor_speed :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> f32 {
	return b3.prismatic_joint_get_motor_speed(joint_id(world, joint))
}

// Sets the prismatic joint's maximum motor force, usually in newtons.
prismatic_joint_set_max_motor_force :: proc(world: ^World, joint: Prismatic_Joint_Ref, max_force: f32) {
	b3.prismatic_joint_set_max_motor_force(joint_id(world, joint), max_force)
}

// The prismatic joint's maximum motor force, usually in newtons.
prismatic_joint_max_motor_force :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> f32 {
	return b3.prismatic_joint_get_max_motor_force(joint_id(world, joint))
}

// The prismatic joint's current motor force, usually in newtons.
prismatic_joint_motor_force :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> f32 {
	return b3.prismatic_joint_get_motor_force(joint_id(world, joint))
}

// The prismatic joint's current translation, usually in meters.
prismatic_joint_translation :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> f32 {
	return b3.prismatic_joint_get_translation(joint_id(world, joint))
}

// The prismatic joint's current translation speed, usually in meters per second.
prismatic_joint_speed :: proc(world: ^World, joint: Prismatic_Joint_Ref) -> f32 {
	return b3.prismatic_joint_get_speed(joint_id(world, joint))
}

// ---- revolute joints

// Enables or disables the revolute joint's spring.
revolute_joint_enable_spring :: proc(world: ^World, joint: Revolute_Joint_Ref, enable_spring: bool) {
	b3.revolute_joint_enable_spring(joint_id(world, joint), enable_spring)
}

// Whether the revolute joint's angular spring is enabled.
revolute_joint_is_spring_enabled :: proc(world: ^World, joint: Revolute_Joint_Ref) -> bool {
	return b3.revolute_joint_is_spring_enabled(joint_id(world, joint))
}

// Sets the revolute joint's spring stiffness in Hertz.
revolute_joint_set_spring_hertz :: proc(world: ^World, joint: Revolute_Joint_Ref, hertz: f32) {
	b3.revolute_joint_set_spring_hertz(joint_id(world, joint), hertz)
}

// The revolute joint's spring stiffness in Hertz.
revolute_joint_spring_hertz :: proc(world: ^World, joint: Revolute_Joint_Ref) -> f32 {
	return b3.revolute_joint_get_spring_hertz(joint_id(world, joint))
}

// Sets the revolute joint's spring damping ratio, non-dimensional.
revolute_joint_set_spring_damping_ratio :: proc(world: ^World, joint: Revolute_Joint_Ref, damping_ratio: f32) {
	b3.revolute_joint_set_spring_damping_ratio(joint_id(world, joint), damping_ratio)
}

// The revolute joint's spring damping ratio, non-dimensional.
revolute_joint_spring_damping_ratio :: proc(world: ^World, joint: Revolute_Joint_Ref) -> f32 {
	return b3.revolute_joint_get_spring_damping_ratio(joint_id(world, joint))
}

// Sets the revolute joint's target angle in radians.
revolute_joint_set_target_angle :: proc(world: ^World, joint: Revolute_Joint_Ref, target_radians: f32) {
	b3.revolute_joint_set_target_angle(joint_id(world, joint), target_radians)
}

// The revolute joint's target angle in radians.
revolute_joint_target_angle :: proc(world: ^World, joint: Revolute_Joint_Ref) -> f32 {
	return b3.revolute_joint_get_target_angle(joint_id(world, joint))
}

// The revolute joint's current angle in radians, relative to the reference state.
revolute_joint_angle :: proc(world: ^World, joint: Revolute_Joint_Ref) -> f32 {
	return b3.revolute_joint_get_angle(joint_id(world, joint))
}

// Enables or disables the revolute joint's limit.
revolute_joint_enable_limit :: proc(world: ^World, joint: Revolute_Joint_Ref, enable_limit: bool) {
	b3.revolute_joint_enable_limit(joint_id(world, joint), enable_limit)
}

// Whether the revolute joint's limit is enabled.
revolute_joint_is_limit_enabled :: proc(world: ^World, joint: Revolute_Joint_Ref) -> bool {
	return b3.revolute_joint_is_limit_enabled(joint_id(world, joint))
}

// The revolute joint's lower limit in radians.
revolute_joint_lower_limit :: proc(world: ^World, joint: Revolute_Joint_Ref) -> f32 {
	return b3.revolute_joint_get_lower_limit(joint_id(world, joint))
}

// The revolute joint's upper limit in radians.
revolute_joint_upper_limit :: proc(world: ^World, joint: Revolute_Joint_Ref) -> f32 {
	return b3.revolute_joint_get_upper_limit(joint_id(world, joint))
}

// Sets the revolute joint's limits in radians.
revolute_joint_set_limits :: proc(
	world: ^World,
	joint: Revolute_Joint_Ref,
	lower_limit_radians: f32,
	upper_limit_radians: f32,
) {
	b3.revolute_joint_set_limits(joint_id(world, joint), lower_limit_radians, upper_limit_radians)
}

// Enables or disables the revolute joint's motor.
revolute_joint_enable_motor :: proc(world: ^World, joint: Revolute_Joint_Ref, enable_motor: bool) {
	b3.revolute_joint_enable_motor(joint_id(world, joint), enable_motor)
}

// Whether the revolute joint's motor is enabled.
revolute_joint_is_motor_enabled :: proc(world: ^World, joint: Revolute_Joint_Ref) -> bool {
	return b3.revolute_joint_is_motor_enabled(joint_id(world, joint))
}

// Sets the revolute joint's motor speed in radians per second.
revolute_joint_set_motor_speed :: proc(world: ^World, joint: Revolute_Joint_Ref, motor_speed: f32) {
	b3.revolute_joint_set_motor_speed(joint_id(world, joint), motor_speed)
}

// The revolute joint's motor speed in radians per second.
revolute_joint_motor_speed :: proc(world: ^World, joint: Revolute_Joint_Ref) -> f32 {
	return b3.revolute_joint_get_motor_speed(joint_id(world, joint))
}

// The revolute joint's current motor torque, usually in newton-meters.
revolute_joint_motor_torque :: proc(world: ^World, joint: Revolute_Joint_Ref) -> f32 {
	return b3.revolute_joint_get_motor_torque(joint_id(world, joint))
}

// Sets the revolute joint's maximum motor torque, usually in newton-meters.
revolute_joint_set_max_motor_torque :: proc(world: ^World, joint: Revolute_Joint_Ref, max_torque: f32) {
	b3.revolute_joint_set_max_motor_torque(joint_id(world, joint), max_torque)
}

// The revolute joint's maximum motor torque, usually in newton-meters.
revolute_joint_max_motor_torque :: proc(world: ^World, joint: Revolute_Joint_Ref) -> f32 {
	return b3.revolute_joint_get_max_motor_torque(joint_id(world, joint))
}

// ---- spherical joints

// Enables or disables the spherical joint's cone limit.
spherical_joint_enable_cone_limit :: proc(world: ^World, joint: Spherical_Joint_Ref, enable_limit: bool) {
	b3.spherical_joint_enable_cone_limit(joint_id(world, joint), enable_limit)
}

// Whether the spherical joint's cone limit is enabled.
spherical_joint_is_cone_limit_enabled :: proc(world: ^World, joint: Spherical_Joint_Ref) -> bool {
	return b3.spherical_joint_is_cone_limit_enabled(joint_id(world, joint))
}

// The spherical joint's cone limit in radians.
spherical_joint_cone_limit :: proc(world: ^World, joint: Spherical_Joint_Ref) -> f32 {
	return b3.spherical_joint_get_cone_limit(joint_id(world, joint))
}

// Sets the spherical joint's cone limit angle in radians (0 to pi).
spherical_joint_set_cone_limit :: proc(world: ^World, joint: Spherical_Joint_Ref, angle_radians: f32) {
	b3.spherical_joint_set_cone_limit(joint_id(world, joint), angle_radians)
}

// The spherical joint's current cone angle in radians.
spherical_joint_cone_angle :: proc(world: ^World, joint: Spherical_Joint_Ref) -> f32 {
	return b3.spherical_joint_get_cone_angle(joint_id(world, joint))
}

// Enables or disables the spherical joint's twist limit.
spherical_joint_enable_twist_limit :: proc(world: ^World, joint: Spherical_Joint_Ref, enable_limit: bool) {
	b3.spherical_joint_enable_twist_limit(joint_id(world, joint), enable_limit)
}

// Whether the spherical joint's twist limit is enabled.
spherical_joint_is_twist_limit_enabled :: proc(world: ^World, joint: Spherical_Joint_Ref) -> bool {
	return b3.spherical_joint_is_twist_limit_enabled(joint_id(world, joint))
}

// The spherical joint's lower twist limit in radians.
spherical_joint_lower_twist_limit :: proc(world: ^World, joint: Spherical_Joint_Ref) -> f32 {
	return b3.spherical_joint_get_lower_twist_limit(joint_id(world, joint))
}

// The spherical joint's upper twist limit in radians.
spherical_joint_upper_twist_limit :: proc(world: ^World, joint: Spherical_Joint_Ref) -> f32 {
	return b3.spherical_joint_get_upper_twist_limit(joint_id(world, joint))
}

// Sets the spherical joint's twist limits in radians.
spherical_joint_set_twist_limits :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	lower_limit_radians: f32,
	upper_limit_radians: f32,
) {
	b3.spherical_joint_set_twist_limits(joint_id(world, joint), lower_limit_radians, upper_limit_radians)
}

// The spherical joint's current twist angle in radians.
spherical_joint_twist_angle :: proc(world: ^World, joint: Spherical_Joint_Ref) -> f32 {
	return b3.spherical_joint_get_twist_angle(joint_id(world, joint))
}

// Enables or disables the spherical joint's spring.
spherical_joint_enable_spring :: proc(world: ^World, joint: Spherical_Joint_Ref, enable_spring: bool) {
	b3.spherical_joint_enable_spring(joint_id(world, joint), enable_spring)
}

// Whether the spherical joint's angular spring is enabled.
spherical_joint_is_spring_enabled :: proc(world: ^World, joint: Spherical_Joint_Ref) -> bool {
	return b3.spherical_joint_is_spring_enabled(joint_id(world, joint))
}

// Sets the spherical joint's spring stiffness in Hertz.
spherical_joint_set_spring_hertz :: proc(world: ^World, joint: Spherical_Joint_Ref, hertz: f32) {
	b3.spherical_joint_set_spring_hertz(joint_id(world, joint), hertz)
}

// The spherical joint's spring stiffness in Hertz.
spherical_joint_spring_hertz :: proc(world: ^World, joint: Spherical_Joint_Ref) -> f32 {
	return b3.spherical_joint_get_spring_hertz(joint_id(world, joint))
}

// Sets the spherical joint's spring damping ratio, non-dimensional.
spherical_joint_set_spring_damping_ratio :: proc(world: ^World, joint: Spherical_Joint_Ref, damping_ratio: f32) {
	b3.spherical_joint_set_spring_damping_ratio(joint_id(world, joint), damping_ratio)
}

// The spherical joint's spring damping ratio, non-dimensional.
spherical_joint_spring_damping_ratio :: proc(world: ^World, joint: Spherical_Joint_Ref) -> f32 {
	return b3.spherical_joint_get_spring_damping_ratio(joint_id(world, joint))
}

// Sets the spherical joint's spring target rotation.
spherical_joint_set_target_rotation :: proc(world: ^World, joint: Spherical_Joint_Ref, target_rotation: [4]f32) {
	b3.spherical_joint_set_target_rotation(joint_id(world, joint), target_rotation)
}

// The spherical joint's spring target rotation.
spherical_joint_target_rotation :: proc(world: ^World, joint: Spherical_Joint_Ref) -> [4]f32 {
	return b3.spherical_joint_get_target_rotation(joint_id(world, joint))
}

// Enables or disables the spherical joint's motor.
spherical_joint_enable_motor :: proc(world: ^World, joint: Spherical_Joint_Ref, enable_motor: bool) {
	b3.spherical_joint_enable_motor(joint_id(world, joint), enable_motor)
}

// Whether the spherical joint's motor is enabled.
spherical_joint_is_motor_enabled :: proc(world: ^World, joint: Spherical_Joint_Ref) -> bool {
	return b3.spherical_joint_is_motor_enabled(joint_id(world, joint))
}

// Sets the spherical joint's motor velocity in radians per second: B's angular velocity minus A's, world frame.
spherical_joint_set_motor_velocity :: proc(world: ^World, joint: Spherical_Joint_Ref, motor_velocity: [3]f32) {
	b3.spherical_joint_set_motor_velocity(joint_id(world, joint), motor_velocity)
}

// The spherical joint's motor velocity in radians per second.
spherical_joint_motor_velocity :: proc(world: ^World, joint: Spherical_Joint_Ref) -> [3]f32 {
	return b3.spherical_joint_get_motor_velocity(joint_id(world, joint))
}

// The spherical joint's current motor torque, usually in newton-meters.
spherical_joint_motor_torque :: proc(world: ^World, joint: Spherical_Joint_Ref) -> [3]f32 {
	return b3.spherical_joint_get_motor_torque(joint_id(world, joint))
}

// Sets the spherical joint's maximum motor torque, usually in newton-meters.
spherical_joint_set_max_motor_torque :: proc(world: ^World, joint: Spherical_Joint_Ref, max_torque: f32) {
	b3.spherical_joint_set_max_motor_torque(joint_id(world, joint), max_torque)
}

// The spherical joint's maximum motor torque, usually in newton-meters.
spherical_joint_max_motor_torque :: proc(world: ^World, joint: Spherical_Joint_Ref) -> f32 {
	return b3.spherical_joint_get_max_motor_torque(joint_id(world, joint))
}

// ---- weld joints

// Sets the weld joint's linear stiffness in Hertz. 0 is rigid.
weld_joint_set_linear_hertz :: proc(world: ^World, joint: Weld_Joint_Ref, hertz: f32) {
	b3.weld_joint_set_linear_hertz(joint_id(world, joint), hertz)
}

// The weld joint's linear stiffness in Hertz.
weld_joint_linear_hertz :: proc(world: ^World, joint: Weld_Joint_Ref) -> f32 {
	return b3.weld_joint_get_linear_hertz(joint_id(world, joint))
}

// Sets the weld joint's linear damping ratio (non-dimensional).
weld_joint_set_linear_damping_ratio :: proc(world: ^World, joint: Weld_Joint_Ref, damping_ratio: f32) {
	b3.weld_joint_set_linear_damping_ratio(joint_id(world, joint), damping_ratio)
}

// The weld joint's linear damping ratio (non-dimensional).
weld_joint_linear_damping_ratio :: proc(world: ^World, joint: Weld_Joint_Ref) -> f32 {
	return b3.weld_joint_get_linear_damping_ratio(joint_id(world, joint))
}

// Sets the weld joint's angular stiffness in Hertz. 0 is rigid.
weld_joint_set_angular_hertz :: proc(world: ^World, joint: Weld_Joint_Ref, hertz: f32) {
	b3.weld_joint_set_angular_hertz(joint_id(world, joint), hertz)
}

// The weld joint's angular stiffness in Hertz.
weld_joint_angular_hertz :: proc(world: ^World, joint: Weld_Joint_Ref) -> f32 {
	return b3.weld_joint_get_angular_hertz(joint_id(world, joint))
}

// Sets the weld joint's angular damping ratio, non-dimensional.
weld_joint_set_angular_damping_ratio :: proc(world: ^World, joint: Weld_Joint_Ref, damping_ratio: f32) {
	b3.weld_joint_set_angular_damping_ratio(joint_id(world, joint), damping_ratio)
}

// The weld joint's angular damping ratio, non-dimensional.
weld_joint_angular_damping_ratio :: proc(world: ^World, joint: Weld_Joint_Ref) -> f32 {
	return b3.weld_joint_get_angular_damping_ratio(joint_id(world, joint))
}

// ---- wheel joints

// Enables or disables the wheel joint's suspension spring.
wheel_joint_enable_suspension :: proc(world: ^World, joint: Wheel_Joint_Ref, enable_spring: bool) {
	b3.wheel_joint_enable_suspension(joint_id(world, joint), enable_spring)
}

// Whether the wheel joint's suspension spring is enabled.
wheel_joint_is_suspension_enabled :: proc(world: ^World, joint: Wheel_Joint_Ref) -> bool {
	return b3.wheel_joint_is_suspension_enabled(joint_id(world, joint))
}

// Sets the wheel joint's suspension stiffness in Hertz.
wheel_joint_set_suspension_hertz :: proc(world: ^World, joint: Wheel_Joint_Ref, hertz: f32) {
	b3.wheel_joint_set_suspension_hertz(joint_id(world, joint), hertz)
}

// The wheel joint's suspension stiffness in Hertz.
wheel_joint_suspension_hertz :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_suspension_hertz(joint_id(world, joint))
}

// Sets the wheel joint's suspension damping ratio, non-dimensional.
wheel_joint_set_suspension_damping_ratio :: proc(world: ^World, joint: Wheel_Joint_Ref, damping_ratio: f32) {
	b3.wheel_joint_set_suspension_damping_ratio(joint_id(world, joint), damping_ratio)
}

// The wheel joint's suspension damping ratio, non-dimensional.
wheel_joint_suspension_damping_ratio :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_suspension_damping_ratio(joint_id(world, joint))
}

// Enables or disables the wheel joint's suspension limit.
wheel_joint_enable_suspension_limit :: proc(world: ^World, joint: Wheel_Joint_Ref, enable_limit: bool) {
	b3.wheel_joint_enable_suspension_limit(joint_id(world, joint), enable_limit)
}

// Whether the wheel joint's suspension limit is enabled.
wheel_joint_is_suspension_limit_enabled :: proc(world: ^World, joint: Wheel_Joint_Ref) -> bool {
	return b3.wheel_joint_is_suspension_limit_enabled(joint_id(world, joint))
}

// The wheel joint's lower suspension limit.
wheel_joint_lower_suspension_limit :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_lower_suspension_limit(joint_id(world, joint))
}

// The wheel joint's upper suspension limit.
wheel_joint_upper_suspension_limit :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_upper_suspension_limit(joint_id(world, joint))
}

// Sets the wheel joint's suspension limits.
wheel_joint_set_suspension_limits :: proc(world: ^World, joint: Wheel_Joint_Ref, lower: f32, upper: f32) {
	b3.wheel_joint_set_suspension_limits(joint_id(world, joint), lower, upper)
}

// Enables or disables the wheel joint's spin motor.
wheel_joint_enable_spin_motor :: proc(world: ^World, joint: Wheel_Joint_Ref, enable_motor: bool) {
	b3.wheel_joint_enable_spin_motor(joint_id(world, joint), enable_motor)
}

// Whether the wheel joint's spin motor is enabled.
wheel_joint_is_spin_motor_enabled :: proc(world: ^World, joint: Wheel_Joint_Ref) -> bool {
	return b3.wheel_joint_is_spin_motor_enabled(joint_id(world, joint))
}

// Sets the wheel joint's spin motor speed in radians per second.
wheel_joint_set_spin_motor_speed :: proc(world: ^World, joint: Wheel_Joint_Ref, motor_speed: f32) {
	b3.wheel_joint_set_spin_motor_speed(joint_id(world, joint), motor_speed)
}

// The wheel joint's spin motor speed in radians per second.
wheel_joint_spin_motor_speed :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_spin_motor_speed(joint_id(world, joint))
}

// Sets the wheel joint's maximum spin motor torque, usually in newton-meters.
wheel_joint_set_max_spin_torque :: proc(world: ^World, joint: Wheel_Joint_Ref, torque: f32) {
	b3.wheel_joint_set_max_spin_torque(joint_id(world, joint), torque)
}

// The wheel joint's maximum spin motor torque, usually in newton-meters.
wheel_joint_max_spin_torque :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_max_spin_torque(joint_id(world, joint))
}

// The wheel joint's current spin speed in radians per second.
wheel_joint_spin_speed :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_spin_speed(joint_id(world, joint))
}

// The wheel joint's current spin motor torque, usually in newton-meters.
wheel_joint_spin_torque :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_spin_torque(joint_id(world, joint))
}

// Enables or disables steering (the wheel rotating about the suspension axis).
wheel_joint_enable_steering :: proc(world: ^World, joint: Wheel_Joint_Ref, enable: bool) {
	b3.wheel_joint_enable_steering(joint_id(world, joint), enable)
}

// Whether the wheel can steer.
wheel_joint_is_steering_enabled :: proc(world: ^World, joint: Wheel_Joint_Ref) -> bool {
	return b3.wheel_joint_is_steering_enabled(joint_id(world, joint))
}

// Sets the wheel joint's steering stiffness in Hertz.
wheel_joint_set_steering_hertz :: proc(world: ^World, joint: Wheel_Joint_Ref, hertz: f32) {
	b3.wheel_joint_set_steering_hertz(joint_id(world, joint), hertz)
}

// The wheel joint's steering stiffness in Hertz.
wheel_joint_steering_hertz :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_steering_hertz(joint_id(world, joint))
}

// Sets the wheel joint's steering damping ratio, non-dimensional.
wheel_joint_set_steering_damping_ratio :: proc(world: ^World, joint: Wheel_Joint_Ref, damping_ratio: f32) {
	b3.wheel_joint_set_steering_damping_ratio(joint_id(world, joint), damping_ratio)
}

// The wheel joint's steering damping ratio, non-dimensional.
wheel_joint_steering_damping_ratio :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_steering_damping_ratio(joint_id(world, joint))
}

// Sets the wheel joint's maximum steering torque in N·m.
wheel_joint_set_max_steering_torque :: proc(world: ^World, joint: Wheel_Joint_Ref, max_torque: f32) {
	b3.wheel_joint_set_max_steering_torque(joint_id(world, joint), max_torque)
}

// The wheel joint's maximum steering torque in N·m.
wheel_joint_max_steering_torque :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_max_steering_torque(joint_id(world, joint))
}

// Enables or disables the wheel joint's steering limit.
wheel_joint_enable_steering_limit :: proc(world: ^World, joint: Wheel_Joint_Ref, enable: bool) {
	b3.wheel_joint_enable_steering_limit(joint_id(world, joint), enable)
}

// Whether the wheel joint's steering limit is enabled.
wheel_joint_is_steering_limit_enabled :: proc(world: ^World, joint: Wheel_Joint_Ref) -> bool {
	return b3.wheel_joint_is_steering_limit_enabled(joint_id(world, joint))
}

// The wheel joint's lower steering limit in radians.
wheel_joint_lower_steering_limit :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_lower_steering_limit(joint_id(world, joint))
}

// The wheel joint's upper steering limit in radians.
wheel_joint_upper_steering_limit :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_upper_steering_limit(joint_id(world, joint))
}

// Sets the wheel joint's steering limits in radians.
wheel_joint_set_steering_limits :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	lower_radians: f32,
	upper_radians: f32,
) {
	b3.wheel_joint_set_steering_limits(joint_id(world, joint), lower_radians, upper_radians)
}

// Sets the wheel joint's target steering angle in radians.
wheel_joint_set_target_steering_angle :: proc(world: ^World, joint: Wheel_Joint_Ref, radians: f32) {
	b3.wheel_joint_set_target_steering_angle(joint_id(world, joint), radians)
}

// The wheel joint's target steering angle in radians.
wheel_joint_target_steering_angle :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_target_steering_angle(joint_id(world, joint))
}

// The wheel joint's current steering angle in radians.
wheel_joint_steering_angle :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_steering_angle(joint_id(world, joint))
}

// The wheel joint's current steering torque in N·m.
wheel_joint_steering_torque :: proc(world: ^World, joint: Wheel_Joint_Ref) -> f32 {
	return b3.wheel_joint_get_steering_torque(joint_id(world, joint))
}
