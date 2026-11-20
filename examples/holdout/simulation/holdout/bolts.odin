package holdout

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// What a bolt flies into: the level, the core and the players (enemies let it through).
BOLT_FILTER :: physics.Filter {
	category = CAT_ENEMY,
	mask     = CAT_LEVEL | CAT_CORE | CAT_PLAYER,
}

// A spitter's bolt from `from` toward `at`, at BOLT_SPEED for BOLT_LIFE_S, carrying `damage`. False when every bolt
// is in flight.
fire_bolt :: proc(t: ^Tick, from, at: [3]f32, damage: i16) -> bool {
	bolt, _ := sim.spawn(&t.state.bolts) or_return
	bolt^ = {
		pos    = from,
		vel    = dmath.normalize(at - from) * BOLT_SPEED,
		damage = damage,
	}
	sim.timer_start(t, &bolt.life, BOLT_LIFE_S)
	sim.emit(t, Event_Bolt_Fired{at = sim.Position(from)})
	return true
}

// Each bolt flies its tick's way, swept against the level, the core and the players (a ray from where it is to where
// it would be): a player it strikes takes its damage (a downed one isn't struck: it flies on), the core too, and it is
// gone; so is a bolt whose life ran out.
fly_bolts :: proc(t: ^Tick) {
	bolts := sim.iterate(&t.state.bolts)
	for bolt, handle in sim.next(&bolts) {
		step := bolt.vel * t.dt
		hit, struck := physics.world_cast_ray_closest(t.world.phys, bolt.pos, step, BOLT_FILTER)
		if struck && hit.category & CAT_PLAYER != 0 {
			player := sim.player_of_key(hit.tag)
			if data := sim.player_data(t, player); data != nil && data.downed do struck = false
			else do hurt_player(t, player, bolt.damage)
		} else if struck && hit.category & CAT_CORE != 0 {
			hurt_core(t, i32(bolt.damage))
		}
		if struck || sim.timer_fired(t, bolt.life) {
			sim.despawn(&t.state.bolts, handle)
			continue
		}
		bolt.pos += step
	}
}
