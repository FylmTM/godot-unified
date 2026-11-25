// Joints (src/physics/README.md, What physics covers): every Box3D joint proc on a joint ref, named by its names
// without `get_`. The generic joint_* procs take any joint ref; a per-type proc takes its typed ref, so a setter of
// another type does not compile. Creation takes the two bodies as links and fills the def's body ids itself. Every
// proc on a joint asserts the ref names a live joint (a ref may be stale: Joint_Ref), except joint_valid, joint_as,
// destroy_joint and stop_ignoring, which take a stale one.
package physics

import "base:intrinsics"
import "base:runtime"

import box3d "box3d:bindings"


// Box3D's default distance joint definition, to adjust before creating one.
default_distance_joint_def :: proc() -> Distance_Joint_Def {
	return transmute(Distance_Joint_Def)box3d.DefaultDistanceJointDef()
}
// Box3D's default filter joint definition, to adjust before creating one.
default_filter_joint_def :: proc() -> Filter_Joint_Def {
	return transmute(Filter_Joint_Def)box3d.DefaultFilterJointDef()
}
// Box3D's default parallel joint definition, to adjust before creating one.
default_parallel_joint_def :: proc() -> Parallel_Joint_Def {
	return transmute(Parallel_Joint_Def)box3d.DefaultParallelJointDef()
}
// Box3D's default prismatic joint definition, to adjust before creating one.
default_prismatic_joint_def :: proc() -> Prismatic_Joint_Def {
	return transmute(Prismatic_Joint_Def)box3d.DefaultPrismaticJointDef()
}
// Box3D's default revolute joint definition, to adjust before creating one.
default_revolute_joint_def :: proc() -> Revolute_Joint_Def {
	return transmute(Revolute_Joint_Def)box3d.DefaultRevoluteJointDef()
}
// Box3D's default spherical joint definition, to adjust before creating one.
default_spherical_joint_def :: proc() -> Spherical_Joint_Def {
	return transmute(Spherical_Joint_Def)box3d.DefaultSphericalJointDef()
}
// Box3D's default weld joint definition, to adjust before creating one.
default_weld_joint_def :: proc() -> Weld_Joint_Def {
	return transmute(Weld_Joint_Def)box3d.DefaultWeldJointDef()
}
// Box3D's default wheel joint definition, to adjust before creating one.
default_wheel_joint_def :: proc() -> Wheel_Joint_Def {
	return transmute(Wheel_Joint_Def)box3d.DefaultWheelJointDef()
}

// The World's anchor: a static body every World has (its first), for joints that hold a body to the world.
world_anchor :: proc(world: ^World) -> Body_Link {
	return link_of(world.anchor)
}

// ---- creation: the def's body ids come from the links (both must name live bodies); its user_data stays unset

// Creates a distance joint between two bodies.
create_distance_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Distance_Joint_Def,
	loc := #caller_location,
) -> Distance_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreateDistanceJoint(world.id, (^box3d.DistanceJointDef)(&def)))}
}

// Creates a filter joint between two bodies (it only stops them colliding).
create_filter_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Filter_Joint_Def,
	loc := #caller_location,
) -> Filter_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreateFilterJoint(world.id, (^box3d.FilterJointDef)(&def)))}
}

// Stops two bodies touching each other (no contact, no events between them; each still collides with everything
// else) until stop_ignoring: a thrower and what it threw, a carrier and what it carries. A filter joint, so it is
// rollback state like any joint: keep the ref in the block. Destroying either body ends it and leaves the ref stale,
// as any joint ref (Joint_Ref): stop_ignoring and destroy_refs take it as it is.
ignore_contacts :: proc(world: ^World, body_a, body_b: Body_Link, loc := #caller_location) -> Filter_Joint_Ref {
	return create_filter_joint(world, body_a, body_b, default_filter_joint_def(), loc)
}

// Ends an ignore_contacts: the two bodies collide again from the next step, even when they overlap at rest (it sets
// the joint's bodies to collide before destroying it, so Box3D pairs them again; a bare destroy_joint leaves a resting
// overlap alone until one moves). Zeroes the ref; a zero or stale ref is only zeroed.
stop_ignoring :: proc(world: ^World, ignore: ^Filter_Joint_Ref) {
	if joint_valid(world, ignore.joint) do box3d.Joint_SetCollideConnected(joint_id(world, ignore.joint), true)
	destroy_joint(world, &ignore.joint)
}

// Creates a motor joint between two bodies.
create_motor_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Motor_Joint_Def,
	loc := #caller_location,
) -> Motor_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreateMotorJoint(world.id, (^box3d.MotorJointDef)(&def)))}
}

// Creates a mover joint between two bodies.
create_mover_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Mover_Joint_Def,
	loc := #caller_location,
) -> Mover_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreateMoverJoint(world.id, (^box3d.MoverJointDef)(&def)))}
}

// Creates a parallel joint between two bodies.
create_parallel_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Parallel_Joint_Def,
	loc := #caller_location,
) -> Parallel_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreateParallelJoint(world.id, (^box3d.ParallelJointDef)(&def)))}
}

// Creates a pogo joint between two bodies.
create_pogo_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Pogo_Joint_Def,
	loc := #caller_location,
) -> Pogo_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreatePogoJoint(world.id, (^box3d.PogoJointDef)(&def)))}
}

// Creates a prismatic joint between two bodies.
create_prismatic_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Prismatic_Joint_Def,
	loc := #caller_location,
) -> Prismatic_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreatePrismaticJoint(world.id, (^box3d.PrismaticJointDef)(&def)))}
}

// Creates a revolute joint between two bodies.
create_revolute_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Revolute_Joint_Def,
	loc := #caller_location,
) -> Revolute_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreateRevoluteJoint(world.id, (^box3d.RevoluteJointDef)(&def)))}
}

// Creates a spherical joint between two bodies.
create_spherical_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Spherical_Joint_Def,
	loc := #caller_location,
) -> Spherical_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreateSphericalJoint(world.id, (^box3d.SphericalJointDef)(&def)))}
}

// Creates a weld joint between two bodies.
create_weld_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Weld_Joint_Def,
	loc := #caller_location,
) -> Weld_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreateWeldJoint(world.id, (^box3d.WeldJointDef)(&def)))}
}

// Creates a wheel joint between two bodies.
create_wheel_joint :: proc(
	world: ^World,
	body_a, body_b: Body_Link,
	def: Wheel_Joint_Def,
	loc := #caller_location,
) -> Wheel_Joint_Ref {
	def := def
	set_joint_bodies(world, &def.base, body_a, body_b, loc)
	return {joint_ref_of(box3d.CreateWheelJoint(world.id, (^box3d.WheelJointDef)(&def)))}
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
	refs := JOINT_REFS
	if !joint_valid(world, joint) || refs[joint_type(world, joint)] != J do return {}, false
	return J{joint = joint}, true
}

// The typed joint ref of each Box3D joint type.
@(private)
JOINT_REFS :: [Joint_Type]typeid {
	.Parallel  = Parallel_Joint_Ref,
	.Distance  = Distance_Joint_Ref,
	.Filter    = Filter_Joint_Ref,
	.Motor     = Motor_Joint_Ref,
	.Prismatic = Prismatic_Joint_Ref,
	.Revolute  = Revolute_Joint_Ref,
	.Spherical = Spherical_Joint_Ref,
	.Weld      = Weld_Joint_Ref,
	.Wheel     = Wheel_Joint_Ref,
	.Mover     = Mover_Joint_Ref,
	.Pogo      = Pogo_Joint_Ref,
}

// ---- on any joint ref

// The joint's type.
joint_type :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> Joint_Type {
	return Joint_Type(box3d.Joint_GetType(joint_id(world, joint, loc)))
}

// The joint's first body.
joint_body_a :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> Body_Link {
	return link_of(box3d.Joint_GetBodyA(joint_id(world, joint, loc)))
}

// The joint's second body.
joint_body_b :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> Body_Link {
	return link_of(box3d.Joint_GetBodyB(joint_id(world, joint, loc)))
}

// Moves the joint's frame on body A (in A's frame).
joint_set_local_frame_a :: proc(world: ^World, joint: Joint_Ref, local_frame: Transform, loc := #caller_location) {
	box3d.Joint_SetLocalFrameA(joint_id(world, joint, loc), transmute(box3d.Transform)local_frame)
}

// The joint's frame on body A (in A's frame).
joint_local_frame_a :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> Transform {
	return transmute(Transform)box3d.Joint_GetLocalFrameA(joint_id(world, joint, loc))
}

// Moves the joint's frame on body B (in B's frame).
joint_set_local_frame_b :: proc(world: ^World, joint: Joint_Ref, local_frame: Transform, loc := #caller_location) {
	box3d.Joint_SetLocalFrameB(joint_id(world, joint, loc), transmute(box3d.Transform)local_frame)
}

// The joint's frame on body B (in B's frame).
joint_local_frame_b :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> Transform {
	return transmute(Transform)box3d.Joint_GetLocalFrameB(joint_id(world, joint, loc))
}

// Sets whether the joint's two bodies collide with each other.
joint_set_collide_connected :: proc(world: ^World, joint: Joint_Ref, should_collide: bool, loc := #caller_location) {
	box3d.Joint_SetCollideConnected(joint_id(world, joint, loc), should_collide)
}

// Whether the joint's two bodies collide with each other.
joint_collide_connected :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> bool {
	return box3d.Joint_GetCollideConnected(joint_id(world, joint, loc))
}

// Wakes the joint's bodies.
joint_wake_bodies :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) {
	box3d.Joint_WakeBodies(joint_id(world, joint, loc))
}

// Whether the joint is awake (an attached body is awake).
joint_is_awake :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> bool {
	return box3d.Joint_IsAwake(joint_id(world, joint, loc))
}

// The current constraint force for this joint.
joint_constraint_force :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> [3]f32 {
	return transmute([3]f32)box3d.Joint_GetConstraintForce(joint_id(world, joint, loc))
}

// The current constraint torque for this joint. Call it only inside the tick, on every peer: on a revolute or a
// parallel joint Box3D's getter writes solver state that the world's deep hash, a snapshot and an image hold (the next
// step recomputes it), so a call from a view or a tool would make this peer's hash and late-join image differ. Every
// other joint getter leaves the world as it was.
joint_constraint_torque :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> [3]f32 {
	return transmute([3]f32)box3d.Joint_GetConstraintTorque(joint_id(world, joint, loc))
}

// The joint's current linear error (m), not counting the movement it allows.
joint_linear_separation :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.Joint_GetLinearSeparation(joint_id(world, joint, loc))
}

// The joint's current angular error (radians), not counting the movement it allows.
joint_angular_separation :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.Joint_GetAngularSeparation(joint_id(world, joint, loc))
}

// Sets the joint's constraint stiffness (Hz) and damping ratio (1: critical). Advanced.
joint_set_constraint_tuning :: proc(
	world: ^World,
	joint: Joint_Ref,
	hertz: f32,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.Joint_SetConstraintTuning(joint_id(world, joint, loc), hertz, damping_ratio)
}

// The joint's constraint stiffness (Hz) and damping ratio. Advanced.
joint_constraint_tuning :: proc(
	world: ^World,
	joint: Joint_Ref,
	loc := #caller_location,
) -> (
	hertz: f32,
	damping_ratio: f32,
) {
	box3d.Joint_GetConstraintTuning(joint_id(world, joint, loc), &hertz, &damping_ratio)
	return
}

// Sets the force (N) above which the joint reports a joint event.
joint_set_force_threshold :: proc(world: ^World, joint: Joint_Ref, threshold: f32, loc := #caller_location) {
	box3d.Joint_SetForceThreshold(joint_id(world, joint, loc), threshold)
}

// The force (N) above which the joint reports a joint event.
joint_force_threshold :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.Joint_GetForceThreshold(joint_id(world, joint, loc))
}

// Sets the torque (N·m) above which the joint reports a joint event.
joint_set_torque_threshold :: proc(world: ^World, joint: Joint_Ref, threshold: f32, loc := #caller_location) {
	box3d.Joint_SetTorqueThreshold(joint_id(world, joint, loc), threshold)
}

// The torque (N·m) above which the joint reports a joint event.
joint_torque_threshold :: proc(world: ^World, joint: Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.Joint_GetTorqueThreshold(joint_id(world, joint, loc))
}

// ---- parallel joints

// Sets the parallel joint's spring stiffness in Hertz.
parallel_joint_set_spring_hertz :: proc(
	world: ^World,
	joint: Parallel_Joint_Ref,
	hertz: f32,
	loc := #caller_location,
) {
	box3d.ParallelJoint_SetSpringHertz(joint_id(world, joint, loc), hertz)
}

// Sets the parallel joint's spring damping ratio, non-dimensional.
parallel_joint_set_spring_damping_ratio :: proc(
	world: ^World,
	joint: Parallel_Joint_Ref,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.ParallelJoint_SetSpringDampingRatio(joint_id(world, joint, loc), damping_ratio)
}

// The parallel joint's spring Hertz.
parallel_joint_spring_hertz :: proc(world: ^World, joint: Parallel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.ParallelJoint_GetSpringHertz(joint_id(world, joint, loc))
}

// The parallel joint's spring damping ratio.
parallel_joint_spring_damping_ratio :: proc(world: ^World, joint: Parallel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.ParallelJoint_GetSpringDampingRatio(joint_id(world, joint, loc))
}

// Sets the parallel joint's maximum spring torque, usually in newton-meters.
parallel_joint_set_max_torque :: proc(
	world: ^World,
	joint: Parallel_Joint_Ref,
	max_torque: f32,
	loc := #caller_location,
) {
	box3d.ParallelJoint_SetMaxTorque(joint_id(world, joint, loc), max_torque)
}

// The parallel joint's maximum spring torque, usually in newton-meters.
parallel_joint_max_torque :: proc(world: ^World, joint: Parallel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.ParallelJoint_GetMaxTorque(joint_id(world, joint, loc))
}

// ---- distance joints

// Sets the rest length of a distance joint.
distance_joint_set_length :: proc(world: ^World, joint: Distance_Joint_Ref, length: f32, loc := #caller_location) {
	box3d.DistanceJoint_SetLength(joint_id(world, joint, loc), length)
}

// The rest length of a distance joint.
distance_joint_length :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.DistanceJoint_GetLength(joint_id(world, joint, loc))
}

// Enables or disables the distance joint's spring (disabled: the joint is rigid).
distance_joint_enable_spring :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	enable_spring: bool,
	loc := #caller_location,
) {
	box3d.DistanceJoint_EnableSpring(joint_id(world, joint, loc), enable_spring)
}

// Whether the distance joint's spring is enabled.
distance_joint_is_spring_enabled :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.DistanceJoint_IsSpringEnabled(joint_id(world, joint, loc))
}

// Sets the distance joint's force range for the spring.
distance_joint_set_spring_force_range :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	lower_force: f32,
	upper_force: f32,
	loc := #caller_location,
) {
	box3d.DistanceJoint_SetSpringForceRange(joint_id(world, joint, loc), lower_force, upper_force)
}

// The distance joint's force range for the spring.
distance_joint_spring_force_range :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	loc := #caller_location,
) -> (
	lower_force: f32,
	upper_force: f32,
) {
	box3d.DistanceJoint_GetSpringForceRange(joint_id(world, joint, loc), &lower_force, &upper_force)
	return
}

// Sets the distance joint's spring stiffness in Hertz.
distance_joint_set_spring_hertz :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	hertz: f32,
	loc := #caller_location,
) {
	box3d.DistanceJoint_SetSpringHertz(joint_id(world, joint, loc), hertz)
}

// Sets the distance joint's spring damping ratio, non-dimensional.
distance_joint_set_spring_damping_ratio :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.DistanceJoint_SetSpringDampingRatio(joint_id(world, joint, loc), damping_ratio)
}

// The distance joint's spring Hertz.
distance_joint_spring_hertz :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.DistanceJoint_GetSpringHertz(joint_id(world, joint, loc))
}

// The distance joint's spring damping ratio.
distance_joint_spring_damping_ratio :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.DistanceJoint_GetSpringDampingRatio(joint_id(world, joint, loc))
}

// Enables or disables the distance joint's length limit (it acts only with the spring enabled; a rigid joint ignores it).
distance_joint_enable_limit :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	enable_limit: bool,
	loc := #caller_location,
) {
	box3d.DistanceJoint_EnableLimit(joint_id(world, joint, loc), enable_limit)
}

// Whether the distance joint's limit is enabled.
distance_joint_is_limit_enabled :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.DistanceJoint_IsLimitEnabled(joint_id(world, joint, loc))
}

// Sets the minimum and maximum length parameters of a distance joint.
distance_joint_set_length_range :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	min_length: f32,
	max_length: f32,
	loc := #caller_location,
) {
	box3d.DistanceJoint_SetLengthRange(joint_id(world, joint, loc), min_length, max_length)
}

// The distance joint's minimum length.
distance_joint_min_length :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.DistanceJoint_GetMinLength(joint_id(world, joint, loc))
}

// The distance joint's maximum length.
distance_joint_max_length :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.DistanceJoint_GetMaxLength(joint_id(world, joint, loc))
}

// The current length of a distance joint.
distance_joint_current_length :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.DistanceJoint_GetCurrentLength(joint_id(world, joint, loc))
}

// Enables or disables the distance joint's motor.
distance_joint_enable_motor :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	enable_motor: bool,
	loc := #caller_location,
) {
	box3d.DistanceJoint_EnableMotor(joint_id(world, joint, loc), enable_motor)
}

// Whether the distance joint's motor is enabled.
distance_joint_is_motor_enabled :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.DistanceJoint_IsMotorEnabled(joint_id(world, joint, loc))
}

// Sets the distance joint's motor speed, usually in meters per second.
distance_joint_set_motor_speed :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	motor_speed: f32,
	loc := #caller_location,
) {
	box3d.DistanceJoint_SetMotorSpeed(joint_id(world, joint, loc), motor_speed)
}

// The distance joint's motor speed, usually in meters per second.
distance_joint_motor_speed :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.DistanceJoint_GetMotorSpeed(joint_id(world, joint, loc))
}

// Sets the distance joint's maximum motor force, usually in newtons.
distance_joint_set_max_motor_force :: proc(
	world: ^World,
	joint: Distance_Joint_Ref,
	force: f32,
	loc := #caller_location,
) {
	box3d.DistanceJoint_SetMaxMotorForce(joint_id(world, joint, loc), force)
}

// The distance joint's maximum motor force, usually in newtons.
distance_joint_max_motor_force :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.DistanceJoint_GetMaxMotorForce(joint_id(world, joint, loc))
}

// The distance joint's current motor force, usually in newtons.
distance_joint_motor_force :: proc(world: ^World, joint: Distance_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.DistanceJoint_GetMotorForce(joint_id(world, joint, loc))
}

// ---- motor joints

// Sets the motor joint's desired relative linear velocity in meters per second.
motor_joint_set_linear_velocity :: proc(
	world: ^World,
	joint: Motor_Joint_Ref,
	velocity: [3]f32,
	loc := #caller_location,
) {
	box3d.MotorJoint_SetLinearVelocity(joint_id(world, joint, loc), transmute(box3d.Vec3)velocity)
}

// The motor joint's desired relative linear velocity in meters per second.
motor_joint_linear_velocity :: proc(world: ^World, joint: Motor_Joint_Ref, loc := #caller_location) -> [3]f32 {
	return transmute([3]f32)box3d.MotorJoint_GetLinearVelocity(joint_id(world, joint, loc))
}

// Sets the motor joint's desired relative angular velocity in radians per second.
motor_joint_set_angular_velocity :: proc(
	world: ^World,
	joint: Motor_Joint_Ref,
	velocity: [3]f32,
	loc := #caller_location,
) {
	box3d.MotorJoint_SetAngularVelocity(joint_id(world, joint, loc), transmute(box3d.Vec3)velocity)
}

// The motor joint's desired relative angular velocity in radians per second.
motor_joint_angular_velocity :: proc(world: ^World, joint: Motor_Joint_Ref, loc := #caller_location) -> [3]f32 {
	return transmute([3]f32)box3d.MotorJoint_GetAngularVelocity(joint_id(world, joint, loc))
}

// Sets the motor joint's maximum force, usually in newtons.
motor_joint_set_max_velocity_force :: proc(
	world: ^World,
	joint: Motor_Joint_Ref,
	max_force: f32,
	loc := #caller_location,
) {
	box3d.MotorJoint_SetMaxVelocityForce(joint_id(world, joint, loc), max_force)
}

// The motor joint's maximum force, usually in newtons.
motor_joint_max_velocity_force :: proc(world: ^World, joint: Motor_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.MotorJoint_GetMaxVelocityForce(joint_id(world, joint, loc))
}

// Sets the motor joint's maximum torque, usually in newton-meters.
motor_joint_set_max_velocity_torque :: proc(
	world: ^World,
	joint: Motor_Joint_Ref,
	max_torque: f32,
	loc := #caller_location,
) {
	box3d.MotorJoint_SetMaxVelocityTorque(joint_id(world, joint, loc), max_torque)
}

// The motor joint's maximum torque, usually in newton-meters.
motor_joint_max_velocity_torque :: proc(world: ^World, joint: Motor_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.MotorJoint_GetMaxVelocityTorque(joint_id(world, joint, loc))
}

// Sets the motor joint's spring linear hertz stiffness.
motor_joint_set_linear_hertz :: proc(world: ^World, joint: Motor_Joint_Ref, hertz: f32, loc := #caller_location) {
	box3d.MotorJoint_SetLinearHertz(joint_id(world, joint, loc), hertz)
}

// The motor joint's spring linear hertz stiffness.
motor_joint_linear_hertz :: proc(world: ^World, joint: Motor_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.MotorJoint_GetLinearHertz(joint_id(world, joint, loc))
}

// Sets the motor joint's linear spring damping ratio (1: critical).
motor_joint_set_linear_damping_ratio :: proc(
	world: ^World,
	joint: Motor_Joint_Ref,
	damping: f32,
	loc := #caller_location,
) {
	box3d.MotorJoint_SetLinearDampingRatio(joint_id(world, joint, loc), damping)
}

// The motor joint's spring linear damping ratio.
motor_joint_linear_damping_ratio :: proc(world: ^World, joint: Motor_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.MotorJoint_GetLinearDampingRatio(joint_id(world, joint, loc))
}

// Sets the motor joint's spring angular hertz stiffness.
motor_joint_set_angular_hertz :: proc(world: ^World, joint: Motor_Joint_Ref, hertz: f32, loc := #caller_location) {
	box3d.MotorJoint_SetAngularHertz(joint_id(world, joint, loc), hertz)
}

// The motor joint's spring angular hertz stiffness.
motor_joint_angular_hertz :: proc(world: ^World, joint: Motor_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.MotorJoint_GetAngularHertz(joint_id(world, joint, loc))
}

// Sets the motor joint's angular spring damping ratio (1: critical).
motor_joint_set_angular_damping_ratio :: proc(
	world: ^World,
	joint: Motor_Joint_Ref,
	damping: f32,
	loc := #caller_location,
) {
	box3d.MotorJoint_SetAngularDampingRatio(joint_id(world, joint, loc), damping)
}

// The motor joint's spring angular damping ratio.
motor_joint_angular_damping_ratio :: proc(world: ^World, joint: Motor_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.MotorJoint_GetAngularDampingRatio(joint_id(world, joint, loc))
}

// Sets the motor joint's maximum spring force in newtons.
motor_joint_set_max_spring_force :: proc(
	world: ^World,
	joint: Motor_Joint_Ref,
	max_force: f32,
	loc := #caller_location,
) {
	box3d.MotorJoint_SetMaxSpringForce(joint_id(world, joint, loc), max_force)
}

// The motor joint's maximum spring force in newtons.
motor_joint_max_spring_force :: proc(world: ^World, joint: Motor_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.MotorJoint_GetMaxSpringForce(joint_id(world, joint, loc))
}

// Sets the motor joint's maximum spring torque in N·m.
motor_joint_set_max_spring_torque :: proc(
	world: ^World,
	joint: Motor_Joint_Ref,
	max_torque: f32,
	loc := #caller_location,
) {
	box3d.MotorJoint_SetMaxSpringTorque(joint_id(world, joint, loc), max_torque)
}

// The motor joint's maximum spring torque in N·m.
motor_joint_max_spring_torque :: proc(world: ^World, joint: Motor_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.MotorJoint_GetMaxSpringTorque(joint_id(world, joint, loc))
}

// ---- mover joints

// Sets the mover joint's target velocity of B relative to A, usually in meters per second.
mover_joint_set_linear_velocity :: proc(
	world: ^World,
	joint: Mover_Joint_Ref,
	velocity: [3]f32,
	loc := #caller_location,
) {
	box3d.MoverJoint_SetLinearVelocity(joint_id(world, joint, loc), transmute(box3d.Vec3)velocity)
}

// The mover joint's target velocity of B relative to A, usually in meters per second.
mover_joint_linear_velocity :: proc(world: ^World, joint: Mover_Joint_Ref, loc := #caller_location) -> [3]f32 {
	return transmute([3]f32)box3d.MoverJoint_GetLinearVelocity(joint_id(world, joint, loc))
}

// Sets the force cap of the mover joint's velocity drive (0: no drive), usually in newtons.
mover_joint_set_max_velocity_force :: proc(
	world: ^World,
	joint: Mover_Joint_Ref,
	max_force: f32,
	loc := #caller_location,
) {
	box3d.MoverJoint_SetMaxVelocityForce(joint_id(world, joint, loc), max_force)
}

// The force cap of the mover joint's velocity drive, usually in newtons.
mover_joint_max_velocity_force :: proc(world: ^World, joint: Mover_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.MoverJoint_GetMaxVelocityForce(joint_id(world, joint, loc))
}

// ---- pogo joints

// Sets the rest length of a pogo joint.
pogo_joint_set_rest_length :: proc(world: ^World, joint: Pogo_Joint_Ref, length: f32, loc := #caller_location) {
	box3d.PogoJoint_SetRestLength(joint_id(world, joint, loc), length)
}

// The rest length of a pogo joint.
pogo_joint_rest_length :: proc(world: ^World, joint: Pogo_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PogoJoint_GetRestLength(joint_id(world, joint, loc))
}

// Sets the pogo spring's stiffness in Hertz.
pogo_joint_set_spring_hertz :: proc(world: ^World, joint: Pogo_Joint_Ref, hertz: f32, loc := #caller_location) {
	box3d.PogoJoint_SetSpringHertz(joint_id(world, joint, loc), hertz)
}

// The pogo joint's spring Hertz.
pogo_joint_spring_hertz :: proc(world: ^World, joint: Pogo_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PogoJoint_GetSpringHertz(joint_id(world, joint, loc))
}

// Sets the pogo spring's damping ratio (1: critical).
pogo_joint_set_spring_damping_ratio :: proc(
	world: ^World,
	joint: Pogo_Joint_Ref,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.PogoJoint_SetSpringDampingRatio(joint_id(world, joint, loc), damping_ratio)
}

// The pogo joint's spring damping ratio.
pogo_joint_spring_damping_ratio :: proc(world: ^World, joint: Pogo_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PogoJoint_GetSpringDampingRatio(joint_id(world, joint, loc))
}

// Sets the most force the pogo pulls with (0: it only pushes), usually in newtons.
pogo_joint_set_max_tension_force :: proc(world: ^World, joint: Pogo_Joint_Ref, force: f32, loc := #caller_location) {
	box3d.PogoJoint_SetMaxTensionForce(joint_id(world, joint, loc), force)
}

// The most force the pogo pulls with, usually in newtons.
pogo_joint_max_tension_force :: proc(world: ^World, joint: Pogo_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PogoJoint_GetMaxTensionForce(joint_id(world, joint, loc))
}

// Sets the most force the pogo pushes with, usually in newtons.
pogo_joint_set_max_compression_force :: proc(
	world: ^World,
	joint: Pogo_Joint_Ref,
	force: f32,
	loc := #caller_location,
) {
	box3d.PogoJoint_SetMaxCompressionForce(joint_id(world, joint, loc), force)
}

// The most force the pogo pushes with, usually in newtons.
pogo_joint_max_compression_force :: proc(world: ^World, joint: Pogo_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PogoJoint_GetMaxCompressionForce(joint_id(world, joint, loc))
}

// Sets the direction the pogo acts along (unit, world).
pogo_joint_set_normal :: proc(world: ^World, joint: Pogo_Joint_Ref, normal: [3]f32, loc := #caller_location) {
	box3d.PogoJoint_SetNormal(joint_id(world, joint, loc), transmute(box3d.Vec3)normal)
}

// The direction the pogo acts along (unit, world).
pogo_joint_normal :: proc(world: ^World, joint: Pogo_Joint_Ref, loc := #caller_location) -> [3]f32 {
	return transmute([3]f32)box3d.PogoJoint_GetNormal(joint_id(world, joint, loc))
}

// The pogo's current length.
pogo_joint_current_length :: proc(world: ^World, joint: Pogo_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PogoJoint_GetCurrentLength(joint_id(world, joint, loc))
}

// The pogo's current extension speed.
pogo_joint_current_speed :: proc(world: ^World, joint: Pogo_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PogoJoint_GetCurrentSpeed(joint_id(world, joint, loc))
}

// The pogo's last impulse.
pogo_joint_impulse :: proc(world: ^World, joint: Pogo_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PogoJoint_GetImpulse(joint_id(world, joint, loc))
}

// ---- prismatic joints

// Enables or disables the prismatic joint's spring.
prismatic_joint_enable_spring :: proc(
	world: ^World,
	joint: Prismatic_Joint_Ref,
	enable_spring: bool,
	loc := #caller_location,
) {
	box3d.PrismaticJoint_EnableSpring(joint_id(world, joint, loc), enable_spring)
}

// Whether the prismatic joint's spring is enabled.
prismatic_joint_is_spring_enabled :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.PrismaticJoint_IsSpringEnabled(joint_id(world, joint, loc))
}

// Sets the prismatic joint's spring stiffness in Hertz (usually under a quarter of the step rate).
prismatic_joint_set_spring_hertz :: proc(
	world: ^World,
	joint: Prismatic_Joint_Ref,
	hertz: f32,
	loc := #caller_location,
) {
	box3d.PrismaticJoint_SetSpringHertz(joint_id(world, joint, loc), hertz)
}

// The prismatic joint's stiffness in Hertz.
prismatic_joint_spring_hertz :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PrismaticJoint_GetSpringHertz(joint_id(world, joint, loc))
}

// Sets the prismatic joint's damping ratio (non-dimensional).
prismatic_joint_set_spring_damping_ratio :: proc(
	world: ^World,
	joint: Prismatic_Joint_Ref,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.PrismaticJoint_SetSpringDampingRatio(joint_id(world, joint, loc), damping_ratio)
}

// The prismatic joint's spring damping ratio (non-dimensional).
prismatic_joint_spring_damping_ratio :: proc(
	world: ^World,
	joint: Prismatic_Joint_Ref,
	loc := #caller_location,
) -> f32 {
	return box3d.PrismaticJoint_GetSpringDampingRatio(joint_id(world, joint, loc))
}

// Sets the prismatic joint's target translation. Usually in meters.
prismatic_joint_set_target_translation :: proc(
	world: ^World,
	joint: Prismatic_Joint_Ref,
	target_translation: f32,
	loc := #caller_location,
) {
	box3d.PrismaticJoint_SetTargetTranslation(joint_id(world, joint, loc), target_translation)
}

// The prismatic joint's target translation. Usually in meters.
prismatic_joint_target_translation :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PrismaticJoint_GetTargetTranslation(joint_id(world, joint, loc))
}

// Enables or disables the prismatic joint's limit.
prismatic_joint_enable_limit :: proc(
	world: ^World,
	joint: Prismatic_Joint_Ref,
	enable_limit: bool,
	loc := #caller_location,
) {
	box3d.PrismaticJoint_EnableLimit(joint_id(world, joint, loc), enable_limit)
}

// Whether the prismatic joint's limit is enabled.
prismatic_joint_is_limit_enabled :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.PrismaticJoint_IsLimitEnabled(joint_id(world, joint, loc))
}

// The prismatic joint's lower limit.
prismatic_joint_lower_limit :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PrismaticJoint_GetLowerLimit(joint_id(world, joint, loc))
}

// The prismatic joint's upper limit.
prismatic_joint_upper_limit :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PrismaticJoint_GetUpperLimit(joint_id(world, joint, loc))
}

// Sets the prismatic joint's limits.
prismatic_joint_set_limits :: proc(
	world: ^World,
	joint: Prismatic_Joint_Ref,
	lower: f32,
	upper: f32,
	loc := #caller_location,
) {
	box3d.PrismaticJoint_SetLimits(joint_id(world, joint, loc), lower, upper)
}

// Enables or disables the prismatic joint's motor.
prismatic_joint_enable_motor :: proc(
	world: ^World,
	joint: Prismatic_Joint_Ref,
	enable_motor: bool,
	loc := #caller_location,
) {
	box3d.PrismaticJoint_EnableMotor(joint_id(world, joint, loc), enable_motor)
}

// Whether the prismatic joint's motor is enabled.
prismatic_joint_is_motor_enabled :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.PrismaticJoint_IsMotorEnabled(joint_id(world, joint, loc))
}

// Sets the prismatic joint's motor speed, usually in meters per second.
prismatic_joint_set_motor_speed :: proc(
	world: ^World,
	joint: Prismatic_Joint_Ref,
	motor_speed: f32,
	loc := #caller_location,
) {
	box3d.PrismaticJoint_SetMotorSpeed(joint_id(world, joint, loc), motor_speed)
}

// The prismatic joint's motor speed, usually in meters per second.
prismatic_joint_motor_speed :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PrismaticJoint_GetMotorSpeed(joint_id(world, joint, loc))
}

// Sets the prismatic joint's maximum motor force, usually in newtons.
prismatic_joint_set_max_motor_force :: proc(
	world: ^World,
	joint: Prismatic_Joint_Ref,
	max_force: f32,
	loc := #caller_location,
) {
	box3d.PrismaticJoint_SetMaxMotorForce(joint_id(world, joint, loc), max_force)
}

// The prismatic joint's maximum motor force, usually in newtons.
prismatic_joint_max_motor_force :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PrismaticJoint_GetMaxMotorForce(joint_id(world, joint, loc))
}

// The prismatic joint's current motor force, usually in newtons.
prismatic_joint_motor_force :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PrismaticJoint_GetMotorForce(joint_id(world, joint, loc))
}

// The prismatic joint's current translation, usually in meters.
prismatic_joint_translation :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PrismaticJoint_GetTranslation(joint_id(world, joint, loc))
}

// The prismatic joint's current translation speed, usually in meters per second.
prismatic_joint_speed :: proc(world: ^World, joint: Prismatic_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.PrismaticJoint_GetSpeed(joint_id(world, joint, loc))
}

// ---- revolute joints

// Enables or disables the revolute joint's spring.
revolute_joint_enable_spring :: proc(
	world: ^World,
	joint: Revolute_Joint_Ref,
	enable_spring: bool,
	loc := #caller_location,
) {
	box3d.RevoluteJoint_EnableSpring(joint_id(world, joint, loc), enable_spring)
}

// Whether the revolute joint's angular spring is enabled.
revolute_joint_is_spring_enabled :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.RevoluteJoint_IsSpringEnabled(joint_id(world, joint, loc))
}

// Sets the revolute joint's spring stiffness in Hertz.
revolute_joint_set_spring_hertz :: proc(
	world: ^World,
	joint: Revolute_Joint_Ref,
	hertz: f32,
	loc := #caller_location,
) {
	box3d.RevoluteJoint_SetSpringHertz(joint_id(world, joint, loc), hertz)
}

// The revolute joint's spring stiffness in Hertz.
revolute_joint_spring_hertz :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.RevoluteJoint_GetSpringHertz(joint_id(world, joint, loc))
}

// Sets the revolute joint's spring damping ratio, non-dimensional.
revolute_joint_set_spring_damping_ratio :: proc(
	world: ^World,
	joint: Revolute_Joint_Ref,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.RevoluteJoint_SetSpringDampingRatio(joint_id(world, joint, loc), damping_ratio)
}

// The revolute joint's spring damping ratio, non-dimensional.
revolute_joint_spring_damping_ratio :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.RevoluteJoint_GetSpringDampingRatio(joint_id(world, joint, loc))
}

// Sets the revolute joint's target angle in radians.
revolute_joint_set_target_angle :: proc(
	world: ^World,
	joint: Revolute_Joint_Ref,
	target_radians: f32,
	loc := #caller_location,
) {
	box3d.RevoluteJoint_SetTargetAngle(joint_id(world, joint, loc), target_radians)
}

// The revolute joint's target angle in radians.
revolute_joint_target_angle :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.RevoluteJoint_GetTargetAngle(joint_id(world, joint, loc))
}

// The revolute joint's current angle in radians, relative to the reference state.
revolute_joint_angle :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.RevoluteJoint_GetAngle(joint_id(world, joint, loc))
}

// Enables or disables the revolute joint's limit.
revolute_joint_enable_limit :: proc(
	world: ^World,
	joint: Revolute_Joint_Ref,
	enable_limit: bool,
	loc := #caller_location,
) {
	box3d.RevoluteJoint_EnableLimit(joint_id(world, joint, loc), enable_limit)
}

// Whether the revolute joint's limit is enabled.
revolute_joint_is_limit_enabled :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.RevoluteJoint_IsLimitEnabled(joint_id(world, joint, loc))
}

// The revolute joint's lower limit in radians.
revolute_joint_lower_limit :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.RevoluteJoint_GetLowerLimit(joint_id(world, joint, loc))
}

// The revolute joint's upper limit in radians.
revolute_joint_upper_limit :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.RevoluteJoint_GetUpperLimit(joint_id(world, joint, loc))
}

// Sets the revolute joint's limits in radians.
revolute_joint_set_limits :: proc(
	world: ^World,
	joint: Revolute_Joint_Ref,
	lower_limit_radians: f32,
	upper_limit_radians: f32,
	loc := #caller_location,
) {
	box3d.RevoluteJoint_SetLimits(joint_id(world, joint, loc), lower_limit_radians, upper_limit_radians)
}

// Enables or disables the revolute joint's motor.
revolute_joint_enable_motor :: proc(
	world: ^World,
	joint: Revolute_Joint_Ref,
	enable_motor: bool,
	loc := #caller_location,
) {
	box3d.RevoluteJoint_EnableMotor(joint_id(world, joint, loc), enable_motor)
}

// Whether the revolute joint's motor is enabled.
revolute_joint_is_motor_enabled :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.RevoluteJoint_IsMotorEnabled(joint_id(world, joint, loc))
}

// Sets the revolute joint's motor speed in radians per second.
revolute_joint_set_motor_speed :: proc(
	world: ^World,
	joint: Revolute_Joint_Ref,
	motor_speed: f32,
	loc := #caller_location,
) {
	box3d.RevoluteJoint_SetMotorSpeed(joint_id(world, joint, loc), motor_speed)
}

// The revolute joint's motor speed in radians per second.
revolute_joint_motor_speed :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.RevoluteJoint_GetMotorSpeed(joint_id(world, joint, loc))
}

// The revolute joint's current motor torque, usually in newton-meters.
revolute_joint_motor_torque :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.RevoluteJoint_GetMotorTorque(joint_id(world, joint, loc))
}

// Sets the revolute joint's maximum motor torque, usually in newton-meters.
revolute_joint_set_max_motor_torque :: proc(
	world: ^World,
	joint: Revolute_Joint_Ref,
	max_torque: f32,
	loc := #caller_location,
) {
	box3d.RevoluteJoint_SetMaxMotorTorque(joint_id(world, joint, loc), max_torque)
}

// The revolute joint's maximum motor torque, usually in newton-meters.
revolute_joint_max_motor_torque :: proc(world: ^World, joint: Revolute_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.RevoluteJoint_GetMaxMotorTorque(joint_id(world, joint, loc))
}

// ---- spherical joints

// Enables or disables the spherical joint's cone limit.
spherical_joint_enable_cone_limit :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	enable_limit: bool,
	loc := #caller_location,
) {
	box3d.SphericalJoint_EnableConeLimit(joint_id(world, joint, loc), enable_limit)
}

// Whether the spherical joint's cone limit is enabled.
spherical_joint_is_cone_limit_enabled :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	loc := #caller_location,
) -> bool {
	return box3d.SphericalJoint_IsConeLimitEnabled(joint_id(world, joint, loc))
}

// The spherical joint's cone limit in radians.
spherical_joint_cone_limit :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.SphericalJoint_GetConeLimit(joint_id(world, joint, loc))
}

// Sets the spherical joint's cone limit angle in radians (0 to pi).
spherical_joint_set_cone_limit :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	angle_radians: f32,
	loc := #caller_location,
) {
	box3d.SphericalJoint_SetConeLimit(joint_id(world, joint, loc), angle_radians)
}

// The spherical joint's current cone angle in radians.
spherical_joint_cone_angle :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.SphericalJoint_GetConeAngle(joint_id(world, joint, loc))
}

// Enables or disables the spherical joint's twist limit.
spherical_joint_enable_twist_limit :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	enable_limit: bool,
	loc := #caller_location,
) {
	box3d.SphericalJoint_EnableTwistLimit(joint_id(world, joint, loc), enable_limit)
}

// Whether the spherical joint's twist limit is enabled.
spherical_joint_is_twist_limit_enabled :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	loc := #caller_location,
) -> bool {
	return box3d.SphericalJoint_IsTwistLimitEnabled(joint_id(world, joint, loc))
}

// The spherical joint's lower twist limit in radians.
spherical_joint_lower_twist_limit :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.SphericalJoint_GetLowerTwistLimit(joint_id(world, joint, loc))
}

// The spherical joint's upper twist limit in radians.
spherical_joint_upper_twist_limit :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.SphericalJoint_GetUpperTwistLimit(joint_id(world, joint, loc))
}

// Sets the spherical joint's twist limits in radians.
spherical_joint_set_twist_limits :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	lower_limit_radians: f32,
	upper_limit_radians: f32,
	loc := #caller_location,
) {
	box3d.SphericalJoint_SetTwistLimits(joint_id(world, joint, loc), lower_limit_radians, upper_limit_radians)
}

// The spherical joint's current twist angle in radians.
spherical_joint_twist_angle :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.SphericalJoint_GetTwistAngle(joint_id(world, joint, loc))
}

// Enables or disables the spherical joint's spring.
spherical_joint_enable_spring :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	enable_spring: bool,
	loc := #caller_location,
) {
	box3d.SphericalJoint_EnableSpring(joint_id(world, joint, loc), enable_spring)
}

// Whether the spherical joint's angular spring is enabled.
spherical_joint_is_spring_enabled :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.SphericalJoint_IsSpringEnabled(joint_id(world, joint, loc))
}

// Sets the spherical joint's spring stiffness in Hertz.
spherical_joint_set_spring_hertz :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	hertz: f32,
	loc := #caller_location,
) {
	box3d.SphericalJoint_SetSpringHertz(joint_id(world, joint, loc), hertz)
}

// The spherical joint's spring stiffness in Hertz.
spherical_joint_spring_hertz :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.SphericalJoint_GetSpringHertz(joint_id(world, joint, loc))
}

// Sets the spherical joint's spring damping ratio, non-dimensional.
spherical_joint_set_spring_damping_ratio :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.SphericalJoint_SetSpringDampingRatio(joint_id(world, joint, loc), damping_ratio)
}

// The spherical joint's spring damping ratio, non-dimensional.
spherical_joint_spring_damping_ratio :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	loc := #caller_location,
) -> f32 {
	return box3d.SphericalJoint_GetSpringDampingRatio(joint_id(world, joint, loc))
}

// Sets the spherical joint's spring target rotation.
spherical_joint_set_target_rotation :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	target_rotation: [4]f32,
	loc := #caller_location,
) {
	box3d.SphericalJoint_SetTargetRotation(joint_id(world, joint, loc), transmute(box3d.Quat)target_rotation)
}

// The spherical joint's spring target rotation.
spherical_joint_target_rotation :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> [4]f32 {
	return transmute([4]f32)box3d.SphericalJoint_GetTargetRotation(joint_id(world, joint, loc))
}

// Enables or disables the spherical joint's motor.
spherical_joint_enable_motor :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	enable_motor: bool,
	loc := #caller_location,
) {
	box3d.SphericalJoint_EnableMotor(joint_id(world, joint, loc), enable_motor)
}

// Whether the spherical joint's motor is enabled.
spherical_joint_is_motor_enabled :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.SphericalJoint_IsMotorEnabled(joint_id(world, joint, loc))
}

// Sets the spherical joint's motor velocity in radians per second: B's angular velocity minus A's, world frame.
spherical_joint_set_motor_velocity :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	motor_velocity: [3]f32,
	loc := #caller_location,
) {
	box3d.SphericalJoint_SetMotorVelocity(joint_id(world, joint, loc), transmute(box3d.Vec3)motor_velocity)
}

// The spherical joint's motor velocity in radians per second.
spherical_joint_motor_velocity :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> [3]f32 {
	return transmute([3]f32)box3d.SphericalJoint_GetMotorVelocity(joint_id(world, joint, loc))
}

// The spherical joint's current motor torque, usually in newton-meters.
spherical_joint_motor_torque :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> [3]f32 {
	return transmute([3]f32)box3d.SphericalJoint_GetMotorTorque(joint_id(world, joint, loc))
}

// Sets the spherical joint's maximum motor torque, usually in newton-meters.
spherical_joint_set_max_motor_torque :: proc(
	world: ^World,
	joint: Spherical_Joint_Ref,
	max_torque: f32,
	loc := #caller_location,
) {
	box3d.SphericalJoint_SetMaxMotorTorque(joint_id(world, joint, loc), max_torque)
}

// The spherical joint's maximum motor torque, usually in newton-meters.
spherical_joint_max_motor_torque :: proc(world: ^World, joint: Spherical_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.SphericalJoint_GetMaxMotorTorque(joint_id(world, joint, loc))
}

// ---- weld joints

// Sets the weld joint's linear stiffness in Hertz. 0 is rigid.
weld_joint_set_linear_hertz :: proc(world: ^World, joint: Weld_Joint_Ref, hertz: f32, loc := #caller_location) {
	box3d.WeldJoint_SetLinearHertz(joint_id(world, joint, loc), hertz)
}

// The weld joint's linear stiffness in Hertz.
weld_joint_linear_hertz :: proc(world: ^World, joint: Weld_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WeldJoint_GetLinearHertz(joint_id(world, joint, loc))
}

// Sets the weld joint's linear damping ratio (non-dimensional).
weld_joint_set_linear_damping_ratio :: proc(
	world: ^World,
	joint: Weld_Joint_Ref,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.WeldJoint_SetLinearDampingRatio(joint_id(world, joint, loc), damping_ratio)
}

// The weld joint's linear damping ratio (non-dimensional).
weld_joint_linear_damping_ratio :: proc(world: ^World, joint: Weld_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WeldJoint_GetLinearDampingRatio(joint_id(world, joint, loc))
}

// Sets the weld joint's angular stiffness in Hertz. 0 is rigid.
weld_joint_set_angular_hertz :: proc(world: ^World, joint: Weld_Joint_Ref, hertz: f32, loc := #caller_location) {
	box3d.WeldJoint_SetAngularHertz(joint_id(world, joint, loc), hertz)
}

// The weld joint's angular stiffness in Hertz.
weld_joint_angular_hertz :: proc(world: ^World, joint: Weld_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WeldJoint_GetAngularHertz(joint_id(world, joint, loc))
}

// Sets the weld joint's angular damping ratio, non-dimensional.
weld_joint_set_angular_damping_ratio :: proc(
	world: ^World,
	joint: Weld_Joint_Ref,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.WeldJoint_SetAngularDampingRatio(joint_id(world, joint, loc), damping_ratio)
}

// The weld joint's angular damping ratio, non-dimensional.
weld_joint_angular_damping_ratio :: proc(world: ^World, joint: Weld_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WeldJoint_GetAngularDampingRatio(joint_id(world, joint, loc))
}

// ---- wheel joints

// Enables or disables the wheel joint's suspension spring.
wheel_joint_enable_suspension :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	enable_spring: bool,
	loc := #caller_location,
) {
	box3d.WheelJoint_EnableSuspension(joint_id(world, joint, loc), enable_spring)
}

// Whether the wheel joint's suspension spring is enabled.
wheel_joint_is_suspension_enabled :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.WheelJoint_IsSuspensionEnabled(joint_id(world, joint, loc))
}

// Sets the wheel joint's suspension stiffness in Hertz.
wheel_joint_set_suspension_hertz :: proc(world: ^World, joint: Wheel_Joint_Ref, hertz: f32, loc := #caller_location) {
	box3d.WheelJoint_SetSuspensionHertz(joint_id(world, joint, loc), hertz)
}

// The wheel joint's suspension stiffness in Hertz.
wheel_joint_suspension_hertz :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetSuspensionHertz(joint_id(world, joint, loc))
}

// Sets the wheel joint's suspension damping ratio, non-dimensional.
wheel_joint_set_suspension_damping_ratio :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.WheelJoint_SetSuspensionDampingRatio(joint_id(world, joint, loc), damping_ratio)
}

// The wheel joint's suspension damping ratio, non-dimensional.
wheel_joint_suspension_damping_ratio :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetSuspensionDampingRatio(joint_id(world, joint, loc))
}

// Enables or disables the wheel joint's suspension limit.
wheel_joint_enable_suspension_limit :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	enable_limit: bool,
	loc := #caller_location,
) {
	box3d.WheelJoint_EnableSuspensionLimit(joint_id(world, joint, loc), enable_limit)
}

// Whether the wheel joint's suspension limit is enabled.
wheel_joint_is_suspension_limit_enabled :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	loc := #caller_location,
) -> bool {
	return box3d.WheelJoint_IsSuspensionLimitEnabled(joint_id(world, joint, loc))
}

// The wheel joint's lower suspension limit.
wheel_joint_lower_suspension_limit :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetLowerSuspensionLimit(joint_id(world, joint, loc))
}

// The wheel joint's upper suspension limit.
wheel_joint_upper_suspension_limit :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetUpperSuspensionLimit(joint_id(world, joint, loc))
}

// Sets the wheel joint's suspension limits.
wheel_joint_set_suspension_limits :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	lower: f32,
	upper: f32,
	loc := #caller_location,
) {
	box3d.WheelJoint_SetSuspensionLimits(joint_id(world, joint, loc), lower, upper)
}

// Enables or disables the wheel joint's spin motor.
wheel_joint_enable_spin_motor :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	enable_motor: bool,
	loc := #caller_location,
) {
	box3d.WheelJoint_EnableSpinMotor(joint_id(world, joint, loc), enable_motor)
}

// Whether the wheel joint's spin motor is enabled.
wheel_joint_is_spin_motor_enabled :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.WheelJoint_IsSpinMotorEnabled(joint_id(world, joint, loc))
}

// Sets the wheel joint's spin motor speed in radians per second.
wheel_joint_set_spin_motor_speed :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	motor_speed: f32,
	loc := #caller_location,
) {
	box3d.WheelJoint_SetSpinMotorSpeed(joint_id(world, joint, loc), motor_speed)
}

// The wheel joint's spin motor speed in radians per second.
wheel_joint_spin_motor_speed :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetSpinMotorSpeed(joint_id(world, joint, loc))
}

// Sets the wheel joint's maximum spin motor torque, usually in newton-meters.
wheel_joint_set_max_spin_torque :: proc(world: ^World, joint: Wheel_Joint_Ref, torque: f32, loc := #caller_location) {
	box3d.WheelJoint_SetMaxSpinTorque(joint_id(world, joint, loc), torque)
}

// The wheel joint's maximum spin motor torque, usually in newton-meters.
wheel_joint_max_spin_torque :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetMaxSpinTorque(joint_id(world, joint, loc))
}

// The wheel joint's current spin speed in radians per second.
wheel_joint_spin_speed :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetSpinSpeed(joint_id(world, joint, loc))
}

// The wheel joint's current spin motor torque, usually in newton-meters.
wheel_joint_spin_torque :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetSpinTorque(joint_id(world, joint, loc))
}

// Enables or disables steering (the wheel rotating about the suspension axis).
wheel_joint_enable_steering :: proc(world: ^World, joint: Wheel_Joint_Ref, enable: bool, loc := #caller_location) {
	box3d.WheelJoint_EnableSteering(joint_id(world, joint, loc), enable)
}

// Whether the wheel can steer.
wheel_joint_is_steering_enabled :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.WheelJoint_IsSteeringEnabled(joint_id(world, joint, loc))
}

// Sets the wheel joint's steering stiffness in Hertz.
wheel_joint_set_steering_hertz :: proc(world: ^World, joint: Wheel_Joint_Ref, hertz: f32, loc := #caller_location) {
	box3d.WheelJoint_SetSteeringHertz(joint_id(world, joint, loc), hertz)
}

// The wheel joint's steering stiffness in Hertz.
wheel_joint_steering_hertz :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetSteeringHertz(joint_id(world, joint, loc))
}

// Sets the wheel joint's steering damping ratio, non-dimensional.
wheel_joint_set_steering_damping_ratio :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	damping_ratio: f32,
	loc := #caller_location,
) {
	box3d.WheelJoint_SetSteeringDampingRatio(joint_id(world, joint, loc), damping_ratio)
}

// The wheel joint's steering damping ratio, non-dimensional.
wheel_joint_steering_damping_ratio :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetSteeringDampingRatio(joint_id(world, joint, loc))
}

// Sets the wheel joint's maximum steering torque in N·m.
wheel_joint_set_max_steering_torque :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	max_torque: f32,
	loc := #caller_location,
) {
	box3d.WheelJoint_SetMaxSteeringTorque(joint_id(world, joint, loc), max_torque)
}

// The wheel joint's maximum steering torque in N·m.
wheel_joint_max_steering_torque :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetMaxSteeringTorque(joint_id(world, joint, loc))
}

// Enables or disables the wheel joint's steering limit.
wheel_joint_enable_steering_limit :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	enable: bool,
	loc := #caller_location,
) {
	box3d.WheelJoint_EnableSteeringLimit(joint_id(world, joint, loc), enable)
}

// Whether the wheel joint's steering limit is enabled.
wheel_joint_is_steering_limit_enabled :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> bool {
	return box3d.WheelJoint_IsSteeringLimitEnabled(joint_id(world, joint, loc))
}

// The wheel joint's lower steering limit in radians.
wheel_joint_lower_steering_limit :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetLowerSteeringLimit(joint_id(world, joint, loc))
}

// The wheel joint's upper steering limit in radians.
wheel_joint_upper_steering_limit :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetUpperSteeringLimit(joint_id(world, joint, loc))
}

// Sets the wheel joint's steering limits in radians.
wheel_joint_set_steering_limits :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	lower_radians: f32,
	upper_radians: f32,
	loc := #caller_location,
) {
	box3d.WheelJoint_SetSteeringLimits(joint_id(world, joint, loc), lower_radians, upper_radians)
}

// Sets the wheel joint's target steering angle in radians.
wheel_joint_set_target_steering_angle :: proc(
	world: ^World,
	joint: Wheel_Joint_Ref,
	radians: f32,
	loc := #caller_location,
) {
	box3d.WheelJoint_SetTargetSteeringAngle(joint_id(world, joint, loc), radians)
}

// The wheel joint's target steering angle in radians.
wheel_joint_target_steering_angle :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetTargetSteeringAngle(joint_id(world, joint, loc))
}

// The wheel joint's current steering angle in radians.
wheel_joint_steering_angle :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetSteeringAngle(joint_id(world, joint, loc))
}

// The wheel joint's current steering torque in N·m.
wheel_joint_steering_torque :: proc(world: ^World, joint: Wheel_Joint_Ref, loc := #caller_location) -> f32 {
	return box3d.WheelJoint_GetSteeringTorque(joint_id(world, joint, loc))
}

// Destroys the joint (if it is still alive: destroying a body destroys its joints) and clears the ref. A joint that
// kept its bodies from colliding leaves them overlapping at rest uncollided until one moves (stop_ignoring re-pairs).
destroy_joint :: proc(world: ^World, joint: ^Joint_Ref) {
	if joint_valid(world, joint^) {
		box3d.DestroyJoint(joint_id(world, joint^), true)
	}
	joint^ = {}
}

// Box3D's default motor joint definition (drives B's pose relative to A).
default_motor_joint_def :: proc() -> Motor_Joint_Def {
	return transmute(Motor_Joint_Def)box3d.DefaultMotorJointDef()
}

// Box3D's default mover joint definition (drives B to a target velocity relative to A).
default_mover_joint_def :: proc() -> Mover_Joint_Def {
	return transmute(Mover_Joint_Def)box3d.DefaultMoverJointDef()
}

// Box3D's default pogo joint definition (a spring along a normal).
default_pogo_joint_def :: proc() -> Pogo_Joint_Def {
	return transmute(Pogo_Joint_Def)box3d.DefaultPogoJointDef()
}
