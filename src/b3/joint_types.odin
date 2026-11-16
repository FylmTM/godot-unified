// Mirrors of Box3D's joint definitions and joint type that types.odin doesn't have (src/b3/SPEC.md, Conventions):
// the bindings' layout field for field, asserted below and tested in tests/b3.
package b3

import box3d "box3d:bindings"

// What kind a joint is (joint_get_type).
Joint_Type :: enum i32 {
	Parallel_Joint  = 0,
	Distance_Joint  = 1,
	Filter_Joint    = 2,
	Motor_Joint     = 3,
	Prismatic_Joint = 4,
	Revolute_Joint  = 5,
	Spherical_Joint = 6,
	Weld_Joint      = 7,
	Wheel_Joint     = 8,
	Mover_Joint     = 9,
	Pogo_Joint      = 10,
}

Distance_Joint_Def :: struct {
	base:               Joint_Def,
	length:             f32,
	enable_spring:      bool,
	lower_spring_force: f32,
	upper_spring_force: f32,
	hertz:              f32,
	damping_ratio:      f32,
	enable_limit:       bool,
	min_length:         f32,
	max_length:         f32,
	enable_motor:       bool,
	max_motor_force:    f32,
	motor_speed:        f32,
}

// Disables collision between two bodies, nothing else.
Filter_Joint_Def :: struct {
	base: Joint_Def,
}

Parallel_Joint_Def :: struct {
	base:          Joint_Def,
	hertz:         f32,
	damping_ratio: f32,
	max_torque:    f32,
}

Prismatic_Joint_Def :: struct {
	base:               Joint_Def,
	enable_spring:      bool,
	hertz:              f32,
	damping_ratio:      f32,
	target_translation: f32,
	enable_limit:       bool,
	lower_translation:  f32,
	upper_translation:  f32,
	enable_motor:       bool,
	max_motor_force:    f32,
	motor_speed:        f32,
}

Revolute_Joint_Def :: struct {
	base:             Joint_Def,
	target_angle:     f32,
	enable_spring:    bool,
	hertz:            f32,
	damping_ratio:    f32,
	enable_limit:     bool,
	lower_angle:      f32,
	upper_angle:      f32,
	enable_motor:     bool,
	max_motor_torque: f32,
	motor_speed:      f32,
}

Spherical_Joint_Def :: struct {
	base:               Joint_Def,
	enable_spring:      bool,
	hertz:              f32,
	damping_ratio:      f32,
	target_rotation:    [4]f32, // frame B relative to frame A
	enable_cone_limit:  bool,
	cone_angle:         f32,
	enable_twist_limit: bool,
	lower_twist_angle:  f32,
	upper_twist_angle:  f32,
	enable_motor:       bool,
	max_motor_torque:   f32,
	motor_velocity:     [3]f32, // B's angular velocity minus A's, world frame
}

Weld_Joint_Def :: struct {
	base:                  Joint_Def,
	linear_hertz:          f32,
	angular_hertz:         f32,
	linear_damping_ratio:  f32,
	angular_damping_ratio: f32,
}

Wheel_Joint_Def :: struct {
	base:                     Joint_Def,
	enable_suspension_spring: bool,
	suspension_hertz:         f32,
	suspension_damping_ratio: f32,
	enable_suspension_limit:  bool,
	lower_suspension_limit:   f32,
	upper_suspension_limit:   f32,
	enable_spin_motor:        bool,
	max_spin_torque:          f32,
	spin_speed:               f32,
	enable_steering:          bool,
	steering_hertz:           f32,
	steering_damping_ratio:   f32,
	target_steering_angle:    f32,
	max_steering_torque:      f32,
	enable_steering_limit:    bool,
	lower_steering_limit:     f32,
	upper_steering_limit:     f32,
}

#assert(size_of(Joint_Type) == size_of(box3d.JointType))
#assert(i32(Joint_Type.Parallel_Joint) == i32(box3d.JointType.parallelJoint))
#assert(i32(Joint_Type.Distance_Joint) == i32(box3d.JointType.distanceJoint))
#assert(i32(Joint_Type.Filter_Joint) == i32(box3d.JointType.filterJoint))
#assert(i32(Joint_Type.Motor_Joint) == i32(box3d.JointType.motorJoint))
#assert(i32(Joint_Type.Prismatic_Joint) == i32(box3d.JointType.prismaticJoint))
#assert(i32(Joint_Type.Revolute_Joint) == i32(box3d.JointType.revoluteJoint))
#assert(i32(Joint_Type.Spherical_Joint) == i32(box3d.JointType.sphericalJoint))
#assert(i32(Joint_Type.Weld_Joint) == i32(box3d.JointType.weldJoint))
#assert(i32(Joint_Type.Wheel_Joint) == i32(box3d.JointType.wheelJoint))
#assert(i32(Joint_Type.Mover_Joint) == i32(box3d.JointType.moverJoint))
#assert(i32(Joint_Type.Pogo_Joint) == i32(box3d.JointType.pogoJoint))
#assert(size_of(Distance_Joint_Def) == size_of(box3d.DistanceJointDef))
#assert(size_of(Filter_Joint_Def) == size_of(box3d.FilterJointDef))
#assert(size_of(Parallel_Joint_Def) == size_of(box3d.ParallelJointDef))
#assert(size_of(Prismatic_Joint_Def) == size_of(box3d.PrismaticJointDef))
#assert(size_of(Revolute_Joint_Def) == size_of(box3d.RevoluteJointDef))
#assert(size_of(Spherical_Joint_Def) == size_of(box3d.SphericalJointDef))
#assert(size_of(Weld_Joint_Def) == size_of(box3d.WeldJointDef))
#assert(size_of(Wheel_Joint_Def) == size_of(box3d.WheelJointDef))
