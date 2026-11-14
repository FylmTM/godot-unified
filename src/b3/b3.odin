package b3

import "base:runtime"
import box3d "box3d:bindings"

// ---- world

// Box3D's default world definition, to adjust before create_world.
default_world_def :: proc() -> World_Def {
	return transmute(World_Def)box3d.DefaultWorldDef()
}

// Creates a Box3D world (physics.create wraps it, with the settings determinism needs).
create_world :: proc(def: ^World_Def) -> World_Id {
	return box3d.CreateWorld((^box3d.WorldDef)(def))
}

// Destroys a world and everything in it.
destroy_world :: proc(world_id: World_Id) {
	box3d.DestroyWorld(world_id)
}

// Advances the world by `time_step` seconds in `sub_step_count` solver substeps.
world_step :: proc(world_id: World_Id, time_step: f32, sub_step_count: i32) {
	box3d.World_Step(world_id, time_step, sub_step_count)
}

// The world's gravity (m/s²).
world_get_gravity :: proc(world_id: World_Id) -> [3]f32 {
	return transmute([3]f32)box3d.World_GetGravity(world_id)
}

// The last step's contact events: slices into Box3D's memory, valid until the next step.
world_get_contact_events :: proc(world_id: World_Id) -> Contact_Events {
	events := box3d.World_GetContactEvents(world_id)
	return {
		begin_events = ([^]Contact_Begin_Touch_Event)(events.beginEvents)[:events.beginCount],
		end_events = ([^]Contact_End_Touch_Event)(events.endEvents)[:events.endCount],
		hit_events = ([^]Contact_Hit_Event)(events.hitEvents)[:events.hitCount],
	}
}

// Calls `fcn` (with the caller's context) for every shape whose fat AABB overlaps `aabb`.
world_overlap_aabb :: proc(
	world_id: World_Id,
	aabb: AABB,
	filter: Query_Filter,
	fcn: Overlap_Result_Fcn,
	user: rawptr,
) -> Tree_Stats {
	trampoline := Overlap_Trampoline{context, fcn, user}
	stats := box3d.World_OverlapAABB(
		world_id,
		transmute(box3d.AABB)aabb,
		transmute(box3d.QueryFilter)filter,
		overlap_trampoline,
		&trampoline,
	)
	return transmute(Tree_Stats)stats
}

// Calls `fcn` (with the caller's context) for every shape along the ray; its return value steers the cast.
world_cast_ray :: proc(
	world_id: World_Id,
	origin: [3]f32,
	translation: [3]f32,
	filter: Query_Filter,
	fcn: Cast_Result_Fcn,
	user: rawptr,
) -> Tree_Stats {
	trampoline := Cast_Trampoline{context, fcn, user}
	stats := box3d.World_CastRay(
		world_id,
		transmute(box3d.Vec3)origin,
		transmute(box3d.Vec3)translation,
		transmute(box3d.QueryFilter)filter,
		cast_trampoline,
		&trampoline,
	)
	return transmute(Tree_Stats)stats
}

// The closest hit along the ray; not ok: no hit.
world_cast_ray_closest :: proc(
	world_id: World_Id,
	origin: [3]f32,
	translation: [3]f32,
	filter: Query_Filter,
) -> (
	result: Ray_Result,
	ok: bool,
) {
	closest := box3d.World_CastRayClosest(
		world_id,
		transmute(box3d.Vec3)origin,
		transmute(box3d.Vec3)translation,
		transmute(box3d.QueryFilter)filter,
	)
	return (^Ray_Result)(&closest)^, closest.hit
}

// ---- snapshots and images (step boundaries only)

// Saves the world into `snapshot` (a copy of its arena: everything, so a restore continues bit-exactly).
world_save_snapshot :: proc(world_id: World_Id, snapshot: ^World_Snapshot) {
	box3d.World_SaveSnapshot(world_id, snapshot)
}

// Puts a snapshot back into the world it was saved from. False: the snapshot doesn't fit this world.
world_restore_snapshot :: proc(world_id: World_Id, snapshot: ^World_Snapshot) -> bool {
	return box3d.World_RestoreSnapshot(world_id, snapshot)
}

// Frees a snapshot's memory (it can be saved into again).
destroy_world_snapshot :: proc(snapshot: ^World_Snapshot) {
	box3d.DestroyWorldSnapshot(snapshot)
}

// A buffer for portable images (world_save_image). Free with destroy_world_state.
create_world_state :: proc() -> ^World_State {
	return box3d.CreateWorldState()
}

// Frees an image buffer.
destroy_world_state :: proc(state: ^World_State) {
	box3d.DestroyWorldState(state)
}

// The state's bytes (b3WorldState_GetData and GetSize): valid until the state is saved into again or destroyed.
world_state_get_data :: proc(state: ^World_State) -> []u8 {
	return box3d.WorldState_GetData(state)[:box3d.WorldState_GetSize(state)]
}

// Saves the world's canonical image into `state`; returns its size in bytes.
world_save_image :: proc(world_id: World_Id, state: ^World_State, with_geometry: bool) -> i32 {
	return box3d.World_SaveImage(world_id, state, with_geometry)
}

// Loads a portable image into the world. False: Box3D refused it (the world may be half-written).
world_load_image :: proc(world_id: World_Id, bytes: []u8) -> bool {
	return box3d.World_LoadImage(world_id, raw_data(bytes), i32(len(bytes)))
}

// The hash of the whole world's canonical image: every body, contact, warm start, joint, island and tree.
// What peers compare.
world_hash_state :: proc(world_id: World_Id) -> u64 {
	return box3d.World_HashState(world_id)
}

// The hash of the awake bodies (id, transform, velocities, in the solver's order) and so of which bodies are awake: a
// fraction of world_hash_state's cost, for a check every tick. Leaves out contacts, warm starts, joints, islands,
// trees and sleeping bodies.
world_hash_awake_bodies :: proc(world_id: World_Id) -> u64 {
	return box3d.World_HashAwakeBodies(world_id)
}

// ---- bodies

// Box3D's default body definition (a static body at the origin), to adjust before create_body.
default_body_def :: proc() -> Body_Def {
	return transmute(Body_Def)box3d.DefaultBodyDef()
}

// Creates a body (games use physics.create_body, which returns the block's reference).
create_body :: proc(world_id: World_Id, def: ^Body_Def) -> Body_Id {
	return box3d.CreateBody(world_id, (^box3d.BodyDef)(def))
}

// Destroys a body with its shapes and joints. Unchecked in the release library: physics.destroy_body checks first.
destroy_body :: proc(body_id: Body_Id) {
	box3d.DestroyBody(body_id)
}

// Whether the id names a live body (index and generation).
body_is_valid :: proc(id: Body_Id) -> bool {
	return box3d.Body_IsValid(id)
}

// Static, kinematic or dynamic.
body_get_type :: proc(body_id: Body_Id) -> Body_Type {
	return Body_Type(box3d.Body_GetType(body_id))
}

// The body origin's world position.
body_get_position :: proc(body_id: Body_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetPosition(body_id)
}

// The body's world rotation, a unit quaternion (x, y, z, w).
body_get_rotation :: proc(body_id: Body_Id) -> [4]f32 {
	return transmute([4]f32)box3d.Body_GetRotation(body_id)
}

// Moves the body to a pose (teleport: velocities are kept).
body_set_transform :: proc(body_id: Body_Id, position: [3]f32, rotation: [4]f32) {
	box3d.Body_SetTransform(body_id, transmute(box3d.Vec3)position, transmute(box3d.Quat)rotation)
}

// A world point in the body's frame.
body_get_local_point :: proc(body_id: Body_Id, world_point: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLocalPoint(body_id, transmute(box3d.Vec3)world_point)
}

// The centre of mass's velocity (m/s).
body_get_linear_velocity :: proc(body_id: Body_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLinearVelocity(body_id)
}

// The angular velocity (rad/s, world axes).
body_get_angular_velocity :: proc(body_id: Body_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetAngularVelocity(body_id)
}

// Sets the centre of mass's velocity.
body_set_linear_velocity :: proc(body_id: Body_Id, linear_velocity: [3]f32) {
	box3d.Body_SetLinearVelocity(body_id, transmute(box3d.Vec3)linear_velocity)
}

// Sets the angular velocity.
body_set_angular_velocity :: proc(body_id: Body_Id, angular_velocity: [3]f32) {
	box3d.Body_SetAngularVelocity(body_id, transmute(box3d.Vec3)angular_velocity)
}

// Adds an impulse (N·s) at the centre of mass; `wake` wakes a sleeping body.
body_apply_linear_impulse_to_center :: proc(body_id: Body_Id, impulse: [3]f32, wake: bool) {
	box3d.Body_ApplyLinearImpulseToCenter(body_id, transmute(box3d.Vec3)impulse, wake)
}

// The body's mass (kg), from its shapes' densities.
body_get_mass :: proc(body_id: Body_Id) -> f32 {
	return box3d.Body_GetMass(body_id)
}

// ---- shapes and geometry

// Box3D's default shape definition, to adjust before creating a shape.
default_shape_def :: proc() -> Shape_Def {
	return transmute(Shape_Def)box3d.DefaultShapeDef()
}

// The filter that sees every shape.
default_query_filter :: proc() -> Query_Filter {
	return transmute(Query_Filter)box3d.DefaultQueryFilter()
}

// Adds a sphere to a body.
create_sphere_shape :: proc(body_id: Body_Id, def: ^Shape_Def, sphere: ^Sphere) -> Shape_Id {
	return box3d.CreateSphereShape(body_id, (^box3d.ShapeDef)(def), (^box3d.Sphere)(sphere))
}

// Adds a capsule to a body.
create_capsule_shape :: proc(body_id: Body_Id, def: ^Shape_Def, capsule: ^Capsule) -> Shape_Id {
	return box3d.CreateCapsuleShape(body_id, (^box3d.ShapeDef)(def), (^box3d.Capsule)(capsule))
}

// Adds a convex hull to a body (Box3D copies the hull into its geometry database).
create_hull_shape :: proc(body_id: Body_Id, def: ^Shape_Def, hull: ^Hull_Data) -> Shape_Id {
	return box3d.CreateHullShape(body_id, (^box3d.ShapeDef)(def), hull)
}

// The body a shape belongs to.
shape_get_body :: proc(shape_id: Shape_Id) -> Body_Id {
	return box3d.Shape_GetBody(shape_id)
}

// Whether the shape is a sensor (detects overlaps, doesn't collide).
shape_is_sensor :: proc(shape_id: Shape_Id) -> bool {
	return box3d.Shape_IsSensor(shape_id)
}

// The convex hull of `points` (at most `max_vertex_count` vertices); nil when degenerate. Free with destroy_hull.
create_hull :: proc(points: [][3]f32, max_vertex_count: i32) -> ^Hull_Data {
	return box3d.CreateHull(([^]box3d.Vec3)(raw_data(points)), i32(len(points)), max_vertex_count)
}

// A copy of a hull moved by `transform` and scaled. Free with destroy_hull.
clone_and_transform_hull :: proc(original: ^Hull_Data, transform: Transform, scale: [3]f32) -> ^Hull_Data {
	return box3d.CloneAndTransformHull(original, transmute(box3d.Transform)transform, transmute(box3d.Vec3)scale)
}

// Frees a hull made by create_hull or clone_and_transform_hull.
destroy_hull :: proc(hull: ^Hull_Data) {
	box3d.DestroyHull(hull)
}

// A box hull with the given half extents, centred on the origin (by value, nothing to free).
make_box_hull :: proc(hx: f32, hy: f32, hz: f32) -> Box_Hull {
	return box3d.MakeBoxHull(hx, hy, hz)
}

// ---- joints

// Destroys a joint; `wake_attached` wakes its bodies.
destroy_joint :: proc(joint_id: Joint_Id, wake_attached: bool) {
	box3d.DestroyJoint(joint_id, wake_attached)
}

// Whether the id names a live joint (index and generation).
joint_is_valid :: proc(id: Joint_Id) -> bool {
	return box3d.Joint_IsValid(id)
}

// The joint's first body.
joint_get_body_a :: proc(joint_id: Joint_Id) -> Body_Id {
	return box3d.Joint_GetBodyA(joint_id)
}

// Moves the joint's frame on body A (in A's frame).
joint_set_local_frame_a :: proc(joint_id: Joint_Id, local_frame: Transform) {
	box3d.Joint_SetLocalFrameA(joint_id, transmute(box3d.Transform)local_frame)
}

// Moves the joint's frame on body B (in B's frame).
joint_set_local_frame_b :: proc(joint_id: Joint_Id, local_frame: Transform) {
	box3d.Joint_SetLocalFrameB(joint_id, transmute(box3d.Transform)local_frame)
}

// Box3D's default motor joint definition (drives B's pose relative to A).
default_motor_joint_def :: proc() -> Motor_Joint_Def {
	return transmute(Motor_Joint_Def)box3d.DefaultMotorJointDef()
}

// Creates a motor joint (games use it to hold things).
create_motor_joint :: proc(world_id: World_Id, def: ^Motor_Joint_Def) -> Joint_Id {
	return box3d.CreateMotorJoint(world_id, (^box3d.MotorJointDef)(def))
}

// Box3D's default mover joint definition (drives B to a target velocity relative to A).
default_mover_joint_def :: proc() -> Mover_Joint_Def {
	return transmute(Mover_Joint_Def)box3d.DefaultMoverJointDef()
}

// Creates a mover joint (the character's drive).
create_mover_joint :: proc(world_id: World_Id, def: ^Mover_Joint_Def) -> Joint_Id {
	return box3d.CreateMoverJoint(world_id, (^box3d.MoverJointDef)(def))
}

// The mover joint's target velocity of B relative to A.
mover_joint_set_linear_velocity :: proc(joint_id: Joint_Id, velocity: [3]f32) {
	box3d.MoverJoint_SetLinearVelocity(joint_id, transmute(box3d.Vec3)velocity)
}

// The force cap of the mover joint's velocity drive (0: no drive).
mover_joint_set_max_velocity_force :: proc(joint_id: Joint_Id, max_force: f32) {
	box3d.MoverJoint_SetMaxVelocityForce(joint_id, max_force)
}

// Box3D's default pogo joint definition (a spring along a normal).
default_pogo_joint_def :: proc() -> Pogo_Joint_Def {
	return transmute(Pogo_Joint_Def)box3d.DefaultPogoJointDef()
}

// Creates a pogo joint (the character's spring above the ground).
create_pogo_joint :: proc(world_id: World_Id, def: ^Pogo_Joint_Def) -> Joint_Id {
	return box3d.CreatePogoJoint(world_id, (^box3d.PogoJointDef)(def))
}

// The pogo spring's stiffness, as a frequency (Hz).
pogo_joint_set_spring_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.PogoJoint_SetSpringHertz(joint_id, hertz)
}

// The pogo spring's damping ratio (1: critical).
pogo_joint_set_spring_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.PogoJoint_SetSpringDampingRatio(joint_id, damping_ratio)
}

// The most force the pogo pulls with (0: it only pushes).
pogo_joint_set_max_tension_force :: proc(joint_id: Joint_Id, force: f32) {
	box3d.PogoJoint_SetMaxTensionForce(joint_id, force)
}

// The most force the pogo pushes with.
pogo_joint_set_max_compression_force :: proc(joint_id: Joint_Id, force: f32) {
	box3d.PogoJoint_SetMaxCompressionForce(joint_id, force)
}

// The direction the pogo acts along (unit, world).
pogo_joint_set_normal :: proc(joint_id: Joint_Id, normal: [3]f32) {
	box3d.PogoJoint_SetNormal(joint_id, transmute(box3d.Vec3)normal)
}

// The pogo's current extension speed (to warm start a replacement joint).
pogo_joint_get_current_speed :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PogoJoint_GetCurrentSpeed(joint_id)
}

// The pogo's last impulse (to warm start a replacement joint).
pogo_joint_get_impulse :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PogoJoint_GetImpulse(joint_id)
}

// ---- callback trampolines: the library calls back with C's convention; these restore the caller's context and
// call its Odin proc.

@(private)
Overlap_Trampoline :: struct {
	ctx:  runtime.Context,
	fcn:  Overlap_Result_Fcn,
	user: rawptr,
}

@(private)
overlap_trampoline :: proc "c" (shape_id: box3d.ShapeId, context_: rawptr) -> bool {
	trampoline := (^Overlap_Trampoline)(context_)
	context = trampoline.ctx
	return trampoline.fcn(shape_id, trampoline.user)
}

@(private)
Cast_Trampoline :: struct {
	ctx:  runtime.Context,
	fcn:  Cast_Result_Fcn,
	user: rawptr,
}

@(private)
cast_trampoline :: proc "c" (
	shape_id: box3d.ShapeId,
	point: box3d.Vec3,
	normal: box3d.Vec3,
	fraction: f32,
	user_material_id: u64,
	triangle_index: i32,
	child_index: i32,
	context_: rawptr,
) -> f32 {
	trampoline := (^Cast_Trampoline)(context_)
	context = trampoline.ctx
	return trampoline.fcn(
		shape_id,
		transmute([3]f32)point,
		transmute([3]f32)normal,
		fraction,
		user_material_id,
		triangle_index,
		child_index,
		trampoline.user,
	)
}
