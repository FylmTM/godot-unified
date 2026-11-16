// The joint procs b3.odin doesn't have (src/b3/SPEC.md): the generic Joint_* procs and every per-type proc, creation
// and default definition of Box3D's joints, by its names. Out-pointer getters return several values.
package b3

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

// The joint's type.
joint_get_type :: proc(joint_id: Joint_Id) -> Joint_Type {
	return Joint_Type(box3d.Joint_GetType(joint_id))
}

// The joint's second body.
joint_get_body_b :: proc(joint_id: Joint_Id) -> Body_Id {
	return box3d.Joint_GetBodyB(joint_id)
}

// The joint's frame on body A (in A's frame).
joint_get_local_frame_a :: proc(joint_id: Joint_Id) -> Transform {
	return transmute(Transform)box3d.Joint_GetLocalFrameA(joint_id)
}

// The joint's frame on body B (in B's frame).
joint_get_local_frame_b :: proc(joint_id: Joint_Id) -> Transform {
	return transmute(Transform)box3d.Joint_GetLocalFrameB(joint_id)
}

// Sets whether the joint's two bodies collide with each other.
joint_set_collide_connected :: proc(joint_id: Joint_Id, should_collide: bool) {
	box3d.Joint_SetCollideConnected(joint_id, should_collide)
}

// Whether the joint's two bodies collide with each other.
joint_get_collide_connected :: proc(joint_id: Joint_Id) -> bool {
	return box3d.Joint_GetCollideConnected(joint_id)
}

// Wakes the joint's bodies.
joint_wake_bodies :: proc(joint_id: Joint_Id) {
	box3d.Joint_WakeBodies(joint_id)
}

// Whether the joint is awake (an attached body is awake).
joint_is_awake :: proc(joint_id: Joint_Id) -> bool {
	return box3d.Joint_IsAwake(joint_id)
}

// The current constraint force for this joint.
joint_get_constraint_force :: proc(joint_id: Joint_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Joint_GetConstraintForce(joint_id)
}

// The current constraint torque for this joint.
joint_get_constraint_torque :: proc(joint_id: Joint_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Joint_GetConstraintTorque(joint_id)
}

// The joint's current linear error (m), not counting the movement it allows.
joint_get_linear_separation :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.Joint_GetLinearSeparation(joint_id)
}

// The joint's current angular error (radians), not counting the movement it allows.
joint_get_angular_separation :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.Joint_GetAngularSeparation(joint_id)
}

// Sets the joint's constraint stiffness (Hz) and damping ratio (1: critical). Advanced.
joint_set_constraint_tuning :: proc(joint_id: Joint_Id, hertz: f32, damping_ratio: f32) {
	box3d.Joint_SetConstraintTuning(joint_id, hertz, damping_ratio)
}

// The joint's constraint stiffness (Hz) and damping ratio. Advanced.
joint_get_constraint_tuning :: proc(joint_id: Joint_Id) -> (hertz: f32, damping_ratio: f32) {
	box3d.Joint_GetConstraintTuning(joint_id, &hertz, &damping_ratio)
	return
}

// Sets the force (N) above which the joint reports a joint event.
joint_set_force_threshold :: proc(joint_id: Joint_Id, threshold: f32) {
	box3d.Joint_SetForceThreshold(joint_id, threshold)
}

// The force (N) above which the joint reports a joint event.
joint_get_force_threshold :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.Joint_GetForceThreshold(joint_id)
}

// Sets the torque (N·m) above which the joint reports a joint event.
joint_set_torque_threshold :: proc(joint_id: Joint_Id, threshold: f32) {
	box3d.Joint_SetTorqueThreshold(joint_id, threshold)
}

// The torque (N·m) above which the joint reports a joint event.
joint_get_torque_threshold :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.Joint_GetTorqueThreshold(joint_id)
}

// Creates a parallel joint between the def's two bodies.
create_parallel_joint :: proc(world_id: World_Id, def: ^Parallel_Joint_Def) -> Joint_Id {
	return box3d.CreateParallelJoint(world_id, (^box3d.ParallelJointDef)(def))
}

// Sets the parallel joint's spring stiffness in Hertz.
parallel_joint_set_spring_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.ParallelJoint_SetSpringHertz(joint_id, hertz)
}

// Sets the parallel joint's spring damping ratio, non-dimensional.
parallel_joint_set_spring_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.ParallelJoint_SetSpringDampingRatio(joint_id, damping_ratio)
}

// The parallel joint's spring Hertz.
parallel_joint_get_spring_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.ParallelJoint_GetSpringHertz(joint_id)
}

// The parallel joint's spring damping ratio.
parallel_joint_get_spring_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.ParallelJoint_GetSpringDampingRatio(joint_id)
}

// Sets the parallel joint's maximum spring torque, usually in newton-meters.
parallel_joint_set_max_torque :: proc(joint_id: Joint_Id, max_torque: f32) {
	box3d.ParallelJoint_SetMaxTorque(joint_id, max_torque)
}

// The parallel joint's maximum spring torque, usually in newton-meters.
parallel_joint_get_max_torque :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.ParallelJoint_GetMaxTorque(joint_id)
}

// Creates a distance joint between the def's two bodies.
create_distance_joint :: proc(world_id: World_Id, def: ^Distance_Joint_Def) -> Joint_Id {
	return box3d.CreateDistanceJoint(world_id, (^box3d.DistanceJointDef)(def))
}

// Sets the rest length of a distance joint.
distance_joint_set_length :: proc(joint_id: Joint_Id, length: f32) {
	box3d.DistanceJoint_SetLength(joint_id, length)
}

// The rest length of a distance joint.
distance_joint_get_length :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.DistanceJoint_GetLength(joint_id)
}

// Enables or disables the distance joint's spring (disabled: the joint is rigid).
distance_joint_enable_spring :: proc(joint_id: Joint_Id, enable_spring: bool) {
	box3d.DistanceJoint_EnableSpring(joint_id, enable_spring)
}

// Whether the distance joint's spring is enabled.
distance_joint_is_spring_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.DistanceJoint_IsSpringEnabled(joint_id)
}

// Sets the distance joint's force range for the spring.
distance_joint_set_spring_force_range :: proc(joint_id: Joint_Id, lower_force: f32, upper_force: f32) {
	box3d.DistanceJoint_SetSpringForceRange(joint_id, lower_force, upper_force)
}

// The distance joint's force range for the spring.
distance_joint_get_spring_force_range :: proc(joint_id: Joint_Id) -> (lower_force: f32, upper_force: f32) {
	box3d.DistanceJoint_GetSpringForceRange(joint_id, &lower_force, &upper_force)
	return
}

// Sets the distance joint's spring stiffness in Hertz.
distance_joint_set_spring_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.DistanceJoint_SetSpringHertz(joint_id, hertz)
}

// Sets the distance joint's spring damping ratio, non-dimensional.
distance_joint_set_spring_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.DistanceJoint_SetSpringDampingRatio(joint_id, damping_ratio)
}

// The distance joint's spring Hertz.
distance_joint_get_spring_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.DistanceJoint_GetSpringHertz(joint_id)
}

// The distance joint's spring damping ratio.
distance_joint_get_spring_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.DistanceJoint_GetSpringDampingRatio(joint_id)
}

// Enables or disables the distance joint's length limit (it acts only with the spring enabled; a rigid joint ignores it).
distance_joint_enable_limit :: proc(joint_id: Joint_Id, enable_limit: bool) {
	box3d.DistanceJoint_EnableLimit(joint_id, enable_limit)
}

// Whether the distance joint's limit is enabled.
distance_joint_is_limit_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.DistanceJoint_IsLimitEnabled(joint_id)
}

// Sets the minimum and maximum length parameters of a distance joint.
distance_joint_set_length_range :: proc(joint_id: Joint_Id, min_length: f32, max_length: f32) {
	box3d.DistanceJoint_SetLengthRange(joint_id, min_length, max_length)
}

// The distance joint's minimum length.
distance_joint_get_min_length :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.DistanceJoint_GetMinLength(joint_id)
}

// The distance joint's maximum length.
distance_joint_get_max_length :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.DistanceJoint_GetMaxLength(joint_id)
}

// The current length of a distance joint.
distance_joint_get_current_length :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.DistanceJoint_GetCurrentLength(joint_id)
}

// Enables or disables the distance joint's motor.
distance_joint_enable_motor :: proc(joint_id: Joint_Id, enable_motor: bool) {
	box3d.DistanceJoint_EnableMotor(joint_id, enable_motor)
}

// Whether the distance joint's motor is enabled.
distance_joint_is_motor_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.DistanceJoint_IsMotorEnabled(joint_id)
}

// Sets the distance joint's motor speed, usually in meters per second.
distance_joint_set_motor_speed :: proc(joint_id: Joint_Id, motor_speed: f32) {
	box3d.DistanceJoint_SetMotorSpeed(joint_id, motor_speed)
}

// The distance joint's motor speed, usually in meters per second.
distance_joint_get_motor_speed :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.DistanceJoint_GetMotorSpeed(joint_id)
}

// Sets the distance joint's maximum motor force, usually in newtons.
distance_joint_set_max_motor_force :: proc(joint_id: Joint_Id, force: f32) {
	box3d.DistanceJoint_SetMaxMotorForce(joint_id, force)
}

// The distance joint's maximum motor force, usually in newtons.
distance_joint_get_max_motor_force :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.DistanceJoint_GetMaxMotorForce(joint_id)
}

// The distance joint's current motor force, usually in newtons.
distance_joint_get_motor_force :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.DistanceJoint_GetMotorForce(joint_id)
}

// Sets the motor joint's desired relative linear velocity in meters per second.
motor_joint_set_linear_velocity :: proc(joint_id: Joint_Id, velocity: [3]f32) {
	box3d.MotorJoint_SetLinearVelocity(joint_id, transmute(box3d.Vec3)velocity)
}

// The motor joint's desired relative linear velocity in meters per second.
motor_joint_get_linear_velocity :: proc(joint_id: Joint_Id) -> [3]f32 {
	return transmute([3]f32)box3d.MotorJoint_GetLinearVelocity(joint_id)
}

// Sets the motor joint's desired relative angular velocity in radians per second.
motor_joint_set_angular_velocity :: proc(joint_id: Joint_Id, velocity: [3]f32) {
	box3d.MotorJoint_SetAngularVelocity(joint_id, transmute(box3d.Vec3)velocity)
}

// The motor joint's desired relative angular velocity in radians per second.
motor_joint_get_angular_velocity :: proc(joint_id: Joint_Id) -> [3]f32 {
	return transmute([3]f32)box3d.MotorJoint_GetAngularVelocity(joint_id)
}

// Sets the motor joint's maximum force, usually in newtons.
motor_joint_set_max_velocity_force :: proc(joint_id: Joint_Id, max_force: f32) {
	box3d.MotorJoint_SetMaxVelocityForce(joint_id, max_force)
}

// The motor joint's maximum force, usually in newtons.
motor_joint_get_max_velocity_force :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.MotorJoint_GetMaxVelocityForce(joint_id)
}

// Sets the motor joint's maximum torque, usually in newton-meters.
motor_joint_set_max_velocity_torque :: proc(joint_id: Joint_Id, max_torque: f32) {
	box3d.MotorJoint_SetMaxVelocityTorque(joint_id, max_torque)
}

// The motor joint's maximum torque, usually in newton-meters.
motor_joint_get_max_velocity_torque :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.MotorJoint_GetMaxVelocityTorque(joint_id)
}

// Sets the motor joint's spring linear hertz stiffness.
motor_joint_set_linear_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.MotorJoint_SetLinearHertz(joint_id, hertz)
}

// The motor joint's spring linear hertz stiffness.
motor_joint_get_linear_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.MotorJoint_GetLinearHertz(joint_id)
}

// Sets the motor joint's linear spring damping ratio (1: critical).
motor_joint_set_linear_damping_ratio :: proc(joint_id: Joint_Id, damping: f32) {
	box3d.MotorJoint_SetLinearDampingRatio(joint_id, damping)
}

// The motor joint's spring linear damping ratio.
motor_joint_get_linear_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.MotorJoint_GetLinearDampingRatio(joint_id)
}

// Sets the motor joint's spring angular hertz stiffness.
motor_joint_set_angular_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.MotorJoint_SetAngularHertz(joint_id, hertz)
}

// The motor joint's spring angular hertz stiffness.
motor_joint_get_angular_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.MotorJoint_GetAngularHertz(joint_id)
}

// Sets the motor joint's angular spring damping ratio (1: critical).
motor_joint_set_angular_damping_ratio :: proc(joint_id: Joint_Id, damping: f32) {
	box3d.MotorJoint_SetAngularDampingRatio(joint_id, damping)
}

// The motor joint's spring angular damping ratio.
motor_joint_get_angular_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.MotorJoint_GetAngularDampingRatio(joint_id)
}

// Sets the motor joint's maximum spring force in newtons.
motor_joint_set_max_spring_force :: proc(joint_id: Joint_Id, max_force: f32) {
	box3d.MotorJoint_SetMaxSpringForce(joint_id, max_force)
}

// The motor joint's maximum spring force in newtons.
motor_joint_get_max_spring_force :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.MotorJoint_GetMaxSpringForce(joint_id)
}

// Sets the motor joint's maximum spring torque in N·m.
motor_joint_set_max_spring_torque :: proc(joint_id: Joint_Id, max_torque: f32) {
	box3d.MotorJoint_SetMaxSpringTorque(joint_id, max_torque)
}

// The motor joint's maximum spring torque in N·m.
motor_joint_get_max_spring_torque :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.MotorJoint_GetMaxSpringTorque(joint_id)
}

// The mover joint's target velocity of B relative to A, usually in meters per second.
mover_joint_get_linear_velocity :: proc(joint_id: Joint_Id) -> [3]f32 {
	return transmute([3]f32)box3d.MoverJoint_GetLinearVelocity(joint_id)
}

// The force cap of the mover joint's velocity drive, usually in newtons.
mover_joint_get_max_velocity_force :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.MoverJoint_GetMaxVelocityForce(joint_id)
}

// Sets the rest length of a pogo joint.
pogo_joint_set_rest_length :: proc(joint_id: Joint_Id, length: f32) {
	box3d.PogoJoint_SetRestLength(joint_id, length)
}

// The rest length of a pogo joint.
pogo_joint_get_rest_length :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PogoJoint_GetRestLength(joint_id)
}

// The pogo joint's spring Hertz.
pogo_joint_get_spring_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PogoJoint_GetSpringHertz(joint_id)
}

// The pogo joint's spring damping ratio.
pogo_joint_get_spring_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PogoJoint_GetSpringDampingRatio(joint_id)
}

// The most force the pogo pulls with, usually in newtons.
pogo_joint_get_max_tension_force :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PogoJoint_GetMaxTensionForce(joint_id)
}

// The most force the pogo pushes with, usually in newtons.
pogo_joint_get_max_compression_force :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PogoJoint_GetMaxCompressionForce(joint_id)
}

// The direction the pogo acts along (unit, world).
pogo_joint_get_normal :: proc(joint_id: Joint_Id) -> [3]f32 {
	return transmute([3]f32)box3d.PogoJoint_GetNormal(joint_id)
}

// The pogo's current length.
pogo_joint_get_current_length :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PogoJoint_GetCurrentLength(joint_id)
}

// Creates a filter joint between the def's two bodies.
create_filter_joint :: proc(world_id: World_Id, def: ^Filter_Joint_Def) -> Joint_Id {
	return box3d.CreateFilterJoint(world_id, (^box3d.FilterJointDef)(def))
}

// Creates a prismatic joint between the def's two bodies.
create_prismatic_joint :: proc(world_id: World_Id, def: ^Prismatic_Joint_Def) -> Joint_Id {
	return box3d.CreatePrismaticJoint(world_id, (^box3d.PrismaticJointDef)(def))
}

// Enables or disables the prismatic joint's spring.
prismatic_joint_enable_spring :: proc(joint_id: Joint_Id, enable_spring: bool) {
	box3d.PrismaticJoint_EnableSpring(joint_id, enable_spring)
}

// Whether the prismatic joint's spring is enabled.
prismatic_joint_is_spring_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.PrismaticJoint_IsSpringEnabled(joint_id)
}

// Sets the prismatic joint's spring stiffness in Hertz (usually under a quarter of the step rate).
prismatic_joint_set_spring_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.PrismaticJoint_SetSpringHertz(joint_id, hertz)
}

// The prismatic joint's stiffness in Hertz.
prismatic_joint_get_spring_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PrismaticJoint_GetSpringHertz(joint_id)
}

// Sets the prismatic joint's damping ratio (non-dimensional).
prismatic_joint_set_spring_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.PrismaticJoint_SetSpringDampingRatio(joint_id, damping_ratio)
}

// The prismatic joint's spring damping ratio (non-dimensional).
prismatic_joint_get_spring_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PrismaticJoint_GetSpringDampingRatio(joint_id)
}

// Sets the prismatic joint's target translation. Usually in meters.
prismatic_joint_set_target_translation :: proc(joint_id: Joint_Id, target_translation: f32) {
	box3d.PrismaticJoint_SetTargetTranslation(joint_id, target_translation)
}

// The prismatic joint's target translation. Usually in meters.
prismatic_joint_get_target_translation :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PrismaticJoint_GetTargetTranslation(joint_id)
}

// Enables or disables the prismatic joint's limit.
prismatic_joint_enable_limit :: proc(joint_id: Joint_Id, enable_limit: bool) {
	box3d.PrismaticJoint_EnableLimit(joint_id, enable_limit)
}

// Whether the prismatic joint's limit is enabled.
prismatic_joint_is_limit_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.PrismaticJoint_IsLimitEnabled(joint_id)
}

// The prismatic joint's lower limit.
prismatic_joint_get_lower_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PrismaticJoint_GetLowerLimit(joint_id)
}

// The prismatic joint's upper limit.
prismatic_joint_get_upper_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PrismaticJoint_GetUpperLimit(joint_id)
}

// Sets the prismatic joint's limits.
prismatic_joint_set_limits :: proc(joint_id: Joint_Id, lower: f32, upper: f32) {
	box3d.PrismaticJoint_SetLimits(joint_id, lower, upper)
}

// Enables or disables the prismatic joint's motor.
prismatic_joint_enable_motor :: proc(joint_id: Joint_Id, enable_motor: bool) {
	box3d.PrismaticJoint_EnableMotor(joint_id, enable_motor)
}

// Whether the prismatic joint's motor is enabled.
prismatic_joint_is_motor_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.PrismaticJoint_IsMotorEnabled(joint_id)
}

// Sets the prismatic joint's motor speed, usually in meters per second.
prismatic_joint_set_motor_speed :: proc(joint_id: Joint_Id, motor_speed: f32) {
	box3d.PrismaticJoint_SetMotorSpeed(joint_id, motor_speed)
}

// The prismatic joint's motor speed, usually in meters per second.
prismatic_joint_get_motor_speed :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PrismaticJoint_GetMotorSpeed(joint_id)
}

// Sets the prismatic joint's maximum motor force, usually in newtons.
prismatic_joint_set_max_motor_force :: proc(joint_id: Joint_Id, max_force: f32) {
	box3d.PrismaticJoint_SetMaxMotorForce(joint_id, max_force)
}

// The prismatic joint's maximum motor force, usually in newtons.
prismatic_joint_get_max_motor_force :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PrismaticJoint_GetMaxMotorForce(joint_id)
}

// The prismatic joint's current motor force, usually in newtons.
prismatic_joint_get_motor_force :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PrismaticJoint_GetMotorForce(joint_id)
}

// The prismatic joint's current translation, usually in meters.
prismatic_joint_get_translation :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PrismaticJoint_GetTranslation(joint_id)
}

// The prismatic joint's current translation speed, usually in meters per second.
prismatic_joint_get_speed :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PrismaticJoint_GetSpeed(joint_id)
}

// Creates a revolute joint between the def's two bodies.
create_revolute_joint :: proc(world_id: World_Id, def: ^Revolute_Joint_Def) -> Joint_Id {
	return box3d.CreateRevoluteJoint(world_id, (^box3d.RevoluteJointDef)(def))
}

// Enables or disables the revolute joint's spring.
revolute_joint_enable_spring :: proc(joint_id: Joint_Id, enable_spring: bool) {
	box3d.RevoluteJoint_EnableSpring(joint_id, enable_spring)
}

// Whether the revolute joint's angular spring is enabled.
revolute_joint_is_spring_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.RevoluteJoint_IsSpringEnabled(joint_id)
}

// Sets the revolute joint's spring stiffness in Hertz.
revolute_joint_set_spring_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.RevoluteJoint_SetSpringHertz(joint_id, hertz)
}

// The revolute joint's spring stiffness in Hertz.
revolute_joint_get_spring_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.RevoluteJoint_GetSpringHertz(joint_id)
}

// Sets the revolute joint's spring damping ratio, non-dimensional.
revolute_joint_set_spring_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.RevoluteJoint_SetSpringDampingRatio(joint_id, damping_ratio)
}

// The revolute joint's spring damping ratio, non-dimensional.
revolute_joint_get_spring_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.RevoluteJoint_GetSpringDampingRatio(joint_id)
}

// Sets the revolute joint's target angle in radians.
revolute_joint_set_target_angle :: proc(joint_id: Joint_Id, target_radians: f32) {
	box3d.RevoluteJoint_SetTargetAngle(joint_id, target_radians)
}

// The revolute joint's target angle in radians.
revolute_joint_get_target_angle :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.RevoluteJoint_GetTargetAngle(joint_id)
}

// The revolute joint's current angle in radians, relative to the reference state.
revolute_joint_get_angle :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.RevoluteJoint_GetAngle(joint_id)
}

// Enables or disables the revolute joint's limit.
revolute_joint_enable_limit :: proc(joint_id: Joint_Id, enable_limit: bool) {
	box3d.RevoluteJoint_EnableLimit(joint_id, enable_limit)
}

// Whether the revolute joint's limit is enabled.
revolute_joint_is_limit_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.RevoluteJoint_IsLimitEnabled(joint_id)
}

// The revolute joint's lower limit in radians.
revolute_joint_get_lower_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.RevoluteJoint_GetLowerLimit(joint_id)
}

// The revolute joint's upper limit in radians.
revolute_joint_get_upper_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.RevoluteJoint_GetUpperLimit(joint_id)
}

// Sets the revolute joint's limits in radians.
revolute_joint_set_limits :: proc(joint_id: Joint_Id, lower_limit_radians: f32, upper_limit_radians: f32) {
	box3d.RevoluteJoint_SetLimits(joint_id, lower_limit_radians, upper_limit_radians)
}

// Enables or disables the revolute joint's motor.
revolute_joint_enable_motor :: proc(joint_id: Joint_Id, enable_motor: bool) {
	box3d.RevoluteJoint_EnableMotor(joint_id, enable_motor)
}

// Whether the revolute joint's motor is enabled.
revolute_joint_is_motor_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.RevoluteJoint_IsMotorEnabled(joint_id)
}

// Sets the revolute joint's motor speed in radians per second.
revolute_joint_set_motor_speed :: proc(joint_id: Joint_Id, motor_speed: f32) {
	box3d.RevoluteJoint_SetMotorSpeed(joint_id, motor_speed)
}

// The revolute joint's motor speed in radians per second.
revolute_joint_get_motor_speed :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.RevoluteJoint_GetMotorSpeed(joint_id)
}

// The revolute joint's current motor torque, usually in newton-meters.
revolute_joint_get_motor_torque :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.RevoluteJoint_GetMotorTorque(joint_id)
}

// Sets the revolute joint's maximum motor torque, usually in newton-meters.
revolute_joint_set_max_motor_torque :: proc(joint_id: Joint_Id, max_torque: f32) {
	box3d.RevoluteJoint_SetMaxMotorTorque(joint_id, max_torque)
}

// The revolute joint's maximum motor torque, usually in newton-meters.
revolute_joint_get_max_motor_torque :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.RevoluteJoint_GetMaxMotorTorque(joint_id)
}

// Creates a spherical joint between the def's two bodies.
create_spherical_joint :: proc(world_id: World_Id, def: ^Spherical_Joint_Def) -> Joint_Id {
	return box3d.CreateSphericalJoint(world_id, (^box3d.SphericalJointDef)(def))
}

// Enables or disables the spherical joint's cone limit.
spherical_joint_enable_cone_limit :: proc(joint_id: Joint_Id, enable_limit: bool) {
	box3d.SphericalJoint_EnableConeLimit(joint_id, enable_limit)
}

// Whether the spherical joint's cone limit is enabled.
spherical_joint_is_cone_limit_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.SphericalJoint_IsConeLimitEnabled(joint_id)
}

// The spherical joint's cone limit in radians.
spherical_joint_get_cone_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.SphericalJoint_GetConeLimit(joint_id)
}

// Sets the spherical joint's cone limit angle in radians (0 to pi).
spherical_joint_set_cone_limit :: proc(joint_id: Joint_Id, angle_radians: f32) {
	box3d.SphericalJoint_SetConeLimit(joint_id, angle_radians)
}

// The spherical joint's current cone angle in radians.
spherical_joint_get_cone_angle :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.SphericalJoint_GetConeAngle(joint_id)
}

// Enables or disables the spherical joint's twist limit.
spherical_joint_enable_twist_limit :: proc(joint_id: Joint_Id, enable_limit: bool) {
	box3d.SphericalJoint_EnableTwistLimit(joint_id, enable_limit)
}

// Whether the spherical joint's twist limit is enabled.
spherical_joint_is_twist_limit_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.SphericalJoint_IsTwistLimitEnabled(joint_id)
}

// The spherical joint's lower twist limit in radians.
spherical_joint_get_lower_twist_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.SphericalJoint_GetLowerTwistLimit(joint_id)
}

// The spherical joint's upper twist limit in radians.
spherical_joint_get_upper_twist_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.SphericalJoint_GetUpperTwistLimit(joint_id)
}

// Sets the spherical joint's twist limits in radians.
spherical_joint_set_twist_limits :: proc(joint_id: Joint_Id, lower_limit_radians: f32, upper_limit_radians: f32) {
	box3d.SphericalJoint_SetTwistLimits(joint_id, lower_limit_radians, upper_limit_radians)
}

// The spherical joint's current twist angle in radians.
spherical_joint_get_twist_angle :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.SphericalJoint_GetTwistAngle(joint_id)
}

// Enables or disables the spherical joint's spring.
spherical_joint_enable_spring :: proc(joint_id: Joint_Id, enable_spring: bool) {
	box3d.SphericalJoint_EnableSpring(joint_id, enable_spring)
}

// Whether the spherical joint's angular spring is enabled.
spherical_joint_is_spring_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.SphericalJoint_IsSpringEnabled(joint_id)
}

// Sets the spherical joint's spring stiffness in Hertz.
spherical_joint_set_spring_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.SphericalJoint_SetSpringHertz(joint_id, hertz)
}

// The spherical joint's spring stiffness in Hertz.
spherical_joint_get_spring_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.SphericalJoint_GetSpringHertz(joint_id)
}

// Sets the spherical joint's spring damping ratio, non-dimensional.
spherical_joint_set_spring_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.SphericalJoint_SetSpringDampingRatio(joint_id, damping_ratio)
}

// The spherical joint's spring damping ratio, non-dimensional.
spherical_joint_get_spring_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.SphericalJoint_GetSpringDampingRatio(joint_id)
}

// Sets the spherical joint's spring target rotation.
spherical_joint_set_target_rotation :: proc(joint_id: Joint_Id, target_rotation: [4]f32) {
	box3d.SphericalJoint_SetTargetRotation(joint_id, transmute(box3d.Quat)target_rotation)
}

// The spherical joint's spring target rotation.
spherical_joint_get_target_rotation :: proc(joint_id: Joint_Id) -> [4]f32 {
	return transmute([4]f32)box3d.SphericalJoint_GetTargetRotation(joint_id)
}

// Enables or disables the spherical joint's motor.
spherical_joint_enable_motor :: proc(joint_id: Joint_Id, enable_motor: bool) {
	box3d.SphericalJoint_EnableMotor(joint_id, enable_motor)
}

// Whether the spherical joint's motor is enabled.
spherical_joint_is_motor_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.SphericalJoint_IsMotorEnabled(joint_id)
}

// Sets the spherical joint's motor velocity in radians per second: B's angular velocity minus A's, world frame.
spherical_joint_set_motor_velocity :: proc(joint_id: Joint_Id, motor_velocity: [3]f32) {
	box3d.SphericalJoint_SetMotorVelocity(joint_id, transmute(box3d.Vec3)motor_velocity)
}

// The spherical joint's motor velocity in radians per second.
spherical_joint_get_motor_velocity :: proc(joint_id: Joint_Id) -> [3]f32 {
	return transmute([3]f32)box3d.SphericalJoint_GetMotorVelocity(joint_id)
}

// The spherical joint's current motor torque, usually in newton-meters.
spherical_joint_get_motor_torque :: proc(joint_id: Joint_Id) -> [3]f32 {
	return transmute([3]f32)box3d.SphericalJoint_GetMotorTorque(joint_id)
}

// Sets the spherical joint's maximum motor torque, usually in newton-meters.
spherical_joint_set_max_motor_torque :: proc(joint_id: Joint_Id, max_torque: f32) {
	box3d.SphericalJoint_SetMaxMotorTorque(joint_id, max_torque)
}

// The spherical joint's maximum motor torque, usually in newton-meters.
spherical_joint_get_max_motor_torque :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.SphericalJoint_GetMaxMotorTorque(joint_id)
}

// Creates a weld joint between the def's two bodies.
create_weld_joint :: proc(world_id: World_Id, def: ^Weld_Joint_Def) -> Joint_Id {
	return box3d.CreateWeldJoint(world_id, (^box3d.WeldJointDef)(def))
}

// Sets the weld joint's linear stiffness in Hertz. 0 is rigid.
weld_joint_set_linear_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.WeldJoint_SetLinearHertz(joint_id, hertz)
}

// The weld joint's linear stiffness in Hertz.
weld_joint_get_linear_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WeldJoint_GetLinearHertz(joint_id)
}

// Sets the weld joint's linear damping ratio (non-dimensional).
weld_joint_set_linear_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.WeldJoint_SetLinearDampingRatio(joint_id, damping_ratio)
}

// The weld joint's linear damping ratio (non-dimensional).
weld_joint_get_linear_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WeldJoint_GetLinearDampingRatio(joint_id)
}

// Sets the weld joint's angular stiffness in Hertz. 0 is rigid.
weld_joint_set_angular_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.WeldJoint_SetAngularHertz(joint_id, hertz)
}

// The weld joint's angular stiffness in Hertz.
weld_joint_get_angular_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WeldJoint_GetAngularHertz(joint_id)
}

// Sets the weld joint's angular damping ratio, non-dimensional.
weld_joint_set_angular_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.WeldJoint_SetAngularDampingRatio(joint_id, damping_ratio)
}

// The weld joint's angular damping ratio, non-dimensional.
weld_joint_get_angular_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WeldJoint_GetAngularDampingRatio(joint_id)
}

// Creates a wheel joint between the def's two bodies.
create_wheel_joint :: proc(world_id: World_Id, def: ^Wheel_Joint_Def) -> Joint_Id {
	return box3d.CreateWheelJoint(world_id, (^box3d.WheelJointDef)(def))
}

// Enables or disables the wheel joint's suspension spring.
wheel_joint_enable_suspension :: proc(joint_id: Joint_Id, enable_spring: bool) {
	box3d.WheelJoint_EnableSuspension(joint_id, enable_spring)
}

// Whether the wheel joint's suspension spring is enabled.
wheel_joint_is_suspension_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.WheelJoint_IsSuspensionEnabled(joint_id)
}

// Sets the wheel joint's suspension stiffness in Hertz.
wheel_joint_set_suspension_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.WheelJoint_SetSuspensionHertz(joint_id, hertz)
}

// The wheel joint's suspension stiffness in Hertz.
wheel_joint_get_suspension_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetSuspensionHertz(joint_id)
}

// Sets the wheel joint's suspension damping ratio, non-dimensional.
wheel_joint_set_suspension_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.WheelJoint_SetSuspensionDampingRatio(joint_id, damping_ratio)
}

// The wheel joint's suspension damping ratio, non-dimensional.
wheel_joint_get_suspension_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetSuspensionDampingRatio(joint_id)
}

// Enables or disables the wheel joint's suspension limit.
wheel_joint_enable_suspension_limit :: proc(joint_id: Joint_Id, enable_limit: bool) {
	box3d.WheelJoint_EnableSuspensionLimit(joint_id, enable_limit)
}

// Whether the wheel joint's suspension limit is enabled.
wheel_joint_is_suspension_limit_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.WheelJoint_IsSuspensionLimitEnabled(joint_id)
}

// The wheel joint's lower suspension limit.
wheel_joint_get_lower_suspension_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetLowerSuspensionLimit(joint_id)
}

// The wheel joint's upper suspension limit.
wheel_joint_get_upper_suspension_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetUpperSuspensionLimit(joint_id)
}

// Sets the wheel joint's suspension limits.
wheel_joint_set_suspension_limits :: proc(joint_id: Joint_Id, lower: f32, upper: f32) {
	box3d.WheelJoint_SetSuspensionLimits(joint_id, lower, upper)
}

// Enables or disables the wheel joint's spin motor.
wheel_joint_enable_spin_motor :: proc(joint_id: Joint_Id, enable_motor: bool) {
	box3d.WheelJoint_EnableSpinMotor(joint_id, enable_motor)
}

// Whether the wheel joint's spin motor is enabled.
wheel_joint_is_spin_motor_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.WheelJoint_IsSpinMotorEnabled(joint_id)
}

// Sets the wheel joint's spin motor speed in radians per second.
wheel_joint_set_spin_motor_speed :: proc(joint_id: Joint_Id, motor_speed: f32) {
	box3d.WheelJoint_SetSpinMotorSpeed(joint_id, motor_speed)
}

// The wheel joint's spin motor speed in radians per second.
wheel_joint_get_spin_motor_speed :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetSpinMotorSpeed(joint_id)
}

// Sets the wheel joint's maximum spin motor torque, usually in newton-meters.
wheel_joint_set_max_spin_torque :: proc(joint_id: Joint_Id, torque: f32) {
	box3d.WheelJoint_SetMaxSpinTorque(joint_id, torque)
}

// The wheel joint's maximum spin motor torque, usually in newton-meters.
wheel_joint_get_max_spin_torque :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetMaxSpinTorque(joint_id)
}

// The wheel joint's current spin speed in radians per second.
wheel_joint_get_spin_speed :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetSpinSpeed(joint_id)
}

// The wheel joint's current spin motor torque, usually in newton-meters.
wheel_joint_get_spin_torque :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetSpinTorque(joint_id)
}

// Enables or disables steering (the wheel rotating about the suspension axis).
wheel_joint_enable_steering :: proc(joint_id: Joint_Id, enable: bool) {
	box3d.WheelJoint_EnableSteering(joint_id, enable)
}

// Whether the wheel can steer.
wheel_joint_is_steering_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.WheelJoint_IsSteeringEnabled(joint_id)
}

// Sets the wheel joint's steering stiffness in Hertz.
wheel_joint_set_steering_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.WheelJoint_SetSteeringHertz(joint_id, hertz)
}

// The wheel joint's steering stiffness in Hertz.
wheel_joint_get_steering_hertz :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetSteeringHertz(joint_id)
}

// Sets the wheel joint's steering damping ratio, non-dimensional.
wheel_joint_set_steering_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.WheelJoint_SetSteeringDampingRatio(joint_id, damping_ratio)
}

// The wheel joint's steering damping ratio, non-dimensional.
wheel_joint_get_steering_damping_ratio :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetSteeringDampingRatio(joint_id)
}

// Sets the wheel joint's maximum steering torque in N·m.
wheel_joint_set_max_steering_torque :: proc(joint_id: Joint_Id, max_torque: f32) {
	box3d.WheelJoint_SetMaxSteeringTorque(joint_id, max_torque)
}

// The wheel joint's maximum steering torque in N·m.
wheel_joint_get_max_steering_torque :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetMaxSteeringTorque(joint_id)
}

// Enables or disables the wheel joint's steering limit.
wheel_joint_enable_steering_limit :: proc(joint_id: Joint_Id, enable: bool) {
	box3d.WheelJoint_EnableSteeringLimit(joint_id, enable)
}

// Whether the wheel joint's steering limit is enabled.
wheel_joint_is_steering_limit_enabled :: proc(joint_id: Joint_Id) -> bool {
	return box3d.WheelJoint_IsSteeringLimitEnabled(joint_id)
}

// The wheel joint's lower steering limit in radians.
wheel_joint_get_lower_steering_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetLowerSteeringLimit(joint_id)
}

// The wheel joint's upper steering limit in radians.
wheel_joint_get_upper_steering_limit :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetUpperSteeringLimit(joint_id)
}

// Sets the wheel joint's steering limits in radians.
wheel_joint_set_steering_limits :: proc(joint_id: Joint_Id, lower_radians: f32, upper_radians: f32) {
	box3d.WheelJoint_SetSteeringLimits(joint_id, lower_radians, upper_radians)
}

// Sets the wheel joint's target steering angle in radians.
wheel_joint_set_target_steering_angle :: proc(joint_id: Joint_Id, radians: f32) {
	box3d.WheelJoint_SetTargetSteeringAngle(joint_id, radians)
}

// The wheel joint's target steering angle in radians.
wheel_joint_get_target_steering_angle :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetTargetSteeringAngle(joint_id)
}

// The wheel joint's current steering angle in radians.
wheel_joint_get_steering_angle :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetSteeringAngle(joint_id)
}

// The wheel joint's current steering torque in N·m.
wheel_joint_get_steering_torque :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.WheelJoint_GetSteeringTorque(joint_id)
}
