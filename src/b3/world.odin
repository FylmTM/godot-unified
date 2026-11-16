// Box3D's world procs beyond b3.odin's (src/b3/SPEC.md): gravity, explosions, the solver settings, bounds, the body
// and joint events and the mover queries physics wraps.
package b3

import "base:runtime"
import box3d "box3d:bindings"

// Sets the world's gravity (m/s²).
world_set_gravity :: proc(world_id: World_Id, gravity: [3]f32) {
	box3d.World_SetGravity(world_id, transmute(box3d.Vec3)gravity)
}

// Box3D's default explosion definition, to adjust before world_explode.
default_explosion_def :: proc() -> Explosion_Def {
	return transmute(Explosion_Def)box3d.DefaultExplosionDef()
}

// Applies an explosion's impulses to the shapes around it (Explosion_Def).
world_explode :: proc(world_id: World_Id, def: ^Explosion_Def) {
	box3d.World_Explode(world_id, (^box3d.ExplosionDef)(def))
}

// Lets bodies sleep, or wakes every body and keeps them awake.
world_enable_sleeping :: proc(world_id: World_Id, flag: bool) {
	box3d.World_EnableSleeping(world_id, flag)
}

// Whether bodies may sleep.
world_is_sleeping_enabled :: proc(world_id: World_Id) -> bool {
	return box3d.World_IsSleepingEnabled(world_id)
}

// Turns continuous collision (dynamic against static) on or off.
world_enable_continuous :: proc(world_id: World_Id, flag: bool) {
	box3d.World_EnableContinuous(world_id, flag)
}

// Whether continuous collision is on.
world_is_continuous_enabled :: proc(world_id: World_Id) -> bool {
	return box3d.World_IsContinuousEnabled(world_id)
}

// Sets the approach speed (m/s) under which contacts don't bounce.
world_set_restitution_threshold :: proc(world_id: World_Id, value: f32) {
	box3d.World_SetRestitutionThreshold(world_id, value)
}

// The restitution threshold.
world_get_restitution_threshold :: proc(world_id: World_Id) -> f32 {
	return box3d.World_GetRestitutionThreshold(world_id)
}

// Sets how many restitution iterations the solver runs.
world_set_restitution_iterations :: proc(world_id: World_Id, iterations: i32) {
	box3d.World_SetRestitutionIterations(world_id, iterations)
}

// The restitution iterations.
world_get_restitution_iterations :: proc(world_id: World_Id) -> i32 {
	return box3d.World_GetRestitutionIterations(world_id)
}

// Turns restitution propagation (bounces passed through stacks) on or off.
world_enable_restitution_propagation :: proc(world_id: World_Id, flag: bool) {
	box3d.World_EnableRestitutionPropagation(world_id, flag)
}

// Whether restitution propagates.
world_is_restitution_propagation_enabled :: proc(world_id: World_Id) -> bool {
	return box3d.World_IsRestitutionPropagationEnabled(world_id)
}

// Sets the approach speed (m/s) above which contacts make hit events.
world_set_hit_event_threshold :: proc(world_id: World_Id, value: f32) {
	box3d.World_SetHitEventThreshold(world_id, value)
}

// The hit event threshold.
world_get_hit_event_threshold :: proc(world_id: World_Id) -> f32 {
	return box3d.World_GetHitEventThreshold(world_id)
}

// Sets the contact softness (stiffness as a frequency, damping ratio) and the speed contacts push apart at.
world_set_contact_tuning :: proc(world_id: World_Id, hertz, damping_ratio, contact_speed: f32) {
	box3d.World_SetContactTuning(world_id, hertz, damping_ratio, contact_speed)
}

// Sets how far (m) a recycling body may move before its contacts are rebuilt.
world_set_contact_recycle_distance :: proc(world_id: World_Id, recycle_distance: f32) {
	box3d.World_SetContactRecycleDistance(world_id, recycle_distance)
}

// The contact recycle distance.
world_get_contact_recycle_distance :: proc(world_id: World_Id) -> f32 {
	return box3d.World_GetContactRecycleDistance(world_id)
}

// Sets the speed limit (m/s) of every body.
world_set_maximum_linear_speed :: proc(world_id: World_Id, maximum_linear_speed: f32) {
	box3d.World_SetMaximumLinearSpeed(world_id, maximum_linear_speed)
}

// The speed limit.
world_get_maximum_linear_speed :: proc(world_id: World_Id) -> f32 {
	return box3d.World_GetMaximumLinearSpeed(world_id)
}

// Sets how close to a sphere's inertia a body's must be to be treated as one (relative).
world_set_isotropic_inertia_tolerance :: proc(world_id: World_Id, tolerance: f32) {
	box3d.World_SetIsotropicInertiaTolerance(world_id, tolerance)
}

// The isotropic inertia tolerance.
world_get_isotropic_inertia_tolerance :: proc(world_id: World_Id) -> f32 {
	return box3d.World_GetIsotropicInertiaTolerance(world_id)
}

// Turns warm starting (contact impulses carried between steps) on or off.
world_enable_warm_starting :: proc(world_id: World_Id, flag: bool) {
	box3d.World_EnableWarmStarting(world_id, flag)
}

// Whether warm starting is on.
world_is_warm_starting_enabled :: proc(world_id: World_Id) -> bool {
	return box3d.World_IsWarmStartingEnabled(world_id)
}

// The AABB of every body in the world.
world_get_bounds :: proc(world_id: World_Id) -> AABB {
	return transmute(AABB)box3d.World_GetBounds(world_id)
}

// The number of awake bodies.
world_get_awake_body_count :: proc(world_id: World_Id) -> i32 {
	return box3d.World_GetAwakeBodyCount(world_id)
}

// The last step's body move events: a slice into Box3D's memory, valid until the next step.
world_get_body_events :: proc(world_id: World_Id) -> []Body_Move_Event {
	events := box3d.World_GetBodyEvents(world_id)
	return ([^]Body_Move_Event)(events.moveEvents)[:events.moveCount]
}

// The last step's joint events: a slice into Box3D's memory, valid until the next step.
world_get_joint_events :: proc(world_id: World_Id) -> []Joint_Event {
	events := box3d.World_GetJointEvents(world_id)
	return ([^]Joint_Event)(events.jointEvents)[:events.count]
}

// How far (a fraction of `translation`) a mover capsule at `origin` sweeps before it hits a shape; 1: no hit. `fcn`
// (with the caller's context; nil: every shape) decides which shapes count. Shapes it starts inside are skipped.
world_cast_mover :: proc(
	world_id: World_Id,
	origin: [3]f32,
	mover: ^Capsule,
	translation: [3]f32,
	filter: Query_Filter,
	fcn: Mover_Filter_Fcn,
	user: rawptr,
) -> f32 {
	trampoline := Mover_Filter_Trampoline{context, fcn, user}
	return box3d.World_CastMover(
		world_id,
		transmute(box3d.Vec3)origin,
		(^box3d.Capsule)(mover),
		transmute(box3d.Vec3)translation,
		transmute(box3d.QueryFilter)filter,
		fcn != nil ? mover_filter_trampoline : nil,
		&trampoline,
	)
}

// Calls `fcn` (with the caller's context) with each shape's planes against a mover capsule at `origin`.
world_collide_mover :: proc(
	world_id: World_Id,
	origin: [3]f32,
	mover: ^Capsule,
	filter: Query_Filter,
	fcn: Plane_Result_Fcn,
	user: rawptr,
) {
	trampoline := Plane_Result_Trampoline{context, fcn, user}
	box3d.World_CollideMover(
		world_id,
		transmute(box3d.Vec3)origin,
		(^box3d.Capsule)(mover),
		transmute(box3d.QueryFilter)filter,
		plane_result_trampoline,
		&trampoline,
	)
}

@(private)
Mover_Filter_Trampoline :: struct {
	ctx:  runtime.Context,
	fcn:  Mover_Filter_Fcn,
	user: rawptr,
}

@(private)
mover_filter_trampoline :: proc "c" (shape_id: box3d.ShapeId, context_: rawptr) -> bool {
	trampoline := (^Mover_Filter_Trampoline)(context_)
	context = trampoline.ctx
	return trampoline.fcn(shape_id, trampoline.user)
}

@(private)
Plane_Result_Trampoline :: struct {
	ctx:  runtime.Context,
	fcn:  Plane_Result_Fcn,
	user: rawptr,
}

@(private)
plane_result_trampoline :: proc "c" (
	shape_id: box3d.ShapeId,
	planes: ^box3d.PlaneResult,
	plane_count: i32,
	context_: rawptr,
) -> bool {
	trampoline := (^Plane_Result_Trampoline)(context_)
	context = trampoline.ctx
	return trampoline.fcn(shape_id, ([^]Plane_Result)(planes)[:plane_count], trampoline.user)
}
