// Box3D's body procs beyond b3.odin's (src/b3/SPEC.md): what physics' Bodies group and per-body queries wrap.
package b3

import box3d "box3d:bindings"

// The body's world transform (position and rotation).
body_get_transform :: proc(body_id: Body_Id) -> Transform {
	return transmute(Transform)box3d.Body_GetTransform(body_id)
}

// Changes the body's type (static, kinematic, dynamic); its contacts and joints follow.
body_set_type :: proc(body_id: Body_Id, type: Body_Type) {
	box3d.Body_SetType(body_id, box3d.BodyType(type))
}

// A body-local point in world space.
body_get_world_point :: proc(body_id: Body_Id, local_point: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetWorldPoint(body_id, transmute(box3d.Vec3)local_point)
}

// A world vector in the body's frame (rotation only).
body_get_local_vector :: proc(body_id: Body_Id, world_vector: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLocalVector(body_id, transmute(box3d.Vec3)world_vector)
}

// A body-local vector in world space (rotation only).
body_get_world_vector :: proc(body_id: Body_Id, local_vector: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetWorldVector(body_id, transmute(box3d.Vec3)local_vector)
}

// Sets a kinematic body's velocities so it reaches `target` in `time_step` (a moving platform's next pose).
body_set_target_transform :: proc(body_id: Body_Id, target: Transform, time_step: f32, wake: bool) {
	box3d.Body_SetTargetTransform(body_id, transmute(box3d.Transform)target, time_step, wake)
}

// The world velocity of a body-local point.
body_get_local_point_velocity :: proc(body_id: Body_Id, local_point: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLocalPointVelocity(body_id, transmute(box3d.Vec3)local_point)
}

// The world velocity of a world point moving with the body.
body_get_world_point_velocity :: proc(body_id: Body_Id, world_point: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetWorldPointVelocity(body_id, transmute(box3d.Vec3)world_point)
}

// The rotational inertia about the centre of mass, in the body's frame (kg·m²).
body_get_local_rotational_inertia :: proc(body_id: Body_Id) -> Matrix3 {
	return transmute(Matrix3)box3d.Body_GetLocalRotationalInertia(body_id)
}

// 1 / mass (0 for static and kinematic bodies).
body_get_inverse_mass :: proc(body_id: Body_Id) -> f32 {
	return box3d.Body_GetInverseMass(body_id)
}

// The inverse rotational inertia in world axes.
body_get_world_inverse_rotational_inertia :: proc(body_id: Body_Id) -> Matrix3 {
	return transmute(Matrix3)box3d.Body_GetWorldInverseRotationalInertia(body_id)
}

// The centre of mass in the body's frame.
body_get_local_center :: proc(body_id: Body_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLocalCenter(body_id)
}

// The centre of mass in world space.
body_get_world_center :: proc(body_id: Body_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetWorldCenter(body_id)
}

// Overrides the mass, centre of mass and inertia the shapes gave (until shapes change or apply_mass_from_shapes).
body_set_mass_data :: proc(body_id: Body_Id, mass_data: Mass_Data) {
	box3d.Body_SetMassData(body_id, transmute(box3d.MassData)mass_data)
}

// The body's mass, centre of mass and inertia.
body_get_mass_data :: proc(body_id: Body_Id) -> Mass_Data {
	return transmute(Mass_Data)box3d.Body_GetMassData(body_id)
}

// Recomputes the mass data from the body's shapes (after set_mass_data, or shapes made without update_body_mass).
body_apply_mass_from_shapes :: proc(body_id: Body_Id) {
	box3d.Body_ApplyMassFromShapes(body_id)
}

// Sets the linear damping (slows linear velocity, 1/s).
body_set_linear_damping :: proc(body_id: Body_Id, linear_damping: f32) {
	box3d.Body_SetLinearDamping(body_id, linear_damping)
}

// The linear damping.
body_get_linear_damping :: proc(body_id: Body_Id) -> f32 {
	return box3d.Body_GetLinearDamping(body_id)
}

// Sets the angular damping (slows angular velocity, 1/s).
body_set_angular_damping :: proc(body_id: Body_Id, angular_damping: f32) {
	box3d.Body_SetAngularDamping(body_id, angular_damping)
}

// The angular damping.
body_get_angular_damping :: proc(body_id: Body_Id) -> f32 {
	return box3d.Body_GetAngularDamping(body_id)
}

// Sets how much of the world's gravity the body feels (1: all).
body_set_gravity_scale :: proc(body_id: Body_Id, gravity_scale: f32) {
	box3d.Body_SetGravityScale(body_id, gravity_scale)
}

// The gravity scale.
body_get_gravity_scale :: proc(body_id: Body_Id) -> f32 {
	return box3d.Body_GetGravityScale(body_id)
}

// Whether the body is awake (simulated this step).
body_is_awake :: proc(body_id: Body_Id) -> bool {
	return box3d.Body_IsAwake(body_id)
}

// Wakes the body, or puts it (and its island) to sleep.
body_set_awake :: proc(body_id: Body_Id, awake: bool) {
	box3d.Body_SetAwake(body_id, awake)
}

// Lets the body sleep, or keeps it awake.
body_enable_sleep :: proc(body_id: Body_Id, enable_sleep: bool) {
	box3d.Body_EnableSleep(body_id, enable_sleep)
}

// Whether the body may sleep.
body_is_sleep_enabled :: proc(body_id: Body_Id) -> bool {
	return box3d.Body_IsSleepEnabled(body_id)
}

// Sets the speed (m/s) under which the body counts as resting.
body_set_sleep_threshold :: proc(body_id: Body_Id, sleep_threshold: f32) {
	box3d.Body_SetSleepThreshold(body_id, sleep_threshold)
}

// The sleep threshold.
body_get_sleep_threshold :: proc(body_id: Body_Id) -> f32 {
	return box3d.Body_GetSleepThreshold(body_id)
}

// Sets the continuous-collision safety factor (a fraction of the body's extent).
body_set_safety_factor :: proc(body_id: Body_Id, safety_factor: f32) {
	box3d.Body_SetSafetyFactor(body_id, safety_factor)
}

// The safety factor.
body_get_safety_factor :: proc(body_id: Body_Id) -> f32 {
	return box3d.Body_GetSafetyFactor(body_id)
}

// Whether the body is in the simulation (not disabled).
body_is_enabled :: proc(body_id: Body_Id) -> bool {
	return box3d.Body_IsEnabled(body_id)
}

// Takes the body out of the simulation (no collisions, no queries) without destroying it.
body_disable :: proc(body_id: Body_Id) {
	box3d.Body_Disable(body_id)
}

// Puts a disabled body back into the simulation.
body_enable :: proc(body_id: Body_Id) {
	box3d.Body_Enable(body_id)
}

// Locks translation and rotation per axis.
body_set_motion_locks :: proc(body_id: Body_Id, locks: Motion_Locks) {
	box3d.Body_SetMotionLocks(body_id, transmute(box3d.MotionLocks)locks)
}

// The motion locks.
body_get_motion_locks :: proc(body_id: Body_Id) -> Motion_Locks {
	return transmute(Motion_Locks)box3d.Body_GetMotionLocks(body_id)
}

// Makes the body a bullet (continuous collision against dynamic bodies too).
body_set_bullet :: proc(body_id: Body_Id, flag: bool) {
	box3d.Body_SetBullet(body_id, flag)
}

// Whether the body is a bullet.
body_is_bullet :: proc(body_id: Body_Id) -> bool {
	return box3d.Body_IsBullet(body_id)
}

// Lets the body spin faster than Box3D's per-step rotation limit (wheels, rolling balls).
body_allow_fast_rotation :: proc(body_id: Body_Id, flag: bool) {
	box3d.Body_AllowFastRotation(body_id, flag)
}

// Whether fast rotation is allowed.
body_is_fast_rotation_allowed :: proc(body_id: Body_Id) -> bool {
	return box3d.Body_IsFastRotationAllowed(body_id)
}

// Lets the body reuse its contacts' manifolds while it moves little.
body_enable_contact_recycling :: proc(body_id: Body_Id, flag: bool) {
	box3d.Body_EnableContactRecycling(body_id, flag)
}

// Whether contact recycling is on.
body_is_contact_recycling_enabled :: proc(body_id: Body_Id) -> bool {
	return box3d.Body_IsContactRecyclingEnabled(body_id)
}

// Turns hit events on or off for every shape of the body.
body_enable_hit_events :: proc(body_id: Body_Id, flag: bool) {
	box3d.Body_EnableHitEvents(body_id, flag)
}

// The number of shapes on the body.
body_get_shape_count :: proc(body_id: Body_Id) -> i32 {
	return box3d.Body_GetShapeCount(body_id)
}

// The body's shapes into `out` (at most len(out)); the count written.
body_get_shapes :: proc(body_id: Body_Id, out: []Shape_Id) -> i32 {
	return box3d.Body_GetShapes(body_id, raw_data(out), i32(len(out)))
}

// The number of joints attached to the body.
body_get_joint_count :: proc(body_id: Body_Id) -> i32 {
	return box3d.Body_GetJointCount(body_id)
}

// The body's joints into `out` (at most len(out)); the count written.
body_get_joints :: proc(body_id: Body_Id, out: []Joint_Id) -> i32 {
	return box3d.Body_GetJoints(body_id, raw_data(out), i32(len(out)))
}

// How many contacts body_get_contact_data can report (the size it needs).
body_get_contact_capacity :: proc(body_id: Body_Id) -> i32 {
	return box3d.Body_GetContactCapacity(body_id)
}

// The body's touching contacts into `out` (at most len(out)); the count written. Their manifolds are Box3D's memory,
// valid until the next step.
body_get_contact_data :: proc(body_id: Body_Id, out: []Contact_Data) -> i32 {
	return box3d.Body_GetContactData(body_id, ([^]box3d.ContactData)(raw_data(out)), i32(len(out)))
}

// The union of the body's shapes' AABBs (a point at the origin for a body without shapes).
body_compute_aabb :: proc(body_id: Body_Id) -> AABB {
	return transmute(AABB)box3d.Body_ComputeAABB(body_id)
}

// The body's smallest extent (what continuous collision uses).
body_get_min_extent :: proc(body_id: Body_Id) -> f32 {
	return box3d.Body_GetMinExtent(body_id)
}

// The body's largest extent from its centre of mass, per axis.
body_get_max_extent :: proc(body_id: Body_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetMaxExtent(body_id)
}

// The body's largest extent per axis measured from its origin (max_extent plus the centre of mass's offset).
body_get_max_extent_origin :: proc(body_id: Body_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetMaxExtentOrigin(body_id)
}

// The point of the body's spheres, capsules and hulls closest to `target`, and its distance (0 inside).
body_get_closest_point :: proc(body_id: Body_Id, target: [3]f32) -> (point: [3]f32, distance: f32) {
	distance = box3d.Body_GetClosestPoint(body_id, (^box3d.Vec3)(&point), transmute(box3d.Vec3)target)
	return
}

// A ray against the body's shapes, the body at `body_transform`; not ok: no hit.
body_cast_ray :: proc(
	body_id: Body_Id,
	origin, translation: [3]f32,
	filter: Query_Filter,
	max_fraction: f32,
	body_transform: Transform,
) -> (
	result: Body_Cast_Result,
	ok: bool,
) {
	raw := box3d.Body_CastRay(
		body_id,
		transmute(box3d.Vec3)origin,
		transmute(box3d.Vec3)translation,
		transmute(box3d.QueryFilter)filter,
		max_fraction,
		transmute(box3d.Transform)body_transform,
	)
	return (^Body_Cast_Result)(&raw)^, raw.hit
}

// A swept proxy against the body's shapes, the body at `body_transform`; not ok: no hit. `can_encroach` lets a
// rounded proxy end closer than its radius.
body_cast_shape :: proc(
	body_id: Body_Id,
	origin: [3]f32,
	proxy: ^Shape_Proxy,
	translation: [3]f32,
	filter: Query_Filter,
	max_fraction: f32,
	can_encroach: bool,
	body_transform: Transform,
) -> (
	result: Body_Cast_Result,
	ok: bool,
) {
	raw := box3d.Body_CastShape(
		body_id,
		transmute(box3d.Vec3)origin,
		(^box3d.ShapeProxy)(proxy),
		transmute(box3d.Vec3)translation,
		transmute(box3d.QueryFilter)filter,
		max_fraction,
		can_encroach,
		transmute(box3d.Transform)body_transform,
	)
	return (^Body_Cast_Result)(&raw)^, raw.hit
}

// Whether the proxy at `origin` overlaps one of the body's shapes, the body at `body_transform`.
body_overlap_shape :: proc(
	body_id: Body_Id,
	origin: [3]f32,
	proxy: ^Shape_Proxy,
	filter: Query_Filter,
	body_transform: Transform,
) -> bool {
	return box3d.Body_OverlapShape(
		body_id,
		transmute(box3d.Vec3)origin,
		(^box3d.ShapeProxy)(proxy),
		transmute(box3d.QueryFilter)filter,
		transmute(box3d.Transform)body_transform,
	)
}

// The planes between a mover capsule (relative to `origin`) and the body's shapes, into `out` (at most len(out));
// the count written.
body_collide_mover :: proc(
	body_id: Body_Id,
	out: []Body_Plane_Result,
	origin: [3]f32,
	mover: ^Capsule,
	filter: Query_Filter,
	body_transform: Transform,
) -> i32 {
	return box3d.Body_CollideMover(
		body_id,
		([^]box3d.BodyPlaneResult)(raw_data(out)),
		i32(len(out)),
		transmute(box3d.Vec3)origin,
		(^box3d.Capsule)(mover),
		transmute(box3d.QueryFilter)filter,
		transmute(box3d.Transform)body_transform,
	)
}

// When a mover capsule swept by `mover_translation` first touches the body moving from `body_transform1` to
// `body_transform2` (shapes it starts inside are skipped). Fraction 1: no hit.
body_time_of_impact_mover :: proc(
	body_id: Body_Id,
	origin: [3]f32,
	mover: ^Capsule,
	mover_translation: [3]f32,
	filter: Query_Filter,
	body_transform1, body_transform2: Transform,
) -> Body_TOI_Result {
	result := box3d.Body_TimeOfImpactMover(
		body_id,
		transmute(box3d.Vec3)origin,
		(^box3d.Capsule)(mover),
		transmute(box3d.Vec3)mover_translation,
		transmute(box3d.QueryFilter)filter,
		transmute(box3d.Transform)body_transform1,
		transmute(box3d.Transform)body_transform2,
	)
	return transmute(Body_TOI_Result)result
}

// Names the body (Box3D copies the name into the world: part of its state, hashed and imaged; for debugging).
body_set_name :: proc(body_id: Body_Id, name: cstring) {
	box3d.Body_SetName(body_id, name)
}

// The body's name ("" when unnamed; Box3D's memory, valid while the body lives).
body_get_name :: proc(body_id: Body_Id) -> cstring {
	return box3d.Body_GetName(body_id)
}
