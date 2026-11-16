// Bodies (src/physics/SPEC.md, What physics covers): Box3D's body procs on a Body_Ref, named by its names without
// `get_`. Accessors trust the ref (check_refs covers the block's; a link goes through resolve first).
package physics

import "unified:b3"

Matrix3 :: b3.Matrix3 // three columns
Mass_Data :: b3.Mass_Data

// The body's type (static, kinematic, dynamic).
body_type :: proc(world: ^World, ref: Body_Ref) -> Body_Type {
	return b3.body_get_type(body_id(world, ref))
}

// Changes the body's type; its contacts and joints follow.
body_set_type :: proc(world: ^World, ref: Body_Ref, type: Body_Type) {
	b3.body_set_type(body_id(world, ref), type)
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
	return b3.body_get_transform(body_id(world, ref))
}

// Moves the body (teleports it: respawns, resets); its velocities are kept (body_set_linear_velocity to stop it).
body_set_transform :: proc(world: ^World, ref: Body_Ref, position: [3]f32, rotation: [4]f32) {
	b3.body_set_transform(body_id(world, ref), position, rotation)
}

// Sets a kinematic body's velocities so it reaches `target` in `time_step` (a moving platform's next pose: `t.dt`).
body_set_target_transform :: proc(world: ^World, ref: Body_Ref, target: Transform, time_step: f32, wake := true) {
	b3.body_set_target_transform(body_id(world, ref), target, time_step, wake)
}

// A world point in the body's frame.
body_local_point :: proc(world: ^World, ref: Body_Ref, world_point: [3]f32) -> [3]f32 {
	return b3.body_get_local_point(body_id(world, ref), world_point)
}

// A body-local point in world space.
body_world_point :: proc(world: ^World, ref: Body_Ref, local_point: [3]f32) -> [3]f32 {
	return b3.body_get_world_point(body_id(world, ref), local_point)
}

// A world vector in the body's frame (rotation only).
body_local_vector :: proc(world: ^World, ref: Body_Ref, world_vector: [3]f32) -> [3]f32 {
	return b3.body_get_local_vector(body_id(world, ref), world_vector)
}

// A body-local vector in world space (rotation only).
body_world_vector :: proc(world: ^World, ref: Body_Ref, local_vector: [3]f32) -> [3]f32 {
	return b3.body_get_world_vector(body_id(world, ref), local_vector)
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

// The world velocity of a body-local point.
body_local_point_velocity :: proc(world: ^World, ref: Body_Ref, local_point: [3]f32) -> [3]f32 {
	return b3.body_get_local_point_velocity(body_id(world, ref), local_point)
}

// The world velocity of a world point moving with the body.
body_world_point_velocity :: proc(world: ^World, ref: Body_Ref, world_point: [3]f32) -> [3]f32 {
	return b3.body_get_world_point_velocity(body_id(world, ref), world_point)
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

// ---- mass

// The body's mass (kg).
body_mass :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_mass(body_id(world, ref))
}

// 1 / mass (0 for static and kinematic bodies).
body_inverse_mass :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_inverse_mass(body_id(world, ref))
}

// The rotational inertia about the centre of mass, in the body's frame (kg·m²).
body_local_rotational_inertia :: proc(world: ^World, ref: Body_Ref) -> Matrix3 {
	return b3.body_get_local_rotational_inertia(body_id(world, ref))
}

// The inverse rotational inertia in world axes.
body_world_inverse_rotational_inertia :: proc(world: ^World, ref: Body_Ref) -> Matrix3 {
	return b3.body_get_world_inverse_rotational_inertia(body_id(world, ref))
}

// The centre of mass in the body's frame.
body_local_center :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return b3.body_get_local_center(body_id(world, ref))
}

// The centre of mass in world space.
body_world_center :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return b3.body_get_world_center(body_id(world, ref))
}

// Overrides the mass, centre of mass and inertia the shapes gave (until the shapes change or
// body_apply_mass_from_shapes).
body_set_mass_data :: proc(world: ^World, ref: Body_Ref, mass_data: Mass_Data) {
	b3.body_set_mass_data(body_id(world, ref), mass_data)
}

// The body's mass, centre of mass (body-local) and inertia.
body_mass_data :: proc(world: ^World, ref: Body_Ref) -> Mass_Data {
	return b3.body_get_mass_data(body_id(world, ref))
}

// Recomputes the mass data from the body's shapes.
body_apply_mass_from_shapes :: proc(world: ^World, ref: Body_Ref) {
	b3.body_apply_mass_from_shapes(body_id(world, ref))
}

// ---- damping and gravity

// Sets the linear damping (1/s).
body_set_linear_damping :: proc(world: ^World, ref: Body_Ref, linear_damping: f32) {
	b3.body_set_linear_damping(body_id(world, ref), linear_damping)
}

// The linear damping.
body_linear_damping :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_linear_damping(body_id(world, ref))
}

// Sets the angular damping (1/s).
body_set_angular_damping :: proc(world: ^World, ref: Body_Ref, angular_damping: f32) {
	b3.body_set_angular_damping(body_id(world, ref), angular_damping)
}

// The angular damping.
body_angular_damping :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_angular_damping(body_id(world, ref))
}

// Sets how much of the world's gravity the body feels (1: all).
body_set_gravity_scale :: proc(world: ^World, ref: Body_Ref, gravity_scale: f32) {
	b3.body_set_gravity_scale(body_id(world, ref), gravity_scale)
}

// The gravity scale.
body_gravity_scale :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_gravity_scale(body_id(world, ref))
}

// ---- sleep and enable

// Whether the body is awake.
body_is_awake :: proc(world: ^World, ref: Body_Ref) -> bool {
	return b3.body_is_awake(body_id(world, ref))
}

// Wakes the body, or puts it (and its island) to sleep.
body_set_awake :: proc(world: ^World, ref: Body_Ref, awake: bool) {
	b3.body_set_awake(body_id(world, ref), awake)
}

// Lets the body sleep, or keeps it awake.
body_enable_sleep :: proc(world: ^World, ref: Body_Ref, enable_sleep: bool) {
	b3.body_enable_sleep(body_id(world, ref), enable_sleep)
}

// Whether the body may sleep.
body_is_sleep_enabled :: proc(world: ^World, ref: Body_Ref) -> bool {
	return b3.body_is_sleep_enabled(body_id(world, ref))
}

// Sets the speed (m/s) under which the body counts as resting.
body_set_sleep_threshold :: proc(world: ^World, ref: Body_Ref, sleep_threshold: f32) {
	b3.body_set_sleep_threshold(body_id(world, ref), sleep_threshold)
}

// The sleep threshold.
body_sleep_threshold :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_sleep_threshold(body_id(world, ref))
}

// Whether the body is in the simulation.
body_is_enabled :: proc(world: ^World, ref: Body_Ref) -> bool {
	return b3.body_is_enabled(body_id(world, ref))
}

// Takes the body out of the simulation (no collisions, no queries) without destroying it.
body_disable :: proc(world: ^World, ref: Body_Ref) {
	b3.body_disable(body_id(world, ref))
}

// Puts a disabled body back into the simulation.
body_enable :: proc(world: ^World, ref: Body_Ref) {
	b3.body_enable(body_id(world, ref))
}

// ---- motion

// Locks translation and rotation per axis.
body_set_motion_locks :: proc(world: ^World, ref: Body_Ref, locks: Motion_Locks) {
	b3.body_set_motion_locks(body_id(world, ref), locks)
}

// The motion locks.
body_motion_locks :: proc(world: ^World, ref: Body_Ref) -> Motion_Locks {
	return b3.body_get_motion_locks(body_id(world, ref))
}

// Makes the body a bullet (continuous collision against dynamic bodies too).
body_set_bullet :: proc(world: ^World, ref: Body_Ref, flag: bool) {
	b3.body_set_bullet(body_id(world, ref), flag)
}

// Whether the body is a bullet.
body_is_bullet :: proc(world: ^World, ref: Body_Ref) -> bool {
	return b3.body_is_bullet(body_id(world, ref))
}

// Lets the body spin faster than Box3D's per-step rotation limit (wheels, rolling balls).
body_allow_fast_rotation :: proc(world: ^World, ref: Body_Ref, flag: bool) {
	b3.body_allow_fast_rotation(body_id(world, ref), flag)
}

// Whether fast rotation is allowed.
body_is_fast_rotation_allowed :: proc(world: ^World, ref: Body_Ref) -> bool {
	return b3.body_is_fast_rotation_allowed(body_id(world, ref))
}

// Lets the body reuse its contacts' manifolds while it moves little.
body_enable_contact_recycling :: proc(world: ^World, ref: Body_Ref, flag: bool) {
	b3.body_enable_contact_recycling(body_id(world, ref), flag)
}

// Whether contact recycling is on.
body_is_contact_recycling_enabled :: proc(world: ^World, ref: Body_Ref) -> bool {
	return b3.body_is_contact_recycling_enabled(body_id(world, ref))
}

// Turns hit events on or off for every shape of the body (shape_are_hit_events_enabled reads it back).
body_enable_hit_events :: proc(world: ^World, ref: Body_Ref, flag: bool) {
	b3.body_enable_hit_events(body_id(world, ref), flag)
}

// Sets the continuous-collision safety factor.
body_set_safety_factor :: proc(world: ^World, ref: Body_Ref, safety_factor: f32) {
	b3.body_set_safety_factor(body_id(world, ref), safety_factor)
}

// The safety factor.
body_safety_factor :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_safety_factor(body_id(world, ref))
}

// ---- shapes, joints, extents

// The number of shapes on the body.
body_shape_count :: proc(world: ^World, ref: Body_Ref) -> int {
	return int(b3.body_get_shape_count(body_id(world, ref)))
}

// The body's shapes into `out` (replaced), by shape index.
body_shapes :: proc(world: ^World, ref: Body_Ref, out: ^[dynamic]Shape_Ref) {
	id := body_id(world, ref)
	resize(out, int(b3.body_get_shape_count(id)))
	// A Shape_Id has a Shape_Ref's size: Box3D writes ids into `out`, then each is turned into a ref in place.
	ids := ([^]b3.Shape_Id)(raw_data(out^))[:len(out^)]
	resize(out, int(b3.body_get_shapes(id, ids)))
	for &shape in out^ {
		shape = shape_ref_of(transmute(b3.Shape_Id)shape)
	}
	sort_by_index(out[:])
}

// The number of joints attached to the body.
body_joint_count :: proc(world: ^World, ref: Body_Ref) -> int {
	return int(b3.body_get_joint_count(body_id(world, ref)))
}

// The body's joints into `out` (replaced), by joint index; joint_as gives a typed ref.
body_joints :: proc(world: ^World, ref: Body_Ref, out: ^[dynamic]Joint_Ref) {
	id := body_id(world, ref)
	resize(out, int(b3.body_get_joint_count(id)))
	ids := ([^]b3.Joint_Id)(raw_data(out^))[:len(out^)]
	resize(out, int(b3.body_get_joints(id, ids)))
	for &joint in out^ {
		joint = joint_ref_of(transmute(b3.Joint_Id)joint)
	}
	sort_by_index(out[:])
}

#assert(size_of(Shape_Ref) == size_of(b3.Shape_Id) && size_of(Joint_Ref) == size_of(b3.Joint_Id))

// The union of the body's shapes' AABBs.
body_compute_aabb :: proc(world: ^World, ref: Body_Ref) -> AABB {
	return b3.body_compute_aabb(body_id(world, ref))
}

// The body's smallest extent (what continuous collision uses).
body_min_extent :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_min_extent(body_id(world, ref))
}

// The body's largest extent from its centre of mass, per axis.
body_max_extent :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return b3.body_get_max_extent(body_id(world, ref))
}

// The body's largest extent from its origin, per axis (body_max_extent plus the centre of mass's offset).
body_max_extent_origin :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return b3.body_get_max_extent_origin(body_id(world, ref))
}

// Sorts refs by index (insertion sort: a handful of items, and no core:slice in tick code).
@(private)
sort_by_index :: proc(items: []$T) {
	for i in 1 ..< len(items) {
		held := items[i]
		j := i
		for j > 0 && held.index1 < items[j - 1].index1 {
			items[j] = items[j - 1]
			j -= 1
		}
		items[j] = held
	}
}

// Names the body (copied into the world: rollback state; for debugging and tools).
body_set_name :: proc(world: ^World, ref: Body_Ref, name: cstring) {
	b3.body_set_name(body_id(world, ref), name)
}

// The body's name ("" when unnamed; valid while the body lives).
body_name :: proc(world: ^World, ref: Body_Ref) -> cstring {
	return b3.body_get_name(body_id(world, ref))
}
