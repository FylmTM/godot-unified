package survivor

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Destroyed barrels come back when due; barrels at HP <= 0 explode, in item order: an impulse on the bodies around
// (items and players within BLAST_RADIUS), damage to the enemies within it and to the players within
// BLAST_PLAYER_RADIUS.
explode_barrels :: proc(t: ^Tick) {
	for &item, i in t.state.items[:t.world.items.count] {
		if sim.slice(&t.world.items)[i].kind == .Barrel && !item.alive && item.respawn_tick == t.time {
			item_reset(t.state, t.world, i)
		}
	}
	for &item, i in t.state.items[:t.world.items.count] {
		if sim.slice(&t.world.items)[i].kind != .Barrel || !item.alive || item.hp > 0 {
			continue
		}
		center := physics.body_position(t.world.phys, item.body)
		for &other, j in t.state.items[:t.world.items.count] {
			if j != i && other.alive {
				blast(t.world, center, other.body)
			}
		}
		players := sim.iterate_present(t)
		for character in sim.next(&players) {
			if character.alive {
				blast(t.world, center, character.body)
			}
		}
		enemies := sim.iterate(&t.state.enemies)
		for enemy in sim.next(&enemies) {
			if dmath.dist_sq(enemy.pos, center.xz) < BLAST_RADIUS * BLAST_RADIUS {
				enemy.hp -= BLAST_ENEMY_DAMAGE
				enemy.hit_tick = t.time
			}
		}
		players = sim.iterate_present(t)
		for character, player in sim.next(&players) {
			if character.alive &&
			   dmath.dist_sq(character.pos.xz, center.xz) < BLAST_PLAYER_RADIUS * BLAST_PLAYER_RADIUS {
				damage_player(t, player, BLAST_PLAYER_DAMAGE)
			}
		}
		physics.destroy_body(t.world.phys, &item.body)
		sim.emit(t, Event_Barrel_Exploded{entity = sim.entity(i), position = sim.Position(center)})
		item.alive = false
		item.respawn_tick = t.time + BARREL_RESPAWN_TICKS
	}
}

// A barrel's blast on one body: away from the centre on the ground and up a little, from BLAST_IMPULSE at the centre to
// nothing at BLAST_RADIUS.
blast :: proc(world: ^World, center: [3]f32, body: physics.Body_Ref) {
	offset := physics.body_position(world.phys, body) - center
	distance := dmath.length(offset)
	if distance >= BLAST_RADIUS {
		return
	}
	away := dmath.normalize(offset.xz)
	direction := dmath.normalize([3]f32{away.x, BLAST_LIFT, away.y}, 0)
	strength := BLAST_IMPULSE * (1 - distance / BLAST_RADIUS)
	physics.body_apply_linear_impulse_to_center(world.phys, body, direction * strength)
}
