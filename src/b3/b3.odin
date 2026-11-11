package b3

import "base:runtime"
import box3d "box3d:bindings"

// ---- world

default_world_def :: proc() -> World_Def {
	return transmute(World_Def)box3d.DefaultWorldDef()
}

create_world :: proc(def: ^World_Def) -> World_Id {
	return box3d.CreateWorld((^box3d.WorldDef)(def))
}

destroy_world :: proc(world_id: World_Id) {
	box3d.DestroyWorld(world_id)
}

world_step :: proc(world_id: World_Id, time_step: f32, sub_step_count: i32) {
	box3d.World_Step(world_id, time_step, sub_step_count)
}

world_get_gravity :: proc(world_id: World_Id) -> [3]f32 {
	return transmute([3]f32)box3d.World_GetGravity(world_id)
}

// The last step's contact events: slices into Box3D's memory, valid until the next step.
world_get_contact_events :: proc(world_id: World_Id) -> Contact_Events {
	ev := box3d.World_GetContactEvents(world_id)
	return {
		begin_events = ([^]Contact_Begin_Touch_Event)(ev.beginEvents)[:ev.beginCount],
		end_events = ([^]Contact_End_Touch_Event)(ev.endEvents)[:ev.endCount],
		hit_events = ([^]Contact_Hit_Event)(ev.hitEvents)[:ev.hitCount],
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
	t := Overlap_Trampoline{context, fcn, user}
	s := box3d.World_OverlapAABB(
		world_id,
		transmute(box3d.AABB)aabb,
		transmute(box3d.QueryFilter)filter,
		overlap_trampoline,
		&t,
	)
	return transmute(Tree_Stats)s
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
	t := Cast_Trampoline{context, fcn, user}
	s := box3d.World_CastRay(
		world_id,
		transmute(box3d.Vec3)origin,
		transmute(box3d.Vec3)translation,
		transmute(box3d.QueryFilter)filter,
		cast_trampoline,
		&t,
	)
	return transmute(Tree_Stats)s
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
	r := box3d.World_CastRayClosest(
		world_id,
		transmute(box3d.Vec3)origin,
		transmute(box3d.Vec3)translation,
		transmute(box3d.QueryFilter)filter,
	)
	return (^Ray_Result)(&r)^, r.hit
}

// ---- snapshots and images (step boundaries only)

world_save_snapshot :: proc(world_id: World_Id, snapshot: ^World_Snapshot) {
	box3d.World_SaveSnapshot(world_id, snapshot)
}

world_restore_snapshot :: proc(world_id: World_Id, snapshot: ^World_Snapshot) -> bool {
	return box3d.World_RestoreSnapshot(world_id, snapshot)
}

destroy_world_snapshot :: proc(snapshot: ^World_Snapshot) {
	box3d.DestroyWorldSnapshot(snapshot)
}

create_world_state :: proc() -> ^World_State {
	return box3d.CreateWorldState()
}

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

world_load_image :: proc(world_id: World_Id, bytes: []u8) -> bool {
	return box3d.World_LoadImage(world_id, raw_data(bytes), i32(len(bytes)))
}

world_hash_state :: proc(world_id: World_Id) -> u64 {
	return box3d.World_HashState(world_id)
}

// ---- bodies

default_body_def :: proc() -> Body_Def {
	return transmute(Body_Def)box3d.DefaultBodyDef()
}

create_body :: proc(world_id: World_Id, def: ^Body_Def) -> Body_Id {
	return box3d.CreateBody(world_id, (^box3d.BodyDef)(def))
}

destroy_body :: proc(body_id: Body_Id) {
	box3d.DestroyBody(body_id)
}

body_is_valid :: proc(id: Body_Id) -> bool {
	return box3d.Body_IsValid(id)
}

body_get_type :: proc(body_id: Body_Id) -> Body_Type {
	return Body_Type(box3d.Body_GetType(body_id))
}

body_get_position :: proc(body_id: Body_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetPosition(body_id)
}

body_get_rotation :: proc(body_id: Body_Id) -> [4]f32 {
	return transmute([4]f32)box3d.Body_GetRotation(body_id)
}

body_set_transform :: proc(body_id: Body_Id, position: [3]f32, rotation: [4]f32) {
	box3d.Body_SetTransform(body_id, transmute(box3d.Vec3)position, transmute(box3d.Quat)rotation)
}

body_get_local_point :: proc(body_id: Body_Id, world_point: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLocalPoint(body_id, transmute(box3d.Vec3)world_point)
}

body_get_linear_velocity :: proc(body_id: Body_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetLinearVelocity(body_id)
}

body_get_angular_velocity :: proc(body_id: Body_Id) -> [3]f32 {
	return transmute([3]f32)box3d.Body_GetAngularVelocity(body_id)
}

body_set_linear_velocity :: proc(body_id: Body_Id, linear_velocity: [3]f32) {
	box3d.Body_SetLinearVelocity(body_id, transmute(box3d.Vec3)linear_velocity)
}

body_set_angular_velocity :: proc(body_id: Body_Id, angular_velocity: [3]f32) {
	box3d.Body_SetAngularVelocity(body_id, transmute(box3d.Vec3)angular_velocity)
}

body_apply_linear_impulse_to_center :: proc(body_id: Body_Id, impulse: [3]f32, wake: bool) {
	box3d.Body_ApplyLinearImpulseToCenter(body_id, transmute(box3d.Vec3)impulse, wake)
}

body_get_mass :: proc(body_id: Body_Id) -> f32 {
	return box3d.Body_GetMass(body_id)
}

// ---- shapes and geometry

default_shape_def :: proc() -> Shape_Def {
	return transmute(Shape_Def)box3d.DefaultShapeDef()
}

default_query_filter :: proc() -> Query_Filter {
	return transmute(Query_Filter)box3d.DefaultQueryFilter()
}

create_sphere_shape :: proc(body_id: Body_Id, def: ^Shape_Def, sphere: ^Sphere) -> Shape_Id {
	return box3d.CreateSphereShape(body_id, (^box3d.ShapeDef)(def), (^box3d.Sphere)(sphere))
}

create_capsule_shape :: proc(body_id: Body_Id, def: ^Shape_Def, capsule: ^Capsule) -> Shape_Id {
	return box3d.CreateCapsuleShape(body_id, (^box3d.ShapeDef)(def), (^box3d.Capsule)(capsule))
}

create_hull_shape :: proc(body_id: Body_Id, def: ^Shape_Def, hull: ^Hull_Data) -> Shape_Id {
	return box3d.CreateHullShape(body_id, (^box3d.ShapeDef)(def), hull)
}

shape_get_body :: proc(shape_id: Shape_Id) -> Body_Id {
	return box3d.Shape_GetBody(shape_id)
}

shape_is_sensor :: proc(shape_id: Shape_Id) -> bool {
	return box3d.Shape_IsSensor(shape_id)
}

// The convex hull of `points` (at most `max_vertex_count` vertices); nil when degenerate. Free with destroy_hull.
create_hull :: proc(points: [][3]f32, max_vertex_count: i32) -> ^Hull_Data {
	return box3d.CreateHull(([^]box3d.Vec3)(raw_data(points)), i32(len(points)), max_vertex_count)
}

clone_and_transform_hull :: proc(original: ^Hull_Data, transform: Transform, scale: [3]f32) -> ^Hull_Data {
	return box3d.CloneAndTransformHull(original, transmute(box3d.Transform)transform, transmute(box3d.Vec3)scale)
}

destroy_hull :: proc(hull: ^Hull_Data) {
	box3d.DestroyHull(hull)
}

make_box_hull :: proc(hx: f32, hy: f32, hz: f32) -> Box_Hull {
	return box3d.MakeBoxHull(hx, hy, hz)
}

// ---- joints

destroy_joint :: proc(joint_id: Joint_Id, wake_attached: bool) {
	box3d.DestroyJoint(joint_id, wake_attached)
}

joint_is_valid :: proc(id: Joint_Id) -> bool {
	return box3d.Joint_IsValid(id)
}

joint_get_body_a :: proc(joint_id: Joint_Id) -> Body_Id {
	return box3d.Joint_GetBodyA(joint_id)
}

joint_set_local_frame_a :: proc(joint_id: Joint_Id, local_frame: Transform) {
	box3d.Joint_SetLocalFrameA(joint_id, transmute(box3d.Transform)local_frame)
}

joint_set_local_frame_b :: proc(joint_id: Joint_Id, local_frame: Transform) {
	box3d.Joint_SetLocalFrameB(joint_id, transmute(box3d.Transform)local_frame)
}

default_motor_joint_def :: proc() -> Motor_Joint_Def {
	return transmute(Motor_Joint_Def)box3d.DefaultMotorJointDef()
}

create_motor_joint :: proc(world_id: World_Id, def: ^Motor_Joint_Def) -> Joint_Id {
	return box3d.CreateMotorJoint(world_id, (^box3d.MotorJointDef)(def))
}

default_mover_joint_def :: proc() -> Mover_Joint_Def {
	return transmute(Mover_Joint_Def)box3d.DefaultMoverJointDef()
}

create_mover_joint :: proc(world_id: World_Id, def: ^Mover_Joint_Def) -> Joint_Id {
	return box3d.CreateMoverJoint(world_id, (^box3d.MoverJointDef)(def))
}

mover_joint_set_linear_velocity :: proc(joint_id: Joint_Id, velocity: [3]f32) {
	box3d.MoverJoint_SetLinearVelocity(joint_id, transmute(box3d.Vec3)velocity)
}

mover_joint_set_max_velocity_force :: proc(joint_id: Joint_Id, max_force: f32) {
	box3d.MoverJoint_SetMaxVelocityForce(joint_id, max_force)
}

default_pogo_joint_def :: proc() -> Pogo_Joint_Def {
	return transmute(Pogo_Joint_Def)box3d.DefaultPogoJointDef()
}

create_pogo_joint :: proc(world_id: World_Id, def: ^Pogo_Joint_Def) -> Joint_Id {
	return box3d.CreatePogoJoint(world_id, (^box3d.PogoJointDef)(def))
}

pogo_joint_set_spring_hertz :: proc(joint_id: Joint_Id, hertz: f32) {
	box3d.PogoJoint_SetSpringHertz(joint_id, hertz)
}

pogo_joint_set_spring_damping_ratio :: proc(joint_id: Joint_Id, damping_ratio: f32) {
	box3d.PogoJoint_SetSpringDampingRatio(joint_id, damping_ratio)
}

pogo_joint_set_max_tension_force :: proc(joint_id: Joint_Id, force: f32) {
	box3d.PogoJoint_SetMaxTensionForce(joint_id, force)
}

pogo_joint_set_max_compression_force :: proc(joint_id: Joint_Id, force: f32) {
	box3d.PogoJoint_SetMaxCompressionForce(joint_id, force)
}

pogo_joint_set_normal :: proc(joint_id: Joint_Id, normal: [3]f32) {
	box3d.PogoJoint_SetNormal(joint_id, transmute(box3d.Vec3)normal)
}

pogo_joint_get_current_speed :: proc(joint_id: Joint_Id) -> f32 {
	return box3d.PogoJoint_GetCurrentSpeed(joint_id)
}

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
	t := (^Overlap_Trampoline)(context_)
	context = t.ctx
	return t.fcn(shape_id, t.user)
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
	t := (^Cast_Trampoline)(context_)
	context = t.ctx
	return t.fcn(
		shape_id,
		transmute([3]f32)point,
		transmute([3]f32)normal,
		fraction,
		user_material_id,
		triangle_index,
		child_index,
		t.user,
	)
}
