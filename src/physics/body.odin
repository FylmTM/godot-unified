// Bodies (src/physics/SPEC.md, What physics covers): Box3D's body procs on a Body_Ref, named by its names without
// `get_`. Accessors trust the ref (check_refs covers the block's; a link goes through resolve first).
package physics

import "unified:b3"

// The body's type (static, kinematic, dynamic).
body_type :: proc(world: ^World, ref: Body_Ref) -> Body_Type {
	return b3.body_get_type(body_id(world, ref))
}

// The body's world position (its origin).
body_position :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return b3.body_get_position(body_id(world, ref))
}

// The body's world rotation (x, y, z, w).
body_rotation :: proc(world: ^World, ref: Body_Ref) -> [4]f32 {
	return b3.body_get_rotation(body_id(world, ref))
}

// The body's world transform (position and rotation).
body_transform :: proc(world: ^World, ref: Body_Ref) -> Transform {
	id := body_id(world, ref)
	return {b3.body_get_position(id), b3.body_get_rotation(id)}
}

// Moves the body (teleports it: respawns, resets); its velocities are kept (body_set_linear_velocity to stop it).
body_set_transform :: proc(world: ^World, ref: Body_Ref, position: [3]f32, rotation: [4]f32) {
	b3.body_set_transform(body_id(world, ref), position, rotation)
}

// A world point in the body's frame.
body_local_point :: proc(world: ^World, ref: Body_Ref, world_point: [3]f32) -> [3]f32 {
	return b3.body_get_local_point(body_id(world, ref), world_point)
}

// The body's linear velocity (m/s) at its centre of mass.
body_linear_velocity :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return b3.body_get_linear_velocity(body_id(world, ref))
}

// The body's angular velocity (rad/s, world frame).
body_angular_velocity :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return b3.body_get_angular_velocity(body_id(world, ref))
}

// Sets the body's linear velocity (m/s).
body_set_linear_velocity :: proc(world: ^World, ref: Body_Ref, velocity: [3]f32) {
	b3.body_set_linear_velocity(body_id(world, ref), velocity)
}

// Sets the body's angular velocity (rad/s, world frame).
body_set_angular_velocity :: proc(world: ^World, ref: Body_Ref, velocity: [3]f32) {
	b3.body_set_angular_velocity(body_id(world, ref), velocity)
}

// Adds an impulse (N·s) at the centre of mass; `wake` wakes a sleeping body. A force F over one tick is F · dt.
body_apply_linear_impulse_to_center :: proc(world: ^World, ref: Body_Ref, impulse: [3]f32, wake := true) {
	b3.body_apply_linear_impulse_to_center(body_id(world, ref), impulse, wake)
}

// Adds a force (N) at a world point for the next step.
body_apply_force :: proc(world: ^World, ref: Body_Ref, force: [3]f32, point: [3]f32, wake := true) {
	b3.body_apply_force(body_id(world, ref), force, point, wake)
}

// Adds a force (N) at the centre of mass for the next step.
body_apply_force_to_center :: proc(world: ^World, ref: Body_Ref, force: [3]f32, wake := true) {
	b3.body_apply_force_to_center(body_id(world, ref), force, wake)
}

// Adds a torque (N·m, world frame) for the next step.
body_apply_torque :: proc(world: ^World, ref: Body_Ref, torque: [3]f32, wake := true) {
	b3.body_apply_torque(body_id(world, ref), torque, wake)
}

// Adds an impulse (N·s) at a world point.
body_apply_linear_impulse :: proc(world: ^World, ref: Body_Ref, impulse: [3]f32, point: [3]f32, wake := true) {
	b3.body_apply_linear_impulse(body_id(world, ref), impulse, point, wake)
}

// Adds an angular impulse (N·m·s, world frame).
body_apply_angular_impulse :: proc(world: ^World, ref: Body_Ref, impulse: [3]f32, wake := true) {
	b3.body_apply_angular_impulse(body_id(world, ref), impulse, wake)
}

// The body's mass (kg).
body_mass :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_mass(body_id(world, ref))
}
