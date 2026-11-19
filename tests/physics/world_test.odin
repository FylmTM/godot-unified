// The World group (src/physics/README.md, What physics covers): every world proc once, through physics. A setter is
// covered only if it rolls back: set a value, save a ring slot through physics.extra, change it, restore, read it
// back. Contact tuning, which Box3D has no getter for, is read back by behaviour. (World_EnableSpeculative is left
// out: no getter, and this Box3D stores the flag without reading it, so nothing shows it.)
package test_physics

import "core:testing"

import "unified:physics"
import "unified:sim"

World_Block :: struct {
	body: physics.Body_Ref,
}

@(test)
world_setters_roll_back :: proc(t: ^testing.T) {
	world := api_world()
	defer physics.destroy(world)
	extra := physics.extra(world, World_Block)

	physics.world_set_gravity(world, {1, -2, 3})
	extra.save(extra.data, 0)
	physics.world_set_gravity(world, {0, -5, 0})
	testing.expect_value(t, physics.world_gravity(world), [3]f32{0, -5, 0})
	testing.expect(t, extra.restore(extra.data, 0))
	testing.expect_value(t, physics.world_gravity(world), [3]f32{1, -2, 3})

	flags := []struct {
		enable: proc(world: ^physics.World, flag: bool),
		is:     proc(world: ^physics.World) -> bool,
	} {
		{physics.world_enable_sleeping, physics.world_is_sleeping_enabled},
		{physics.world_enable_continuous, physics.world_is_continuous_enabled},
		{physics.world_enable_warm_starting, physics.world_is_warm_starting_enabled},
		{physics.world_enable_restitution_propagation, physics.world_is_restitution_propagation_enabled},
	}
	for flag, i in flags {
		for saved in ([]bool{false, true}) {
			flag.enable(world, saved)
			extra.save(extra.data, 1)
			flag.enable(world, !saved)
			testing.expectf(t, flag.is(world) == !saved, "flag %d: the setter sets", i)
			testing.expect(t, extra.restore(extra.data, 1))
			testing.expectf(t, flag.is(world) == saved, "flag %d: rolls back to %v", i, saved)
		}
	}

	values := []struct {
		set: proc(world: ^physics.World, value: f32),
		get: proc(world: ^physics.World) -> f32,
	} {
		{physics.world_set_restitution_threshold, physics.world_restitution_threshold},
		{physics.world_set_hit_event_threshold, physics.world_hit_event_threshold},
		{physics.world_set_contact_recycle_distance, physics.world_contact_recycle_distance},
		{physics.world_set_maximum_linear_speed, physics.world_maximum_linear_speed},
		{physics.world_set_isotropic_inertia_tolerance, physics.world_isotropic_inertia_tolerance},
	}
	for value, i in values {
		value.set(world, 0.375)
		extra.save(extra.data, 2)
		value.set(world, 0.625)
		testing.expectf(t, value.get(world) == 0.625, "value %d: the setter sets", i)
		testing.expect(t, extra.restore(extra.data, 2))
		testing.expectf(t, value.get(world) == 0.375, "value %d: rolls back", i)
	}

	physics.world_set_restitution_iterations(world, 3)
	extra.save(extra.data, 3)
	physics.world_set_restitution_iterations(world, 7)
	testing.expect_value(t, physics.world_restitution_iterations(world), 7)
	testing.expect(t, extra.restore(extra.data, 3))
	testing.expect_value(t, physics.world_restitution_iterations(world), 3)

	// The worker count is a setting, not state: it never rolls back (results are the same for any count).
	physics.world_set_worker_count(world, 4)
	testing.expect_value(t, physics.world_worker_count(world), 4)
}

// A box sunk 0.2 m into the ground and another falling onto it fast: how hard contacts push (contact tuning) changes
// where they end up.
Tuning_Scene :: struct {
	world:  ^physics.World,
	extra:  sim.Extra,
	bodies: [2]physics.Body_Ref,
}

tuning_scene :: proc() -> (scene: Tuning_Scene) {
	scene.world = api_world()
	box(scene.world, {0, -0.5, 0}, {10, 0.5, 10}, .Static)
	scene.bodies[0], _ = box(scene.world, {0, 0.3, 0}, {0.5, 0.5, 0.5}, .Dynamic)
	scene.bodies[1], _ = box(scene.world, {0.25, 2, 0}, {0.5, 0.5, 0.5}, .Dynamic)
	physics.body_set_linear_velocity(scene.world, scene.bodies[1], {0, -40, 0})
	scene.extra = physics.extra(scene.world, World_Block)
	return
}

tuning_outcome :: proc(scene: ^Tuning_Scene) -> (outcome: [4][3]f32) {
	steps(scene.world, 20)
	for body, i in scene.bodies {
		outcome[2 * i] = physics.body_position(scene.world, body)
		outcome[2 * i + 1] = physics.body_linear_velocity(scene.world, body)
	}
	physics.destroy(scene.world)
	return
}

@(test)
world_contact_tuning_rolls_back :: proc(t: ^testing.T) {
	// Soft and slow (A) against stiff and fast (B): A, saved, changed to B and restored, runs as A.
	soft, stiff, rolled := tuning_scene(), tuning_scene(), tuning_scene()
	physics.world_set_contact_tuning(soft.world, 5, 0.5, 0.5)
	physics.world_set_contact_tuning(stiff.world, 60, 10, 10)
	physics.world_set_contact_tuning(rolled.world, 5, 0.5, 0.5)
	rolled.extra.save(rolled.extra.data, 0)
	physics.world_set_contact_tuning(rolled.world, 60, 10, 10)
	testing.expect(t, rolled.extra.restore(rolled.extra.data, 0))
	soft_outcome, stiff_outcome := tuning_outcome(&soft), tuning_outcome(&stiff)
	testing.expect(t, soft_outcome != stiff_outcome, "the tuning changes the outcome")
	testing.expect_value(t, tuning_outcome(&rolled), soft_outcome)
}

@(test)
world_explode_bounds_and_awake_count :: proc(t: ^testing.T) {
	world := api_world([3]f32{})
	defer physics.destroy(world)
	left, _ := box(world, {-2, 0, 0}, {0.5, 0.5, 0.5}, .Dynamic)
	right, _ := box(world, {2, 0, 0}, {0.5, 0.5, 0.5}, .Dynamic)
	far, _ := box(world, {0, 0, 50}, {0.5, 0.5, 0.5}, .Dynamic)
	box(world, {0, -20, 0}, {1, 1, 1}, .Static)
	explosion := physics.default_explosion_def()
	explosion.position = {}
	explosion.radius = 3
	explosion.falloff = 1
	explosion.impulse_per_area = 2
	physics.world_explode(world, explosion)
	testing.expect(t, physics.body_linear_velocity(world, left).x < 0, "pushed away from the centre")
	testing.expect(t, physics.body_linear_velocity(world, right).x > 0)
	testing.expect_value(t, physics.body_linear_velocity(world, far), [3]f32{})

	bounds := physics.world_bounds(world)
	testing.expectf(t, bounds.lower_bound.x <= -2.5 && bounds.upper_bound.x >= 2.5, "bounds %v", bounds)
	testing.expectf(t, bounds.lower_bound.y <= -21 && bounds.upper_bound.z >= 50.5, "bounds %v", bounds)

	testing.expect_value(t, physics.world_awake_body_count(world), 3) // the static body never counts
	physics.body_set_awake(world, far, false)
	testing.expect_value(t, physics.world_awake_body_count(world), 2)
}
