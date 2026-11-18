package survivor

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// A burst of enemies every `spawn_every_ticks` of the match while below the cap. Each enemy's direction, jitter and
// kind are keyed rolls, by its place in the burst.
spawn_waves :: proc(t: ^Tick) {
	tuning := &t.state.tuning
	if t.state.phase != .Match || (t.number - t.state.match_tick) % tuning.spawn_every_ticks != 0 {
		return
	}
	present := u32(sim.present_count(t))
	count := dmath.min(tuning.spawn_base + t.state.wave * tuning.spawn_per_wave, tuning.spawn_cap)
	count = count * (100 + tuning.extra_player_pct * (dmath.max(present, 1) - 1)) / 100
	for i in 0 ..< int(count) {
		if u32(t.state.enemies.count) >= tuning.enemy_cap {
			break
		}
		direction := dmath.DIR8[sim.roll_below(t, 8, Roll.Spawn_Direction, index = i)]
		jitter := [2]f32 {
			sim.roll_f32(t, Roll.Spawn_Jitter_X, index = i),
			sim.roll_f32(t, Roll.Spawn_Jitter_Z, index = i),
		}
		pos := direction * SPAWN_RING + (jitter * 2 - 1) * SPAWN_JITTER
		spawn_enemy(
			t.state,
			SPAWN_KINDS[sim.roll_below(t, len(SPAWN_KINDS), Roll.Spawn_Kind, index = i)],
			pos,
			t.number,
		)
	}
}

// Spawns an enemy of a kind at a position, its HP scaled by the wave (false: the enemy table is full).
spawn_enemy :: proc(state: ^State, kind: Enemy_Kind, pos: [2]f32, tick: u32) -> bool {
	enemy, _ := sim.spawn(&state.enemies) or_return
	stats := ENEMY_STATS[kind]
	enemy.spawn_tick = tick
	enemy.kind = kind
	enemy.pos = pos
	enemy.hp = stats.hp * (100 + state.tuning.hp_pct_per_wave * i32(state.wave)) / 100
	enemy.speed = stats.speed
	enemy.radius = stats.radius
	enemy.damage = stats.damage
	return true
}

// Seek the nearest player plus separation from the enemies nearby (from the old positions), then move, pushed out of
// the pillars and kept inside the walls. An enemy standing on a crate or barrel is slowed (a ray down, every
// CLIMB_CHECK_TICKS, only where an item stands).
steer_enemies :: proc(t: ^Tick) {
	scratch := &t.world.scratch
	grid_build(&scratch.grid, &t.state.enemies)
	item_footprints(t)
	targets := targets_of(t)
	enemies := sim.iterate(&t.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		if (handle.index + t.number) % CLIMB_CHECK_TICKS == 0 {
			enemy.climbing = standing_on_item(t, enemy.pos)
		}
		speed := enemy.climbing ? enemy.speed * CLIMB_SLOWDOWN : enemy.speed
		desired: [2]f32
		if target := nearest_target(&targets, enemy.pos); target != nil {
			desired = dmath.normalize(target.pos.xz - enemy.pos) * speed
		}
		separation: [2]f32
		for row in grid_near(&scratch.grid, enemy.pos) {
			for other_index in row {
				if other_index == i32(handle.index) {
					continue
				}
				other := &t.state.enemies.items[other_index]
				away := enemy.pos - other.pos
				distance_sq := dmath.length_sq(away)
				reach := enemy.radius + other.radius
				if distance_sq < reach * reach && distance_sq > SEPARATION_MIN_SQ {
					separation += away * (SEPARATION / distance_sq)
				}
			}
		}
		velocity := enemy.vel * (1 - ENEMY_STEER) + (desired + separation) * ENEMY_STEER
		scratch.new_vel[handle.index] = dmath.clamp_length(velocity, speed * ENEMY_OVERSPEED)
	}
	enemies = sim.iterate(&t.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		enemy.vel = scratch.new_vel[handle.index]
		pos := enemy.pos + enemy.vel * t.dt
		for &pillar in t.world.pillars[:t.world.pillar_count] {
			pos = push_out(pos, pillar, enemy.radius)
		}
		limit := t.world.arena_inner - enemy.radius
		enemy.pos = {dmath.clamp(pos.x, -limit, limit), dmath.clamp(pos.y, -limit, limit)}
	}
}

// A circle of `radius` at `pos` moved out of `box` along the axis it is least deep in (unchanged when apart).
push_out :: #force_inline proc(pos: [2]f32, box: Box2, radius: f32) -> [2]f32 {
	pos := pos
	extent := box.half + radius
	offset := pos - box.center
	depth := extent - [2]f32{abs(offset.x), abs(offset.y)}
	if depth.x <= 0 || depth.y <= 0 {
		return pos
	}
	if depth.x < depth.y {
		pos.x = offset.x >= 0 ? box.center.x + extent.x : box.center.x - extent.x
	} else {
		pos.y = offset.y >= 0 ? box.center.y + extent.y : box.center.y - extent.y
	}
	return pos
}

// Each alive item's position on the ground this tick, for standing_on_item.
item_footprints :: proc(t: ^Tick) {
	for &item, i in t.state.items[:t.world.item_count] {
		if item.alive {
			t.world.scratch.items[i] = physics.body_position(t.world.phys, item.body).xz
		}
	}
}

// Whether something under `pos` (a crate or barrel) is higher than CLIMB_HEIGHT: a ray down, cast only when an alive
// item's footprint (its widest reach, however it lies) covers `pos`, so the result is the ray's every time.
standing_on_item :: proc(t: ^Tick, pos: [2]f32) -> bool {
	under := false
	for &item, i in t.state.items[:t.world.item_count] {
		reach: f32 = t.world.items[i].kind == .Barrel ? BARREL_REACH : CRATE_REACH
		offset := pos - t.world.scratch.items[i]
		if item.alive && abs(offset.x) <= reach && abs(offset.y) <= reach {
			under = true
			break
		}
	}
	if !under {
		return false
	}
	ray, hit := physics.world_cast_ray_closest(
		t.world.phys,
		{pos.x, CLIMB_RAY_FROM, pos.y},
		{0, -CLIMB_RAY_FROM, 0},
		{mask = CAT_CRATE | CAT_BARREL},
	)
	return hit && ray.point.y > CLIMB_HEIGHT
}

// Contact damage: an enemy touching a player hurts them, then waits CONTACT_COOLDOWN_TICKS.
hurt_players :: proc(t: ^Tick) {
	targets := targets_of(t)
	enemies := sim.iterate(&t.state.enemies)
	for enemy in sim.next(&enemies) {
		if enemy.contact_cooldown > 0 {
			enemy.contact_cooldown -= 1
			continue
		}
		for character, k in targets.characters[:targets.count] {
			reach := enemy.radius + PLAYER_RADIUS
			if character.alive && dmath.dist_sq(character.pos.xz, enemy.pos) < reach * reach {
				damage_player(t, targets.players[k], enemy.damage)
				enemy.contact_cooldown = CONTACT_COOLDOWN_TICKS
				break
			}
		}
	}
}

// Enemies at HP <= 0 die and drop a gem worth their XP (with the gem table full, the nearest player gets the XP).
kill_enemies :: proc(t: ^Tick) {
	enemies := sim.iterate(&t.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		if enemy.hp > 0 {
			continue
		}
		pos, xp := enemy.pos, ENEMY_STATS[enemy.kind].xp
		sim.emit(t, Event_Enemy_Died{enemy = handle, position = sim.position_floor(pos), enemy_kind = enemy.kind})
		sim.despawn(&t.state.enemies, handle)
		if gem, _, ok := sim.spawn(&t.state.gems); ok {
			gem^ = {
				pos        = pos,
				value      = xp,
				spawn_tick = t.number,
			}
		} else {
			targets := targets_of(t)
			if nearest := nearest_target(&targets, pos); nearest != nil {
				nearest.xp += xp
			}
		}
	}
}

// The bench's setup: the match running endless with the `bench` tuning, its population held at `count`, pre-spawned
// at random positions over the arena from a fixed stream (setup outside any tick).
bench_prepare :: proc(state: ^State, world: ^World, count: int) {
	state.tuning = TUNINGS[.Bench]
	state.tuning.enemy_cap = u32(count)
	state.phase = .Match // the spawner refills to `count` from tick 1 on
	rng := sim.rng_seed(u64(count))
	for _ in 0 ..< count {
		x := f32(sim.rng_below(&rng, BENCH_HALF * 200)) / 100 - BENCH_HALF // whole centimetres
		z := f32(sim.rng_below(&rng, BENCH_HALF * 200)) / 100 - BENCH_HALF
		if !spawn_enemy(state, SPAWN_KINDS[sim.rng_below(&rng, len(SPAWN_KINDS))], {x, z}, 0) {
			break
		}
	}
}
