package holdout

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// What a keyed roll is for (sim.roll_below's purpose).
Roll :: enum u8 {
	Spread,
}

// What a shot can strike: the level, the core, an enemy's body or head (never a player: no friendly fire).
SHOT_FILTER :: physics.Filter {
	category = CAT_PLAYER,
	mask     = CAT_LEVEL | CAT_CORE | CAT_ENEMY | CAT_HEAD,
}

// Every player who is up and holds Fire shoots once their FIRE_INTERVAL_TICKS ran out: a ray from their eye along
// their aim, strayed by up to SPREAD (a keyed roll), cast on the world as its shooter saw it (shot_rewind). An enemy
// struck takes RIFLE_DAMAGE, HEADSHOT_MULT times that on its head shape.
fire_rifles :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		if data.downed || .Fire not_in sim.buttons(t, player).down || sim.timer_running(t, data.fire_ready) do continue
		sim.timer_start_ticks(t, &data.fire_ready, FIRE_INTERVAL_TICKS)
		input := sim.input(t, player)
		rewind, eye := shot_rewind(t, player, input)
		key := sim.player_key(player)
		stray := [2]f32{spread_roll(t, key, 0), spread_roll(t, key, 1)} * SPREAD
		_, right := dmath.aim_flat(input.aim)
		dir := dmath.aim_vec(input.aim)
		up := dmath.cross3(right, dir)
		dir = dmath.normalize(dir + right * stray.x + up * stray.y)
		hit, struck := physics.world_cast_ray_closest_rewound(
			t.world.phys,
			eye,
			dir * RIFLE_RANGE,
			rewind,
			SHOT_FILTER,
		)
		to := struck ? hit.point : eye + dir * RIFLE_RANGE
		on_enemy := false
		if struck && hit.category & (CAT_ENEMY | CAT_HEAD) != 0 {
			enemy := sim.handle_of_key(Enemy, hit.tag)
			if sim.get(&t.state.enemies, enemy) != nil {
				on_enemy = true
				headshot := hit.category & CAT_HEAD != 0
				damage_enemy(t, enemy, RIFLE_DAMAGE * (HEADSHOT_MULT if headshot else 1), hit.point, headshot, player)
			}
		}
		sim.emit(t, Event_Shot{from = sim.Position(eye), to = sim.Position(to), player = player, hit = on_enemy})
	}
}

// How far back a player's shot or throw looks (sim.seen_rewind of their input, at most MAX_REWIND_S) and their eye
// then: moved back by their own velocity, so a strafing shooter's ray leaves from where their screen showed them.
shot_rewind :: proc(t: ^Tick, player: sim.Player, input: Input) -> (rewind: f32, eye: [3]f32) {
	rewind = sim.seen_rewind(t, input.seen, MAX_REWIND_S)
	body := sim.player_data(t, player).controller.body
	return rewind, player_eye(t, player) - physics.body_linear_velocity(t.world.phys, body) * rewind
}

// A shot's stray along one axis (`axis` 0 or 1), uniform in [-1, 1].
spread_roll :: proc(t: ^Tick, key: u64, axis: int) -> f32 {
	return f32(sim.roll_below(t, 2049, Roll.Spread, key, axis)) / 1024 - 1
}
