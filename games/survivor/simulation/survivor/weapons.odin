package survivor

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// The auto-attack: every fire interval, each alive player shoots at the nearest enemy within FIRE_RANGE.
fire :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character in sim.next(&players) {
		if !character.alive || sim.timer_running(t, character.fire_cooldown) {
			continue
		}
		target: ^Enemy
		best_distance_sq: f32 = FIRE_RANGE * FIRE_RANGE
		enemies := sim.iterate(&t.state.enemies)
		for enemy in sim.next(&enemies) {
			if distance_sq := dmath.dist_sq(enemy.pos, character.pos.xz); distance_sq < best_distance_sq {
				target, best_distance_sq = enemy, distance_sq
			}
		}
		if target == nil {
			continue
		}
		aim := dmath.normalize(target.pos - character.pos.xz)
		if aim == {} {
			continue // standing on it
		}
		projectile, _ := sim.spawn(&t.state.projectiles) or_continue
		projectile.pos = character.pos
		projectile.vel = {aim.x * PROJECTILE_SPEED, 0, aim.y * PROJECTILE_SPEED}
		projectile.life = PROJECTILE_LIFE_TICKS
		projectile.damage = PROJECTILE_DAMAGE + character.damage_bonus
		sim.timer_start_ticks(t, &character.fire_cooldown, u32(character.fire_interval))
	}
}

// Projectiles move, then hit the lowest-index enemy they reach (on the grid), else whatever the segment crosses
// (a ray: the level, crates and barrels; a barrel takes the damage); they expire after their life.
move_projectiles :: proc(t: ^Tick) {
	grid := &t.world.scratch.grid
	enemy_grid_build(grid, &t.state.enemies) // the enemies moved and died since steering
	projectiles := sim.iterate(&t.state.projectiles)
	for projectile, handle in sim.next(&projectiles) {
		step := projectile.vel * t.dt
		next_pos := projectile.pos + step
		hit: i32 = -1
		for row in sim.grid_near(grid, next_pos.xz) {
			for enemy_index in row {
				if hit >= 0 && enemy_index >= hit {
					continue
				}
				enemy := &t.state.enemies.items[enemy_index]
				reach := enemy.radius + PROJECTILE_RADIUS
				if enemy.hp > 0 && dmath.dist_sq(next_pos.xz, enemy.pos) < reach * reach {
					hit = enemy_index
				}
			}
		}
		if hit >= 0 {
			t.state.enemies.items[hit].hp -= projectile.damage
			t.state.enemies.items[hit].hit_tick = t.number
			sim.despawn(&t.state.projectiles, handle)
			continue
		}
		filter := physics.Filter {
			mask = CAT_LEVEL | CAT_CRATE | CAT_BARREL,
		}
		if ray, ray_hit := physics.world_cast_ray_closest(t.world.phys, projectile.pos, step, filter); ray_hit {
			if ray.category & CAT_BARREL != 0 {
				item := &t.state.items[ray.tag]
				if item.alive {
					item.hp -= projectile.damage
				}
			}
			sim.despawn(&t.state.projectiles, handle)
			continue
		}
		projectile.pos = next_pos
		projectile.life -= 1
		if projectile.life <= 0 {
			sim.despawn(&t.state.projectiles, handle)
		}
	}
}
