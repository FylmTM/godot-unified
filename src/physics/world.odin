// The world's settings (src/physics/SPEC.md, What physics covers): gravity, explosions, the solver settings, bounds
// and the awake body count. Every setting lives in Box3D's world, so it rolls back with the snapshot (tested per
// setter: a setter that didn't is left out).
package physics

import "unified:b3"

Explosion_Def :: b3.Explosion_Def

default_explosion_def :: b3.default_explosion_def

// The world's gravity (m/s²).
world_gravity :: proc(world: ^World) -> [3]f32 {
	return b3.world_get_gravity(world.id)
}

// Sets the world's gravity (m/s²).
world_set_gravity :: proc(world: ^World, gravity: [3]f32) {
	b3.world_set_gravity(world.id, gravity)
}

// Applies an explosion's impulses to the spheres, capsules and hulls around it (Explosion_Def; from
// default_explosion_def).
world_explode :: proc(world: ^World, def: Explosion_Def) {
	def := def
	b3.world_explode(world.id, &def)
}

// Lets bodies sleep, or wakes every body and keeps them awake.
world_enable_sleeping :: proc(world: ^World, flag: bool) {
	b3.world_enable_sleeping(world.id, flag)
}

// Whether bodies may sleep.
world_is_sleeping_enabled :: proc(world: ^World) -> bool {
	return b3.world_is_sleeping_enabled(world.id)
}

// Turns continuous collision (fast bodies against static ones) on or off.
world_enable_continuous :: proc(world: ^World, flag: bool) {
	b3.world_enable_continuous(world.id, flag)
}

// Whether continuous collision is on.
world_is_continuous_enabled :: proc(world: ^World) -> bool {
	return b3.world_is_continuous_enabled(world.id)
}

// Turns warm starting (contact impulses carried between steps) on or off.
world_enable_warm_starting :: proc(world: ^World, flag: bool) {
	b3.world_enable_warm_starting(world.id, flag)
}

// Whether warm starting is on.
world_is_warm_starting_enabled :: proc(world: ^World) -> bool {
	return b3.world_is_warm_starting_enabled(world.id)
}

// Turns restitution propagation (bounces passed through stacks) on or off.
world_enable_restitution_propagation :: proc(world: ^World, flag: bool) {
	b3.world_enable_restitution_propagation(world.id, flag)
}

// Whether restitution propagates.
world_is_restitution_propagation_enabled :: proc(world: ^World) -> bool {
	return b3.world_is_restitution_propagation_enabled(world.id)
}

// Sets the approach speed (m/s) under which contacts don't bounce.
world_set_restitution_threshold :: proc(world: ^World, value: f32) {
	b3.world_set_restitution_threshold(world.id, value)
}

// The restitution threshold.
world_restitution_threshold :: proc(world: ^World) -> f32 {
	return b3.world_get_restitution_threshold(world.id)
}

// Sets how many restitution iterations the solver runs.
world_set_restitution_iterations :: proc(world: ^World, iterations: int) {
	b3.world_set_restitution_iterations(world.id, i32(iterations))
}

// The restitution iterations.
world_restitution_iterations :: proc(world: ^World) -> int {
	return int(b3.world_get_restitution_iterations(world.id))
}

// Sets the approach speed (m/s) above which contacts make hit events (Settings.hit_threshold at creation).
world_set_hit_event_threshold :: proc(world: ^World, value: f32) {
	b3.world_set_hit_event_threshold(world.id, value)
}

// The hit event threshold.
world_hit_event_threshold :: proc(world: ^World) -> f32 {
	return b3.world_get_hit_event_threshold(world.id)
}

// Sets the contact softness (stiffness as a frequency in Hz, damping ratio) and the speed (m/s) overlapping shapes
// are pushed apart at (Box3D has no getter).
world_set_contact_tuning :: proc(world: ^World, hertz, damping_ratio, contact_speed: f32) {
	b3.world_set_contact_tuning(world.id, hertz, damping_ratio, contact_speed)
}

// Sets how far (m) a recycling body may move before its contacts are rebuilt.
world_set_contact_recycle_distance :: proc(world: ^World, distance: f32) {
	b3.world_set_contact_recycle_distance(world.id, distance)
}

// The contact recycle distance.
world_contact_recycle_distance :: proc(world: ^World) -> f32 {
	return b3.world_get_contact_recycle_distance(world.id)
}

// Sets every body's speed limit (m/s).
world_set_maximum_linear_speed :: proc(world: ^World, speed: f32) {
	b3.world_set_maximum_linear_speed(world.id, speed)
}

// The speed limit.
world_maximum_linear_speed :: proc(world: ^World) -> f32 {
	return b3.world_get_maximum_linear_speed(world.id)
}

// Sets how close to a sphere's a body's inertia must be (relative) for the solver to treat it as one.
world_set_isotropic_inertia_tolerance :: proc(world: ^World, tolerance: f32) {
	b3.world_set_isotropic_inertia_tolerance(world.id, tolerance)
}

// The isotropic inertia tolerance.
world_isotropic_inertia_tolerance :: proc(world: ^World) -> f32 {
	return b3.world_get_isotropic_inertia_tolerance(world.id)
}

// The AABB of everything in the world.
world_bounds :: proc(world: ^World) -> AABB {
	return b3.world_get_bounds(world.id)
}

// The number of awake bodies.
world_awake_body_count :: proc(world: ^World) -> int {
	return int(b3.world_get_awake_body_count(world.id))
}
