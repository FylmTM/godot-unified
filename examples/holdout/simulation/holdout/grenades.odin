package holdout

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// What a grenade bounces off: the level, the core and the enemies (it passes through players, its thrower first).
GRENADE_MASK :: CAT_LEVEL | CAT_CORE | CAT_ENEMY | CAT_HEAD | CAT_GRENADE

// Each player who is up and pressed Grenade throws one when their GRENADE_COOLDOWN_S ran out (and one is free): a
// dynamic sphere in bullet mode, out of the hand their screen showed (shot_rewind), along their aim at GRENADE_SPEED
// plus their own velocity, its FUSE_S burning.
throw_grenades :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		if data.downed || .Grenade not_in sim.buttons(t, player).pressed || sim.timer_running(t, data.grenade) do continue
		grenade, handle := sim.spawn(&t.state.grenades) or_continue
		sim.timer_start(t, &data.grenade, GRENADE_COOLDOWN_S)
		input := sim.input(t, player)
		_, eye := shot_rewind(t, player, input)
		dir := dmath.aim_vec(input.aim)
		at := eye + dir * (PLAYER_RADIUS + GRENADE_RADIUS + 0.1)
		grenade^ = {
			thrower = player,
		}
		sim.timer_start(t, &grenade.fuse, FUSE_S)
		def := physics.body_def(.Dynamic, at)
		shape := physics.shape_def(CAT_GRENADE, GRENADE_MASK)
		shape.density = GRENADE_DENSITY
		shape.base_material.restitution = GRENADE_RESTITUTION
		grenade.body, _ = physics.create_sphere(t.world.phys, def, shape, GRENADE_RADIUS, sim.handle_key(handle))
		physics.body_set_bullet(t.world.phys, grenade.body, true)
		velocity := physics.body_linear_velocity(t.world.phys, data.controller.body)
		physics.body_set_linear_velocity(t.world.phys, grenade.body, dir * GRENADE_SPEED + velocity)
		sim.emit(t, Event_Grenade_Thrown{at = sim.Position(at), grenade = handle, player = player})
	}
}

// Each grenade whose fuse burned down, or that an enemy's capsule touches (TOUCH_RADIUS), explodes: every enemy whose
// capsule is within BLAST_RADIUS and in the open from it (a ray the level and the core don't block) takes BLAST_DAMAGE,
// falling to a third at the edge; loose bodies are pushed away.
burn_fuses :: proc(t: ^Tick) {
	phys := t.world.phys
	grenades := sim.iterate(&t.state.grenades)
	for grenade, handle in sim.next(&grenades) {
		at := physics.body_position(phys, grenade.body)
		touch := physics.make_proxy([][3]f32{{}}, TOUCH_RADIUS)
		physics.world_overlap_shape(phys, at, touch, &t.world.overlaps, {category = CAT_GRENADE, mask = CAT_ENEMY})
		if !sim.timer_fired(t, grenade.fuse) && len(t.world.overlaps) == 0 do continue
		thrower := grenade.thrower
		physics.despawn(phys, &t.state.grenades, handle)
		explode(t, at, thrower)
	}
}

// A blast at `at` set off by `thrower`'s grenade (BLAST_RADIUS, BLAST_DAMAGE).
explode :: proc(t: ^Tick, at: [3]f32, thrower: sim.Player) {
	phys := t.world.phys
	sim.emit(t, Event_Explosion{at = sim.Position(at)})
	blast := physics.make_proxy([][3]f32{{}}, BLAST_RADIUS)
	physics.world_overlap_shape(phys, at, blast, &t.world.overlaps, {category = CAT_GRENADE, mask = CAT_ENEMY})
	for overlap in t.world.overlaps {
		handle := sim.handle_of_key(Enemy, overlap.tag)
		enemy := sim.get(&t.state.enemies, handle)
		if enemy == nil do continue
		spec := &ENEMY_SPECS[enemy.kind]
		middle := enemy.pos + {0, spec.radius + spec.half_height, 0}
		if _, blocked := physics.world_cast_ray_closest(phys, at, middle - at, SIGHT_FILTER); blocked do continue
		near := 1 - dmath.min(dmath.length(middle - at) / BLAST_RADIUS, 1)
		damage := i16(f32(BLAST_DAMAGE) * (1 + 2 * near) / 3)
		damage_enemy(t, handle, damage, middle, false, thrower)
	}
	physics.world_explode(
		phys,
		{mask_bits = CAT_GRENADE, position = at, radius = BLAST_RADIUS, falloff = 1, impulse_per_area = 2},
	)
}
