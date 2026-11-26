package horde

import "unified:dmath"
import "unified:sim"

GRID_CELL :: f32(1.5) // units: about two enemies across
GRID_N :: 41 // cells along each axis: the arena and a margin
GRID_CELLS :: GRID_N * GRID_N
GRID_ORIGIN :: -f32(GRID_N) * GRID_CELL / 2 // the grid's corner (x and y)

// The alive enemies in GRID_CELL cells (scratch, rebuilt every tick by enemy_grid_build): the enemies near a point
// are those in its cell and the 8 around it (sim.grid_near), each cell in index order.
Enemy_Grid :: sim.Grid(GRID_CELLS, MAX_ENEMIES)

// Rebuilds the grid from the enemies, walked in index order.
enemy_grid_build :: proc(grid: ^Enemy_Grid, enemies: ^sim.Table(Enemy, MAX_ENEMIES)) {
	sim.grid_begin(grid, {GRID_ORIGIN, GRID_ORIGIN}, GRID_CELL, GRID_N, GRID_N)
	alive := sim.iterate(enemies)
	for enemy, handle in sim.next(&alive) do sim.grid_add(grid, i32(handle.index), enemy.pos)
	sim.grid_end(grid)
}

// While the match runs, a burst every SPAWN_EVERY_S of min(SPAWN_BASE + SPAWN_PER_WAVE * wave, SPAWN_CAP) enemies,
// while fewer than ENEMY_CAP are alive: each on SPAWN_RING in one of 8 directions plus up to SPAWN_JITTER along each
// axis, its kind from SPAWN_KINDS (keyed rolls by its place in the burst). The bench refills to its population
// instead, up to SPAWN_CAP a tick.
spawn_waves :: proc(t: ^Tick) {
	if t.state.phase != .Match || sim.present_count(t) == 0 do return
	count, cap: u32
	if t.state.bench_hold > 0 {
		cap = t.state.bench_hold
		count = SPAWN_CAP
	} else {
		if u32(t.time - t.state.match_tick) % sim.ticks(SPAWN_EVERY_S, TICK_HZ) != 0 do return
		cap = ENEMY_CAP
		count = dmath.min(SPAWN_BASE + t.state.wave * SPAWN_PER_WAVE, SPAWN_CAP)
	}
	for i in 0 ..< int(count) {
		if u32(t.state.enemies.count) >= cap do break
		direction := dmath.DIR8[sim.roll_below(t, 8, Roll.Spawn_Direction, index = i)]
		jitter := [2]f32 {
			sim.roll_f32(t, Roll.Spawn_Jitter_X, index = i),
			sim.roll_f32(t, Roll.Spawn_Jitter_Y, index = i),
		}
		pos := direction * SPAWN_RING + (jitter * 2 - 1) * SPAWN_JITTER
		spawn_enemy(t, SPAWN_KINDS[sim.roll_below(t, len(SPAWN_KINDS), Roll.Spawn_Kind, index = i)], pos)
	}
}

// Spawns an enemy of a kind at a position, its HP HP_PCT_PER_WAVE% more per wave (false: the table is full).
spawn_enemy :: proc(t: ^Tick, kind: Enemy_Kind, pos: [2]f32) -> bool {
	enemy, _ := sim.spawn(&t.state.enemies) or_return
	enemy_set(enemy, kind, pos, t.state.wave)
	return true
}

// An enemy of a kind at a position, fresh, with the HP of `wave`.
enemy_set :: proc(enemy: ^Enemy, kind: Enemy_Kind, pos: [2]f32, wave: u32) {
	stats := ENEMY_STATS[kind]
	hp := stats.hp * (100 + HP_PCT_PER_WAVE * i32(wave)) / 100
	enemy^ = {
		pos    = pos,
		hp     = hp,
		hp_max = hp,
		kind   = kind,
	}
}

// Seek the nearest alive hero plus separation from the enemies in the 3×3 grid cells around (old positions), blended
// in by ENEMY_STEER and capped at ENEMY_OVERSPEED times the kind's speed; then move, kept inside the arena.
//
// Separation visits each pair of neighbours once (sim.grid_pairs) over a copy of each enemy's position and radius in
// grid order (World.near), and a push counts for both, opposite ways.
steer_enemies :: proc(t: ^Tick) {
	ids := sim.grid_ids(&t.world.grid)
	for index, k in ids {
		enemy := &t.state.enemies.items[index]
		t.world.near[k] = {enemy.pos, ENEMY_STATS[enemy.kind].radius}
		t.world.push[k] = {}
	}
	pairs := sim.grid_pairs(&t.world.grid)
	for k, later in sim.next(&pairs) {
		enemy := t.world.near[k]
		for run in later {
			for j in run.first ..< run.end {
				other := &t.world.near[j]
				away := enemy.pos - other.pos
				distance_sq := dmath.length_sq(away)
				reach := enemy.radius + other.radius
				if distance_sq < reach * reach && distance_sq > SEPARATION_MIN_SQ {
					push := away * (SEPARATION / distance_sq)
					t.world.push[k] += push
					t.world.push[j] -= push
				}
			}
		}
	}
	for index, k in ids {
		enemy := &t.state.enemies.items[index]
		stats := ENEMY_STATS[enemy.kind]
		desired: [2]f32
		if hero := nearest_hero(t, enemy.pos); hero != nil {
			desired = dmath.normalize(hero.pos - enemy.pos) * stats.speed
		}
		velocity := enemy.vel * (1 - ENEMY_STEER) + (desired + t.world.push[k]) * ENEMY_STEER
		t.world.new_vel[index] = dmath.clamp_length(velocity, stats.speed * ENEMY_OVERSPEED)
	}
	enemies := sim.iterate(&t.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		enemy.vel = t.world.new_vel[handle.index]
		pos := enemy.pos + enemy.vel * t.dt
		limit := ARENA_HALF - ENEMY_STATS[enemy.kind].radius
		enemy.pos = {dmath.clamp(pos.x, -limit, limit), dmath.clamp(pos.y, -limit, limit)}
	}
}

// Damages the enemy at table index `index` (its hit flash, a damage number) and returns its handle. Its death waits
// for kill_enemies, so a pass that hits several sees every enemy where it was.
hit_enemy :: proc(t: ^Tick, index: i32, damage: i32, source: Source) -> sim.Handle(Enemy) {
	enemy, handle, _ := sim.item_at(&t.state.enemies, int(index))
	if enemy.hp <= 0 do return handle // already dying this tick
	enemy.hp -= damage
	enemy.hit_tick = t.time
	sim.emit(
		t,
		Event_Enemy_Hit{enemy = handle, position = sim.position_2d(enemy.pos), damage = damage, source = source},
	)
	return handle
}

// Each enemy at 0 HP dies: its event, a gem of its kind's XP where it stood (none when the gem table is full).
kill_enemies :: proc(t: ^Tick) {
	enemies := sim.iterate(&t.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		if enemy.hp > 0 do continue
		pos, kind := enemy.pos, enemy.kind
		sim.emit(t, Event_Enemy_Died{enemy = handle, position = sim.position_2d(pos), enemy_kind = kind})
		sim.despawn(&t.state.enemies, handle)
		t.state.kills += 1
		if gem, _, ok := sim.spawn(&t.state.gems); ok {
			gem^ = {
				pos   = pos,
				value = ENEMY_STATS[kind].xp,
			}
		}
	}
}

// The alive enemy nearest to `pos` within `range` (-1: none), the lowest index on ties, skipping those in `skip`.
nearest_enemy :: proc(t: ^Tick, pos: [2]f32, range: f32, skip: []i32 = nil) -> i32 {
	best := i32(-1)
	best_sq := range * range
	walk := sim.grid_box(&t.world.grid, pos - range, pos + range)
	for ids in sim.grid_box_next(&walk) {
		next: for index in ids {
			enemy := &t.state.enemies.items[index]
			if enemy.hp <= 0 do continue
			for skipped in skip do if skipped == index do continue next
			distance_sq := dmath.length_sq(enemy.pos - pos)
			if distance_sq < best_sq || (distance_sq == best_sq && best >= 0 && index < best) {
				best, best_sq = index, distance_sq
			}
		}
	}
	return best
}
