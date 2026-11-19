package extension

import "unified:dmath"
import "unified:godot"
import "unified:physics"
import "unified:sim"

import g "../survivor"

// The frame, filled on the session thread. Keys (unique within a kind): a player's view is their sim.player_key (the
// view lives while they are present, dead too, whatever slot they hold), an item's its index (a destroyed barrel's
// view goes; the one back BARREL_RESPAWN_TICKS later is a new view).
fill_frame :: proc(f: ^Frame) {
	players := sim.iterate_present(&f.state.players)
	for character, player in sim.next(&players) {
		godot.push_view(f, player, {
			kind = .Player,
			pos  = sim.Position(character.pos),
		}, Player_View{hp = max(character.hp, 0), dashing = sim.timer_running(f.time, character.dash)})
	}
	for &item, i in f.state.items[:f.world.items.count] {
		if !item.alive do continue
		godot.push_view(f, sim.entity(i), {
			kind = sim.slice(&f.world.items)[i].kind == .Barrel ? .Barrel : .Crate,
			pos  = sim.Position(physics.body_position(f.world.phys, item.body)),
			rot  = physics.body_rotation(f.world.phys, item.body),
		})
	}
	enemies := sim.iterate(&f.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = MultiView(enemy.kind),
			pos    = sim.position_floor(enemy.pos),
			rot    = dmath.quat_yaw(dmath.normalize(enemy.vel, 0)),
			custom = {hit_flash(f.tick, enemy.hit_tick), age_s(f.tick, enemy.spawn_tick), 0, 0},
		})
	}
	projectiles := sim.iterate(&f.state.projectiles)
	for projectile, handle in sim.next(&projectiles) {
		godot.push_multi_view(f, {
			key  = sim.handle_key(handle),
			kind = .Projectile,
			pos  = sim.position_floor(projectile.pos.xz),
			rot  = dmath.quat_yaw(dmath.normalize(projectile.vel.xz, 0)),
		})
	}
	gems := sim.iterate(&f.state.gems)
	for gem, handle in sim.next(&gems) {
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = .Gem,
			pos    = sim.position_floor(gem.pos),
			custom = {0, age_s(f.tick, gem.spawn_tick), 0, 0},
		})
	}
	godot.push_data(f, hud_of(f.state, f.tick, f.seed))
}

HIT_FLASH_S :: 0.15

// MultiMesh custom data (the game's shaders): r = hit flash 1 -> 0 over HIT_FLASH_S, g = age in seconds.
hit_flash :: proc(tick, hit_tick: u32) -> f32 {
	if hit_tick == 0 || tick < hit_tick do return 0
	return max(0, 1 - sim.seconds(tick - hit_tick, g.TICK_HZ) / HIT_FLASH_S)
}

age_s :: proc(tick, spawn_tick: u32) -> f32 {
	return tick > spawn_tick ? sim.seconds(tick - spawn_tick, g.TICK_HZ) : 0
}
