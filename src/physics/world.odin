// The world's settings (src/physics/README.md, What physics covers): gravity, explosions, the solver settings, bounds
// and the awake body count. Every setting lives in Box3D's world, so it rolls back with the snapshot (tested per
// setter: a setter that didn't is left out).
package physics

import box3d "box3d:bindings"


// Box3D's default explosion definition, to adjust before world_explode.
default_explosion_def :: proc() -> Explosion_Def {
	return transmute(Explosion_Def)box3d.DefaultExplosionDef()
}

// The world's gravity (m/s²).
world_gravity :: proc(world: ^World) -> [3]f32 {
	return transmute([3]f32)box3d.World_GetGravity(world.id)
}

// Sets the world's gravity (m/s²).
world_set_gravity :: proc(world: ^World, gravity: [3]f32) {
	box3d.World_SetGravity(world.id, transmute(box3d.Vec3)gravity)
}

// Applies an explosion's impulses to the spheres, capsules and hulls around it (Explosion_Def; from
// default_explosion_def).
world_explode :: proc(world: ^World, def: Explosion_Def) {
	def := def
	box3d.World_Explode(world.id, (^box3d.ExplosionDef)(&def))
}

// Lets bodies sleep, or wakes every body and keeps them awake.
world_enable_sleeping :: proc(world: ^World, flag: bool) {
	box3d.World_EnableSleeping(world.id, flag)
}

// Whether bodies may sleep.
world_is_sleeping_enabled :: proc(world: ^World) -> bool {
	return box3d.World_IsSleepingEnabled(world.id)
}

// Turns continuous collision (fast bodies against static ones) on or off.
world_enable_continuous :: proc(world: ^World, flag: bool) {
	box3d.World_EnableContinuous(world.id, flag)
}

// Whether continuous collision is on.
world_is_continuous_enabled :: proc(world: ^World) -> bool {
	return box3d.World_IsContinuousEnabled(world.id)
}

// Turns warm starting (contact impulses carried between steps) on or off.
world_enable_warm_starting :: proc(world: ^World, flag: bool) {
	box3d.World_EnableWarmStarting(world.id, flag)
}

// Whether warm starting is on.
world_is_warm_starting_enabled :: proc(world: ^World) -> bool {
	return box3d.World_IsWarmStartingEnabled(world.id)
}

// Turns restitution propagation (bounces passed through stacks) on or off.
world_enable_restitution_propagation :: proc(world: ^World, flag: bool) {
	box3d.World_EnableRestitutionPropagation(world.id, flag)
}

// Whether restitution propagates.
world_is_restitution_propagation_enabled :: proc(world: ^World) -> bool {
	return box3d.World_IsRestitutionPropagationEnabled(world.id)
}

// Sets the approach speed (m/s) under which contacts don't bounce.
world_set_restitution_threshold :: proc(world: ^World, value: f32) {
	box3d.World_SetRestitutionThreshold(world.id, value)
}

// The restitution threshold.
world_restitution_threshold :: proc(world: ^World) -> f32 {
	return box3d.World_GetRestitutionThreshold(world.id)
}

// Sets how many restitution iterations the solver runs.
world_set_restitution_iterations :: proc(world: ^World, iterations: int) {
	box3d.World_SetRestitutionIterations(world.id, i32(iterations))
}

// The restitution iterations.
world_restitution_iterations :: proc(world: ^World) -> int {
	return int(box3d.World_GetRestitutionIterations(world.id))
}

// Sets the approach speed (m/s) above which contacts make hit events (Settings.hit_event_threshold at creation).
world_set_hit_event_threshold :: proc(world: ^World, value: f32) {
	box3d.World_SetHitEventThreshold(world.id, value)
}

// The hit event threshold.
world_hit_event_threshold :: proc(world: ^World) -> f32 {
	return box3d.World_GetHitEventThreshold(world.id)
}

// Sets the contact softness (stiffness as a frequency in Hz, damping ratio) and the speed (m/s) overlapping shapes
// are pushed apart at (Box3D has no getter).
world_set_contact_tuning :: proc(world: ^World, hertz, damping_ratio, contact_speed: f32) {
	box3d.World_SetContactTuning(world.id, hertz, damping_ratio, contact_speed)
}

// Sets how far (m) a recycling body may move before its contacts are rebuilt.
world_set_contact_recycle_distance :: proc(world: ^World, distance: f32) {
	box3d.World_SetContactRecycleDistance(world.id, distance)
}

// The contact recycle distance.
world_contact_recycle_distance :: proc(world: ^World) -> f32 {
	return box3d.World_GetContactRecycleDistance(world.id)
}

// Sets every body's speed limit (m/s).
world_set_maximum_linear_speed :: proc(world: ^World, speed: f32) {
	box3d.World_SetMaximumLinearSpeed(world.id, speed)
}

// The speed limit.
world_maximum_linear_speed :: proc(world: ^World) -> f32 {
	return box3d.World_GetMaximumLinearSpeed(world.id)
}

// Sets how close to a sphere's a body's inertia must be (relative) for the solver to treat it as one.
world_set_isotropic_inertia_tolerance :: proc(world: ^World, tolerance: f32) {
	box3d.World_SetIsotropicInertiaTolerance(world.id, tolerance)
}

// The isotropic inertia tolerance.
world_isotropic_inertia_tolerance :: proc(world: ^World) -> f32 {
	return box3d.World_GetIsotropicInertiaTolerance(world.id)
}

// The AABB of everything in the world.
world_bounds :: proc(world: ^World) -> AABB {
	return transmute(AABB)box3d.World_GetBounds(world.id)
}

// The number of awake bodies.
world_awake_body_count :: proc(world: ^World) -> int {
	return int(box3d.World_GetAwakeBodyCount(world.id))
}
