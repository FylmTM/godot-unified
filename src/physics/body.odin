// Bodies (src/physics/README.md, What physics covers): Box3D's body procs on a Body_Ref, named by its names without
// `get_`. Accessors trust the ref (check_refs covers the block's; a link goes through resolve first).
package physics

import box3d "box3d:bindings"


// The body's type (static, kinematic, dynamic).
body_type :: proc(world: ^World, ref: Body_Ref) -> Body_Type {
	return Body_Type(box3d.Body_GetType(body_id(world, ref)))
}

// Changes the body's type; its contacts and joints follow.
body_set_type :: proc(world: ^World, ref: Body_Ref, type: Body_Type) {
	box3d.Body_SetType(body_id(world, ref), box3d.BodyType(type))
}

// The body's world position (its origin).
body_position :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetPosition(body_id(world, ref))
}

// The body's world rotation (x, y, z, w).
body_rotation :: proc(world: ^World, ref: Body_Ref) -> [4]f32 {
	return transmute([4]f32)box3d.Body_GetRotation(body_id(world, ref))
}

// The body's world transform (position and rotation).
body_transform :: proc(world: ^World, ref: Body_Ref) -> Transform {
	return transmute(Transform)box3d.Body_GetTransform(body_id(world, ref))
}

// Moves the body (teleports it: respawns, resets, a warp gate); its velocities are kept (body_set_linear_velocity to
// stop it). Its warp epoch moves on (body_warp): its view snaps.
body_set_transform :: proc(world: ^World, ref: Body_Ref, position: [3]f32, rotation: [4]f32) {
	box3d.Body_SetTransform(body_id(world, ref), transmute(box3d.Vec3)position, transmute(box3d.Quat)rotation)
	warp_bump(world, ref)
}

// Moves the body and stops it: its velocities zeroed (respawns, resets, putting a thing back), its warp epoch moved on
// (body_warp). A character has its own (character_teleport).
body_teleport :: proc(world: ^World, ref: Body_Ref, position: [3]f32, rotation := [4]f32{0, 0, 0, 1}) {
	id := body_id(world, ref)
	box3d.Body_SetTransform(id, transmute(box3d.Vec3)position, transmute(box3d.Quat)rotation)
	box3d.Body_SetLinearVelocity(id, {})
	box3d.Body_SetAngularVelocity(id, {})
	warp_bump(world, ref)
}

// The body's warp epoch: a counter every teleport moves on (body_teleport(_2d), body_set_transform(_2d),
// character_teleport), kept in physics' rolled-back body table. A view pushes it (godot.View_Item.warp) to snap, not
// glide, across a teleport: `warp = physics.body_warp(f.world.phys, ship.body)`. A body made anew starts at 0, so a
// thing whose body is re-created (a respawn that makes a new body) keeps an epoch of its own.
body_warp :: proc(world: ^World, ref: Body_Ref) -> u8 {
	if ref.index1 == 0 || int(ref.index1) > len(world.bodies) do return 0
	return world.bodies[ref.index1 - 1].warp
}

// A teleport of the body: its warp epoch moves on (wrapping).
@(private)
warp_bump :: proc(world: ^World, ref: Body_Ref) {
	world.bodies[ref.index1 - 1].warp += 1
}

// Sets a kinematic body's velocities so it reaches `target` in `time_step` (a moving platform's next pose: `t.dt`).
body_set_target_transform :: proc(world: ^World, ref: Body_Ref, target: Transform, time_step: f32, wake := true) {
	box3d.Body_SetTargetTransform(body_id(world, ref), transmute(box3d.Transform)target, time_step, wake)
}

// A world point in the body's frame.
body_local_point :: proc(world: ^World, ref: Body_Ref, world_point: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLocalPoint(body_id(world, ref), transmute(box3d.Vec3)world_point)
}

// A body-local point in world space.
body_world_point :: proc(world: ^World, ref: Body_Ref, local_point: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetWorldPoint(body_id(world, ref), transmute(box3d.Vec3)local_point)
}

// A world vector in the body's frame (rotation only).
body_local_vector :: proc(world: ^World, ref: Body_Ref, world_vector: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLocalVector(body_id(world, ref), transmute(box3d.Vec3)world_vector)
}

// A body-local vector in world space (rotation only).
body_world_vector :: proc(world: ^World, ref: Body_Ref, local_vector: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetWorldVector(body_id(world, ref), transmute(box3d.Vec3)local_vector)
}

// The body's linear velocity (m/s) at its centre of mass.
body_linear_velocity :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLinearVelocity(body_id(world, ref))
}

// The body's angular velocity (rad/s, world frame).
body_angular_velocity :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetAngularVelocity(body_id(world, ref))
}

// Sets the body's linear velocity (m/s).
body_set_linear_velocity :: proc(world: ^World, ref: Body_Ref, velocity: [3]f32) {
	box3d.Body_SetLinearVelocity(body_id(world, ref), transmute(box3d.Vec3)velocity)
}

// Sets the body's angular velocity (rad/s, world frame).
body_set_angular_velocity :: proc(world: ^World, ref: Body_Ref, velocity: [3]f32) {
	box3d.Body_SetAngularVelocity(body_id(world, ref), transmute(box3d.Vec3)velocity)
}

// The world velocity of a body-local point.
body_local_point_velocity :: proc(world: ^World, ref: Body_Ref, local_point: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLocalPointVelocity(body_id(world, ref), transmute(box3d.Vec3)local_point)
}

// The world velocity of a world point moving with the body.
body_world_point_velocity :: proc(world: ^World, ref: Body_Ref, world_point: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetWorldPointVelocity(body_id(world, ref), transmute(box3d.Vec3)world_point)
}

// Adds an impulse (N·s) at the centre of mass; `wake` wakes a sleeping body. A force F over one tick is F · dt.
body_apply_linear_impulse_to_center :: proc(world: ^World, ref: Body_Ref, impulse: [3]f32, wake := true) {
	box3d.Body_ApplyLinearImpulseToCenter(body_id(world, ref), transmute(box3d.Vec3)impulse, wake)
}

// Adds a force (N) at a world point for the next step.
body_apply_force :: proc(world: ^World, ref: Body_Ref, force: [3]f32, point: [3]f32, wake := true) {
	box3d.Body_ApplyForce(body_id(world, ref), transmute(box3d.Vec3)force, transmute(box3d.Vec3)point, wake)
}

// Adds a force (N) at the centre of mass for the next step.
body_apply_force_to_center :: proc(world: ^World, ref: Body_Ref, force: [3]f32, wake := true) {
	box3d.Body_ApplyForceToCenter(body_id(world, ref), transmute(box3d.Vec3)force, wake)
}

// Adds a torque (N·m, world frame) for the next step.
body_apply_torque :: proc(world: ^World, ref: Body_Ref, torque: [3]f32, wake := true) {
	box3d.Body_ApplyTorque(body_id(world, ref), transmute(box3d.Vec3)torque, wake)
}

// Adds an impulse (N·s) at a world point.
body_apply_linear_impulse :: proc(world: ^World, ref: Body_Ref, impulse: [3]f32, point: [3]f32, wake := true) {
	box3d.Body_ApplyLinearImpulse(body_id(world, ref), transmute(box3d.Vec3)impulse, transmute(box3d.Vec3)point, wake)
}

// Adds an angular impulse (N·m·s, world frame).
body_apply_angular_impulse :: proc(world: ^World, ref: Body_Ref, impulse: [3]f32, wake := true) {
	box3d.Body_ApplyAngularImpulse(body_id(world, ref), transmute(box3d.Vec3)impulse, wake)
}

// ---- mass

// The body's mass (kg).
body_mass :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return box3d.Body_GetMass(body_id(world, ref))
}

// 1 / mass (0 for static and kinematic bodies).
body_inverse_mass :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return box3d.Body_GetInverseMass(body_id(world, ref))
}

// The rotational inertia about the centre of mass, in the body's frame (kg·m²).
body_local_rotational_inertia :: proc(world: ^World, ref: Body_Ref) -> Matrix3 {
	return transmute(Matrix3)box3d.Body_GetLocalRotationalInertia(body_id(world, ref))
}

// The inverse rotational inertia in world axes.
body_world_inverse_rotational_inertia :: proc(world: ^World, ref: Body_Ref) -> Matrix3 {
	return transmute(Matrix3)box3d.Body_GetWorldInverseRotationalInertia(body_id(world, ref))
}

// The centre of mass in the body's frame.
body_local_center :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLocalCenter(body_id(world, ref))
}

// The centre of mass in world space.
body_world_center :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetWorldCenter(body_id(world, ref))
}

// Overrides the mass, centre of mass and inertia the shapes gave (until the shapes change or
// body_apply_mass_from_shapes).
body_set_mass_data :: proc(world: ^World, ref: Body_Ref, mass_data: Mass_Data) {
	box3d.Body_SetMassData(body_id(world, ref), transmute(box3d.MassData)mass_data)
}

// The body's mass, centre of mass (body-local) and inertia.
body_mass_data :: proc(world: ^World, ref: Body_Ref) -> Mass_Data {
	return transmute(Mass_Data)box3d.Body_GetMassData(body_id(world, ref))
}

// Recomputes the mass data from the body's shapes.
body_apply_mass_from_shapes :: proc(world: ^World, ref: Body_Ref) {
	box3d.Body_ApplyMassFromShapes(body_id(world, ref))
}

// ---- damping and gravity

// Sets the linear damping (1/s).
body_set_linear_damping :: proc(world: ^World, ref: Body_Ref, linear_damping: f32) {
	box3d.Body_SetLinearDamping(body_id(world, ref), linear_damping)
}

// The linear damping.
body_linear_damping :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return box3d.Body_GetLinearDamping(body_id(world, ref))
}

// Sets the angular damping (1/s).
body_set_angular_damping :: proc(world: ^World, ref: Body_Ref, angular_damping: f32) {
	box3d.Body_SetAngularDamping(body_id(world, ref), angular_damping)
}

// The angular damping.
body_angular_damping :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return box3d.Body_GetAngularDamping(body_id(world, ref))
}

// Sets how much of the world's gravity the body feels (1: all).
body_set_gravity_scale :: proc(world: ^World, ref: Body_Ref, gravity_scale: f32) {
	box3d.Body_SetGravityScale(body_id(world, ref), gravity_scale)
}

// The gravity scale.
body_gravity_scale :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return box3d.Body_GetGravityScale(body_id(world, ref))
}

// ---- sleep and enable

// Whether the body is awake.
body_is_awake :: proc(world: ^World, ref: Body_Ref) -> bool {
	return box3d.Body_IsAwake(body_id(world, ref))
}

// Wakes the body, or puts it (and its island) to sleep.
body_set_awake :: proc(world: ^World, ref: Body_Ref, awake: bool) {
	box3d.Body_SetAwake(body_id(world, ref), awake)
}

// Lets the body sleep, or keeps it awake.
body_enable_sleep :: proc(world: ^World, ref: Body_Ref, enable_sleep: bool) {
	box3d.Body_EnableSleep(body_id(world, ref), enable_sleep)
}

// Whether the body may sleep.
body_is_sleep_enabled :: proc(world: ^World, ref: Body_Ref) -> bool {
	return box3d.Body_IsSleepEnabled(body_id(world, ref))
}

// Sets the speed (m/s) under which the body counts as resting.
body_set_sleep_threshold :: proc(world: ^World, ref: Body_Ref, sleep_threshold: f32) {
	box3d.Body_SetSleepThreshold(body_id(world, ref), sleep_threshold)
}

// The sleep threshold.
body_sleep_threshold :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return box3d.Body_GetSleepThreshold(body_id(world, ref))
}

// Whether the body is in the simulation.
body_is_enabled :: proc(world: ^World, ref: Body_Ref) -> bool {
	return box3d.Body_IsEnabled(body_id(world, ref))
}

// Takes the body out of the simulation (no collisions, no queries) without destroying it.
body_disable :: proc(world: ^World, ref: Body_Ref) {
	box3d.Body_Disable(body_id(world, ref))
}

// Puts a disabled body back into the simulation.
body_enable :: proc(world: ^World, ref: Body_Ref) {
	box3d.Body_Enable(body_id(world, ref))
}

// ---- motion

// Locks translation and rotation per axis.
body_set_motion_locks :: proc(world: ^World, ref: Body_Ref, locks: Motion_Locks) {
	box3d.Body_SetMotionLocks(body_id(world, ref), transmute(box3d.MotionLocks)locks)
}

// The motion locks.
body_motion_locks :: proc(world: ^World, ref: Body_Ref) -> Motion_Locks {
	return transmute(Motion_Locks)box3d.Body_GetMotionLocks(body_id(world, ref))
}

// Makes the body a bullet (continuous collision against dynamic bodies too).
body_set_bullet :: proc(world: ^World, ref: Body_Ref, flag: bool) {
	box3d.Body_SetBullet(body_id(world, ref), flag)
}

// Whether the body is a bullet.
body_is_bullet :: proc(world: ^World, ref: Body_Ref) -> bool {
	return box3d.Body_IsBullet(body_id(world, ref))
}

// Lets the body spin faster than Box3D's per-step rotation limit (wheels, rolling balls).
body_allow_fast_rotation :: proc(world: ^World, ref: Body_Ref, flag: bool) {
	box3d.Body_AllowFastRotation(body_id(world, ref), flag)
}

// Whether fast rotation is allowed.
body_is_fast_rotation_allowed :: proc(world: ^World, ref: Body_Ref) -> bool {
	return box3d.Body_IsFastRotationAllowed(body_id(world, ref))
}

// Lets the body reuse its contacts' manifolds while it moves little.
body_enable_contact_recycling :: proc(world: ^World, ref: Body_Ref, flag: bool) {
	box3d.Body_EnableContactRecycling(body_id(world, ref), flag)
}

// Whether contact recycling is on.
body_is_contact_recycling_enabled :: proc(world: ^World, ref: Body_Ref) -> bool {
	return box3d.Body_IsContactRecyclingEnabled(body_id(world, ref))
}

// Turns hit events on or off for every shape of the body (shape_are_hit_events_enabled reads it back).
body_enable_hit_events :: proc(world: ^World, ref: Body_Ref, flag: bool) {
	box3d.Body_EnableHitEvents(body_id(world, ref), flag)
}

// Sets the continuous-collision safety factor.
body_set_safety_factor :: proc(world: ^World, ref: Body_Ref, safety_factor: f32) {
	box3d.Body_SetSafetyFactor(body_id(world, ref), safety_factor)
}

// The safety factor.
body_safety_factor :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return box3d.Body_GetSafetyFactor(body_id(world, ref))
}

// ---- shapes, joints, extents

// The number of shapes on the body.
body_shape_count :: proc(world: ^World, ref: Body_Ref) -> int {
	return int(box3d.Body_GetShapeCount(body_id(world, ref)))
}

// The body's shapes into `out` (replaced), by shape index.
body_shapes :: proc(world: ^World, ref: Body_Ref, out: ^[dynamic]Shape_Ref) {
	id := body_id(world, ref)
	resize(out, int(box3d.Body_GetShapeCount(id)))
	// A Shape_Id has a Shape_Ref's size: Box3D writes ids into `out`, then each is turned into a ref in place.
	ids := ([^]box3d.ShapeId)(raw_data(out^))[:len(out^)]
	resize(out, int(box3d.Body_GetShapes(id, raw_data(ids), i32(len(ids)))))
	for &shape in out^ {
		shape = shape_ref_of(transmute(box3d.ShapeId)shape)
	}
	sort_results(world, out[:], proc(a, b: Shape_Ref) -> bool {return a.index1 < b.index1})
}

// The number of joints attached to the body.
body_joint_count :: proc(world: ^World, ref: Body_Ref) -> int {
	return int(box3d.Body_GetJointCount(body_id(world, ref)))
}

// The body's joints into `out` (replaced), by joint index; joint_as gives a typed ref.
body_joints :: proc(world: ^World, ref: Body_Ref, out: ^[dynamic]Joint_Ref) {
	id := body_id(world, ref)
	resize(out, int(box3d.Body_GetJointCount(id)))
	ids := ([^]box3d.JointId)(raw_data(out^))[:len(out^)]
	resize(out, int(box3d.Body_GetJoints(id, raw_data(ids), i32(len(ids)))))
	for &joint in out^ {
		joint = joint_ref_of(transmute(box3d.JointId)joint)
	}
	sort_results(world, out[:], proc(a, b: Joint_Ref) -> bool {return a.index1 < b.index1})
}

#assert(size_of(Shape_Ref) == size_of(box3d.ShapeId) && size_of(Joint_Ref) == size_of(box3d.JointId))

// The union of the body's shapes' AABBs.
body_compute_aabb :: proc(world: ^World, ref: Body_Ref) -> AABB {
	return transmute(AABB)box3d.Body_ComputeAABB(body_id(world, ref))
}

// The body's smallest extent (what continuous collision uses).
body_min_extent :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return box3d.Body_GetMinExtent(body_id(world, ref))
}

// The body's largest extent from its centre of mass, per axis.
body_max_extent :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetMaxExtent(body_id(world, ref))
}

// The body's largest extent from its origin, per axis (body_max_extent plus the centre of mass's offset).
body_max_extent_origin :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetMaxExtentOrigin(body_id(world, ref))
}

// Names the body (copied into the world: rollback state; for debugging and tools).
body_set_name :: proc(world: ^World, ref: Body_Ref, name: cstring) {
	box3d.Body_SetName(body_id(world, ref), name)
}

// The body's name ("" when unnamed; valid while the body lives).
body_name :: proc(world: ^World, ref: Body_Ref) -> cstring {
	return box3d.Body_GetName(body_id(world, ref))
}

// A body definition: Box3D's default with its type and pose (the rotation x, y, z, w; identity by default). Set any
// other field before create_body.
body_def :: proc(type: Body_Type, position: [3]f32, rotation := [4]f32{0, 0, 0, 1}) -> Body_Def {
	def := default_body_def()
	def.type = type
	def.position = position
	def.rotation = rotation
	return def
}

// Creates a body from a definition and returns the block's reference to it, tagged `tag` (the game's: an entity's
// handle_key, a player's player_key; every query and event reports it). Box3D hands out indices in creation order,
// so a game creates the bodies its block owns in a fixed order. The def's user_data stays unset (a pointer); a name
// is copied into the world (its state: hashed, imaged).
create_body :: proc(world: ^World, def: Body_Def, tag: u64 = 0, loc := #caller_location) -> Body_Ref {
	def := def
	assert(def.user_data == nil, "physics: a body def's user_data stays unset (a pointer in rollback state)", loc)
	id := box3d.CreateBody(world.id, (^box3d.BodyDef)(&def))
	body_created(world, id, tag)
	return ref_of(id)
}

// Destroys the body (its shapes and joints with it), if it is still alive, and clears the reference. Checked: Box3D's
// release library doesn't check generations, so a stale ref would destroy whatever body reuses its index.
destroy_body :: proc(world: ^World, ref: ^Body_Ref) {
	if body_valid(world, link(ref^)) {
		box3d.DestroyBody(body_id(world, ref^))
		if int(ref.index1) <= len(world.bodies) do world.bodies[ref.index1 - 1] = {}
	}
	ref^ = {}
}

// A body's tag (create_body's; 0 when untagged or gone).
body_tag :: proc(world: ^World, ref: Body_Ref) -> u64 {
	return tag_of(world, ref.index1)
}

// Retags a body.
body_set_tag :: proc(world: ^World, ref: Body_Ref, tag: u64) {
	if int(ref.index1) > len(world.bodies) do resize(&world.bodies, int(ref.index1))
	world.bodies[ref.index1 - 1].tag = tag
}

// Records a body physics made (every body is made through physics: create_body, the character, the level).
@(private)
body_created :: proc(world: ^World, id: box3d.BodyId, tag: u64) {
	index := int(id.index1) - 1
	if index >= len(world.bodies) do resize(&world.bodies, index + 1)
	if index >= len(world.generations) do resize(&world.generations, index + 1)
	world.generations[index] = id.generation
	world.bodies[index] = {
		tag   = tag,
		flags = world.sealed ? {.Alive} : {.Alive, .World},
	}
}

@(private)
tag_of :: proc(world: ^World, index1: i32) -> u64 {
	index := int(index1) - 1
	return world.bodies[index].tag if index >= 0 && index < len(world.bodies) else 0
}

// Box3D's default body definition (a static body at the origin), to adjust before create_body.
default_body_def :: proc() -> Body_Def {
	return transmute(Body_Def)box3d.DefaultBodyDef()
}
