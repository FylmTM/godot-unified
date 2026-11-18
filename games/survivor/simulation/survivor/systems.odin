// The game systems in games/survivor/SPEC.md order. Float math is scalar f32 `+ − × ÷` and sqrt only, written in
// the order the spec gives; no `matrix` types and no core:math (determinism traps, see AGENTS.md).
package survivor

import "unified:dmath"
import "unified:physics"
import "unified:sim"

GRID_N :: 30 // 2 m cells over the 60×60 arena
GRID_CELLS :: GRID_N * GRID_N

// Per-tick scratch outside the block (rebuilt every tick, never snapshotted).
Scratch :: struct {
	cell_count: [GRID_CELLS]i32,
	cell_start: [GRID_CELLS + 1]i32,
	cell_items: [MAX_ENEMIES]i32,
	enemy_cell: [MAX_ENEMIES]i32,
	new_vel:    [MAX_ENEMIES][2]f32,
}

Enemy_Stats :: struct {
	hp:     i32,
	speed:  f32,
	radius: f32,
	damage: i32,
	xp:     i32,
}

@(rodata)
ENEMY_STATS := [Enemy_Kind]Enemy_Stats {
	.Grunt  = {10, 2.0, 0.4, 5, 1},
	.Runner = {6, 3.2, 0.35, 3, 1},
	.Brute  = {40, 1.2, 0.7, 12, 5},
}

// One tick (t.number = the tick being computed): systems 1-12.
tick :: proc(t: ^Tick) {
	sys_players(t)
	sys_levelup(t)
	sys_spawner(t)
	sys_enemies(t.state, t.world, t.number, t.dt)
	sys_contact(t)
	sys_attack(t.state)
	sys_projectiles(t.state, t.world, t.number, t.dt)
	sys_barrels(t)
	sys_deaths(t)
	physics.step(t.world.phys, t.dt, SUBSTEPS)
	read_back(t.state, t.world)
	sys_phase(t)
}

// 12. Phases: lobby -> match when a player leaves the start circle; match -> over when every
// present player is dead at once (or nobody is present); over -> lobby (world reset) after the hold.
@(private)
sys_phase :: proc(t: ^Tick) {
	present, alive := 0, 0
	players := sim.iterate_present(&t.state.players)
	for character in sim.next(&players) {
		present += 1
		alive += int(character.alive)
	}
	switch t.state.phase {
	case .Lobby:
		radius2 := t.state.circle_radius * t.state.circle_radius
		players = sim.iterate_present(&t.state.players)
		for character, player in sim.next(&players) {
			pos := character.pos
			if character.alive && pos.x * pos.x + pos.z * pos.z > radius2 {
				t.state.phase = .Match
				t.state.match_tick = t.number
				t.state.over_tick = 0
				t.state.wave = 0
				t.state.circle_radius = 0
				t.state.matches += 1
				sim.emit(t, Event_Match_Started{position = sim.Position(pos), player = player})
				break
			}
		}
	case .Match:
		t.state.wave = (t.number - t.state.match_tick) / tuning(t.state).wave_ticks
		if present == 0 {
			reset_world(t)
		} else if alive == 0 && !t.state.endless {
			t.state.phase = .Over
			t.state.over_tick = t.number
			sim.emit(t, Event_Match_Over{duration_s = sim.seconds(t.number - t.state.match_tick, TICK_HZ)})
		}
	case .Over:
		if t.number - t.state.over_tick >= OVER_HOLD_TICKS {
			reset_world(t)
		}
	}
}

// Back to the lobby: every dynamic body is destroyed and rebuilt in creation order (items, then
// present players at their start spots, in slot order); everyone's progress starts fresh, absent players' too;
// enemies, projectiles and gems go.
reset_world :: proc(t: ^Tick) {
	for &item in t.state.items {
		destroy_body(t.world, &item.body)
	}
	known := sim.iterate_known(&t.state.players)
	for character in sim.next(&known) {
		destroy_body(t.world, &character.body)
		character_reset(character)
	}
	for i in 0 ..< ITEM_COUNT {
		item_reset(t.state, t.world, i)
	}
	for slot in 0 ..< PLAYERS {
		player := sim.player_in_slot(t, slot)
		if character := sim.player_data(t, player); character != nil {
			character_spawn(t.world, character, slot)
			sim.emit(t, Event_Player_Respawned{position = sim.Position(character.pos), player = player})
		}
	}
	sim.despawn_all(&t.state.enemies)
	sim.despawn_all(&t.state.projectiles)
	sim.despawn_all(&t.state.gems)
	t.state.phase = .Lobby
	t.state.circle_radius = START_RADIUS
	t.state.match_tick = 0
	t.state.over_tick = 0
	t.state.wave = 0
}

// 1. Players: leaves and arrivals (the harness's t.player_changes), respawn, movement and dash.
@(private)
sys_players :: proc(t: ^Tick) {
	for player in t.player_changes.left {
		character_leave(t.world, sim.player_data(t, player))
	}
	for player in t.player_changes.joined {
		character_reset(sim.player_data(t, player)) // someone new: fresh progress
	}
	for player in t.player_changes.arrived {
		character_spawn(t.world, sim.player_data(t, player), sim.player_slot(t, player)) // one back keeps their progress
	}
	players := sim.iterate_present(&t.state.players)
	for character, player in sim.next(&players) {
		if character.alive && character.hp <= 0 {
			player_dies(t, character, player) // set from outside a tick (a test): damage_player kills at once
		}
		slot := sim.player_slot(t, player)
		input := sim.input(t, player)
		if character.dash_cooldown > 0 {
			character.dash_cooldown -= 1
		}
		pressed := .Dash in sim.buttons(t, player).pressed
		if !character.alive {
			if t.state.phase == .Over {
				continue // nobody respawns until the reset
			}
			character.respawn -= 1
			if character.respawn > 0 {
				continue
			}
			character_spawn(t.world, character, slot)
			sim.emit(t, Event_Player_Respawned{position = sim.Position(character.pos), player = player})
		}
		if pressed && character.dash_cooldown == 0 {
			character.dash_ticks = DASH_TICKS
			character.dash_cooldown = DASH_COOLDOWN_TICKS
		}
		move := dmath.stick(input.move_x, input.move_z)
		vx := move.x * character.speed
		vz := move.y * character.speed
		if character.dash_ticks > 0 {
			vx = vx * 3
			vz = vz * 3
			character.dash_ticks -= 1
		}
		velocity := physics.body_linear_velocity(t.world.phys, character.body)
		physics.body_set_linear_velocity(t.world.phys, character.body, {vx, velocity.y, vz})
	}
}

// 2. Level-up picks (Cmd_Pick commands, each delivered once): each takes one pending level-up.
@(private)
sys_levelup :: proc(t: ^Tick) {
	players := sim.iterate_present(&t.state.players)
	for character, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			switch command in sent {
			case Cmd_Pick:
				if character.pending_levelups <= 0 {
					continue // nothing to pick
				}
				switch command.upgrade {
				case .Fire_Rate:
					character.fire_interval = max(
						character.fire_interval - FIRE_LEVELUP_TICKS,
						FIRE_INTERVAL_MIN_TICKS,
					)
				case .Damage:
					character.damage_bonus += DAMAGE_LEVELUP
				case .Move_Speed:
					character.speed = character.speed + SPEED_LEVELUP
				case:
					continue // not an option
				}
				character.pending_levelups -= 1
			}
		}
	}
}

// 3. Spawner: a burst of enemies every `spawn_every_ticks` while below the cap. Each enemy's direction, jitter and
// kind are keyed rolls, by its place in the wave.
@(private)
sys_spawner :: proc(t: ^Tick) {
	tune := tuning(t.state)
	if t.state.phase != .Match || (t.number - t.state.match_tick) % tune.spawn_every_ticks != 0 {
		return
	}
	present := u32(sim.present_count(t))
	count := min(tune.spawn_base + t.state.wave * tune.spawn_per_wave, tune.spawn_cap)
	count = count * (100 + tune.extra_player_pct * (max(present, 1) - 1)) / 100
	for i in 0 ..< int(count) {
		if u32(t.state.enemies.count) >= t.state.enemy_cap {
			break
		}
		direction := sim.roll_below(t, 8, Roll.Spawn_Direction, index = i)
		jitter := f32(sim.roll_below(t, 1000, Roll.Spawn_Jitter, index = i)) / 1000 * 2 - 1
		x := 27 * dmath.DIR8[direction].x + jitter
		z := 27 * dmath.DIR8[direction].y + jitter
		spawn_enemy(t.state, kind_of_roll(sim.roll_below(t, 10, Roll.Spawn_Kind, index = i)), {x, z}, t.number)
	}
}

// The enemy kind for a roll in 0 ..< 10.
@(private)
kind_of_roll :: proc(roll: u32) -> Enemy_Kind {
	return roll <= 6 ? .Grunt : (roll <= 8 ? .Runner : .Brute)
}

// Spawns an enemy of a kind at a position, its HP scaled by the wave (false: the enemy table is full). The spawner
// and the bench's prespawn use it.
spawn_enemy :: proc(state: ^State, kind: Enemy_Kind, pos: [2]f32, tick: u32) -> bool {
	enemy, _ := sim.spawn(&state.enemies) or_return
	stats := ENEMY_STATS[kind]
	enemy.spawn_tick = tick
	enemy.kind = kind
	enemy.pos = pos
	enemy.hp = stats.hp * (100 + tuning(state).hp_pct_per_wave * i32(state.wave)) / 100
	enemy.speed = stats.speed
	enemy.radius = stats.radius
	enemy.damage = stats.damage
	return true
}

@(private)
cell_of :: #force_inline proc(pos: [2]f32) -> (cell_x, cell_z: i32) {
	cell_x = dmath.to_i32_clamped((pos.x + 30) * 0.5, 0, GRID_N - 1)
	cell_z = dmath.to_i32_clamped((pos.y + 30) * 0.5, 0, GRID_N - 1)
	return
}

// Counting sort of alive enemies into 2 m cells; items within a cell are in index order.
@(private)
build_grid :: proc(state: ^State, scratch: ^Scratch) {
	scratch.cell_count = {}
	high_water := state.enemies.high_water
	for i in 0 ..< high_water {
		scratch.enemy_cell[i] = -1
	}
	enemies := sim.iterate(&state.enemies)
	for enemy, handle in sim.next(&enemies) {
		cell_x, cell_z := cell_of(enemy.pos)
		cell := cell_z * GRID_N + cell_x
		scratch.enemy_cell[handle.index] = cell
		scratch.cell_count[cell] += 1
	}
	sum: i32 = 0
	for cell in 0 ..< GRID_CELLS {
		scratch.cell_start[cell] = sum
		sum += scratch.cell_count[cell]
	}
	scratch.cell_start[GRID_CELLS] = sum
	scratch.cell_count = {} // reused as the fill cursor
	for i in 0 ..< high_water {
		cell := scratch.enemy_cell[i]
		if cell < 0 {
			continue
		}
		scratch.cell_items[scratch.cell_start[cell] + scratch.cell_count[cell]] = i
		scratch.cell_count[cell] += 1
	}
}

// The alive present players, in slot order, taken once for a pass over many enemies or gems instead of walking the
// presence for each (a pass that can kill checks `alive` again).
@(private)
Targets :: struct {
	characters: [PLAYERS]^Character,
	players:    [PLAYERS]sim.Player,
	count:      int,
}

@(private)
targets_of :: proc(state: ^State) -> (targets: Targets) {
	players := sim.iterate_present(&state.players)
	for character, player in sim.next(&players) {
		if character.alive {
			targets.characters[targets.count] = character
			targets.players[targets.count] = player
			targets.count += 1
		}
	}
	return
}

// Nearest alive player to pos in XZ (lowest slot on ties); nil if none.
@(private)
nearest_player :: proc(state: ^State, pos: [2]f32) -> (best: ^Character, best_distance2: f32) {
	targets := targets_of(state)
	return nearest_target(&targets, pos)
}

@(private)
nearest_target :: proc(targets: ^Targets, pos: [2]f32) -> (best: ^Character, best_distance2: f32) {
	for character in targets.characters[:targets.count] {
		if !character.alive {
			continue
		}
		dx := character.pos.x - pos.x
		dz := character.pos.z - pos.y
		distance2 := dx * dx + dz * dz
		if best == nil || distance2 < best_distance2 {
			best = character
			best_distance2 = distance2
		}
	}
	return
}

// 4. Enemies: seek + separation (phase 1, old positions), integrate + push-out (phase 2).
@(private)
sys_enemies :: proc(state: ^State, world: ^World, tick: u32, dt: f32) {
	scratch := &world.scratch
	build_grid(state, scratch)
	targets := targets_of(state)
	ray_filter := physics.Filter {
		mask = CAT_CRATE | CAT_BARREL,
	}
	enemies := sim.iterate(&state.enemies)
	for enemy, handle in sim.next(&enemies) {
		index := i32(handle.index)
		if (handle.index + tick) % CLIMB_CHECK_TICKS == 0 {
			ray, hit := physics.world_cast_ray_closest(
				world.phys,
				{enemy.pos.x, 3, enemy.pos.y},
				{0, -3, 0},
				ray_filter,
			)
			enemy.climbing = hit && ray.point.y > 0.8
		}
		speed := enemy.climbing ? enemy.speed * 0.5 : enemy.speed
		desired: [2]f32
		if target, _ := nearest_target(&targets, enemy.pos); target != nil {
			dx := target.pos.x - enemy.pos.x
			dz := target.pos.z - enemy.pos.y
			length := dmath.sqrt(dx * dx + dz * dz)
			if length > 0.0001 {
				desired = {dx / length * speed, dz / length * speed}
			}
		}
		separation: [2]f32
		cell_x, cell_z := cell_of(enemy.pos)
		for near_z in cell_z - 1 ..= cell_z + 1 {
			if near_z < 0 || near_z >= GRID_N {
				continue
			}
			for near_x in cell_x - 1 ..= cell_x + 1 {
				if near_x < 0 || near_x >= GRID_N {
					continue
				}
				cell := near_z * GRID_N + near_x
				for k in scratch.cell_start[cell] ..< scratch.cell_start[cell + 1] {
					other_index := scratch.cell_items[k]
					if other_index == index {
						continue
					}
					other := &state.enemies.items[other_index]
					away_x := enemy.pos.x - other.pos.x
					away_z := enemy.pos.y - other.pos.y
					distance2 := away_x * away_x + away_z * away_z
					reach := enemy.radius + other.radius
					if distance2 < reach * reach && distance2 > 0.00000001 {
						push := 0.5 / distance2
						separation.x = separation.x + away_x * push
						separation.y = separation.y + away_z * push
					}
				}
			}
		}
		desired.x = desired.x + separation.x
		desired.y = desired.y + separation.y
		vx := enemy.vel.x * 0.8 + desired.x * 0.2
		vz := enemy.vel.y * 0.8 + desired.y * 0.2
		max_speed := speed * 1.5
		speed2 := vx * vx + vz * vz
		if speed2 > max_speed * max_speed {
			scale := max_speed / dmath.sqrt(speed2)
			vx = vx * scale
			vz = vz * scale
		}
		scratch.new_vel[index] = {vx, vz}
	}
	enemies = sim.iterate(&state.enemies)
	for enemy, handle in sim.next(&enemies) {
		enemy.vel = scratch.new_vel[handle.index]
		x := enemy.pos.x + enemy.vel.x * dt
		z := enemy.pos.y + enemy.vel.y * dt
		radius := enemy.radius
		for k in 0 ..< 8 {
			pillar_x := 14 * dmath.DIR8[k].x
			pillar_z := 14 * dmath.DIR8[k].y
			extent := 1 + radius
			dx := x - pillar_x
			dz := z - pillar_z
			abs_dx := abs(dx)
			abs_dz := abs(dz)
			if abs_dx < extent && abs_dz < extent {
				if extent - abs_dx < extent - abs_dz {
					x = dx >= 0 ? pillar_x + extent : pillar_x - extent
				} else {
					z = dz >= 0 ? pillar_z + extent : pillar_z - extent
				}
			}
		}
		limit := 30 - radius
		enemy.pos = {clamp(x, -limit, limit), clamp(z, -limit, limit)}
	}
}

// Damages an alive player (nobody, absent or dead: nothing); at HP <= 0 they die (body destroyed, respawn timer
// set).
damage_player :: proc(t: ^Tick, player: sim.Player, amount: i32) {
	character := sim.player_data(t, player)
	if character == nil || !character.alive {
		return
	}
	character.hp -= amount
	if character.hp <= 0 {
		player_dies(t, character, player)
	}
}

@(private)
player_dies :: proc(t: ^Tick, character: ^Character, player: sim.Player) {
	sim.emit(t, Event_Player_Died{position = sim.Position(character.pos), player = player})
	character.alive = false
	character.respawn = RESPAWN_TICKS
	character.dash_ticks = 0
	destroy_body(t.world, &character.body)
}

// 5. Contact damage, one hit per enemy per 30 ticks.
@(private)
sys_contact :: proc(t: ^Tick) {
	targets := targets_of(t.state)
	enemies := sim.iterate(&t.state.enemies)
	for enemy in sim.next(&enemies) {
		if enemy.contact_cooldown > 0 {
			enemy.contact_cooldown -= 1
			continue
		}
		for character, k in targets.characters[:targets.count] {
			player := targets.players[k]
			if !character.alive {
				continue
			}
			dx := character.pos.x - enemy.pos.x
			dz := character.pos.z - enemy.pos.y
			reach := enemy.radius + 0.45
			if dx * dx + dz * dz < reach * reach {
				damage_player(t, player, enemy.damage)
				enemy.contact_cooldown = CONTACT_COOLDOWN_TICKS
				break
			}
		}
	}
}

// 6. Auto-attack: fire at the nearest enemy within 14 m.
@(private)
sys_attack :: proc(state: ^State) {
	players := sim.iterate_present(&state.players)
	for character in sim.next(&players) {
		if !character.alive {
			continue
		}
		if character.fire_cooldown > 0 {
			character.fire_cooldown -= 1
			if character.fire_cooldown > 0 {
				continue
			}
		}
		target: ^Enemy
		best_distance2: f32 = 14 * 14
		enemies := sim.iterate(&state.enemies)
		for enemy in sim.next(&enemies) {
			dx := enemy.pos.x - character.pos.x
			dz := enemy.pos.y - character.pos.z
			distance2 := dx * dx + dz * dz
			if distance2 < best_distance2 {
				target = enemy
				best_distance2 = distance2
			}
		}
		if target == nil {
			continue
		}
		dx := target.pos.x - character.pos.x
		dz := target.pos.y - character.pos.z
		length := dmath.sqrt(dx * dx + dz * dz)
		if length <= 0.0001 {
			continue
		}
		projectile, _ := sim.spawn(&state.projectiles) or_continue
		projectile.pos = character.pos
		projectile.vel = {dx / length * 16, 0, dz / length * 16}
		projectile.life = PROJECTILE_LIFE_TICKS
		projectile.damage = 5 + character.damage_bonus
		character.fire_cooldown = character.fire_interval
	}
}

// 7. Projectiles: move, hit enemies (grid, first index wins), else ray-cast the segment.
@(private)
sys_projectiles :: proc(state: ^State, world: ^World, tick: u32, dt: f32) {
	scratch := &world.scratch
	build_grid(state, scratch)
	ray_filter := physics.Filter {
		mask = CAT_STATIC | CAT_CRATE | CAT_BARREL,
	}
	projectiles := sim.iterate(&state.projectiles)
	for projectile, handle in sim.next(&projectiles) {
		step := [3]f32{projectile.vel.x * dt, projectile.vel.y * dt, projectile.vel.z * dt}
		next_pos := [3]f32{projectile.pos.x + step.x, projectile.pos.y + step.y, projectile.pos.z + step.z}
		hit: i32 = -1
		cell_x, cell_z := cell_of({next_pos.x, next_pos.z})
		for near_z in cell_z - 1 ..= cell_z + 1 {
			if near_z < 0 || near_z >= GRID_N {
				continue
			}
			for near_x in cell_x - 1 ..= cell_x + 1 {
				if near_x < 0 || near_x >= GRID_N {
					continue
				}
				cell := near_z * GRID_N + near_x
				for k in scratch.cell_start[cell] ..< scratch.cell_start[cell + 1] {
					enemy_index := scratch.cell_items[k]
					if hit >= 0 && enemy_index >= hit {
						break // cells are index-ordered: nothing lower left here
					}
					enemy := &state.enemies.items[enemy_index]
					if enemy.hp <= 0 {
						continue
					}
					dx := next_pos.x - enemy.pos.x
					dz := next_pos.z - enemy.pos.y
					reach := enemy.radius + 0.15
					if dx * dx + dz * dz < reach * reach {
						hit = enemy_index
					}
				}
			}
		}
		if hit >= 0 {
			state.enemies.items[hit].hp -= projectile.damage
			state.enemies.items[hit].hit_tick = tick
			sim.despawn(&state.projectiles, handle)
			continue
		}
		if ray, ray_hit := physics.world_cast_ray_closest(world.phys, projectile.pos, step, ray_filter); ray_hit {
			if ray.category & (CAT_CRATE | CAT_BARREL) != 0 {
				item := &state.items[ray.tag]
				if item.kind == .Barrel && item.alive {
					item.hp -= projectile.damage
				}
			}
			sim.despawn(&state.projectiles, handle)
			continue
		}
		projectile.pos = next_pos
		projectile.life -= 1
		if projectile.life <= 0 {
			sim.despawn(&state.projectiles, handle)
		}
	}
}

// 8. Barrels: respawn due barrels, then explode barrels at HP <= 0 in barrel order.
@(private)
sys_barrels :: proc(t: ^Tick) {
	for i in 0 ..< ITEM_COUNT {
		item := &t.state.items[i]
		if item.kind == .Barrel && !item.alive && item.respawn_tick == t.number {
			item.alive = true
			item.hp = BARREL_HP
			item.respawn_tick = 0
			item.body = create_item_body(t.world, i)
		}
	}
	for i in 0 ..< ITEM_COUNT {
		item := &t.state.items[i]
		if item.kind != .Barrel || !item.alive || item.hp > 0 {
			continue
		}
		body_pos := physics.body_position(t.world.phys, item.body)
		center := [3]f32{body_pos.x, body_pos.y, body_pos.z}
		for j in 0 ..< ITEM_COUNT {
			other := &t.state.items[j]
			if j == i || !other.alive {
				continue
			}
			explosion_impulse(t.world, center, other.body)
		}
		players := sim.iterate_present(&t.state.players)
		for character in sim.next(&players) {
			if character.alive {
				explosion_impulse(t.world, center, character.body)
			}
		}
		enemies := sim.iterate(&t.state.enemies)
		for enemy in sim.next(&enemies) {
			dx := enemy.pos.x - center.x
			dz := enemy.pos.y - center.z
			if dx * dx + dz * dz < 25 {
				enemy.hp -= 25
				enemy.hit_tick = t.number
			}
		}
		players = sim.iterate_present(&t.state.players)
		for character, player in sim.next(&players) {
			if !character.alive {
				continue
			}
			dx := character.pos.x - center.x
			dz := character.pos.z - center.z
			if dx * dx + dz * dz < 9 {
				damage_player(t, player, 15)
			}
		}
		destroy_body(t.world, &item.body)
		sim.emit(t, Event_Barrel_Exploded{entity = u64(i + 1), position = sim.Position(center)}) // item keys are index + 1
		item.alive = false
		item.respawn_tick = t.number + BARREL_RESPAWN_TICKS
		t.state.explosions += 1
	}
}

@(private)
explosion_impulse :: proc(world: ^World, center: [3]f32, body: Body_Ref) {
	body_pos := physics.body_position(world.phys, body)
	dx := body_pos.x - center.x
	dy := body_pos.y - center.y
	dz := body_pos.z - center.z
	distance := dmath.sqrt(dx * dx + dy * dy + dz * dz)
	if distance >= 5 {
		return
	}
	dir_x, dir_z: f32
	horizontal := dmath.sqrt(dx * dx + dz * dz)
	if horizontal > 0.0001 {
		dir_x = dx / horizontal
		dir_z = dz / horizontal
	}
	up: f32 = 0.5
	length := dmath.sqrt(dir_x * dir_x + up * up + dir_z * dir_z)
	strength := 12 * (1 - distance / 5)
	physics.body_apply_linear_impulse_to_center(
		world.phys,
		body,
		{dir_x / length * strength, up / length * strength, dir_z / length * strength},
	)
}

// 9. Deaths, gems, XP and level thresholds.
@(private)
sys_deaths :: proc(t: ^Tick) {
	enemies := sim.iterate(&t.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		if enemy.hp > 0 {
			continue
		}
		pos := enemy.pos
		xp := ENEMY_STATS[enemy.kind].xp
		sim.emit(t, Event_Enemy_Died {
			enemy      = handle,
			position   = {pos.x, 0, pos.y},
			enemy_kind = enemy.kind,
		})
		sim.despawn(&t.state.enemies, handle)
		t.state.kills += 1
		if gem, _, ok := sim.spawn(&t.state.gems); ok {
			gem.pos = pos
			gem.value = xp
			gem.spawn_tick = t.number
		} else if nearest, _ := nearest_player(t.state, pos); nearest != nil {
			nearest.xp += xp
		}
	}
	targets := targets_of(t.state)
	gems := sim.iterate(&t.state.gems)
	for gem, handle in sim.next(&gems) {
		for character, k in targets.characters[:targets.count] {
			player := targets.players[k]
			if !character.alive {
				continue
			}
			dx := character.pos.x - gem.pos.x
			dz := character.pos.z - gem.pos.y
			if dx * dx + dz * dz < 2.25 {
				character.xp += gem.value
				sim.emit(t, Event_Gem_Collected {
					gem      = handle,
					position = {gem.pos.x, 0, gem.pos.y},
					xp       = gem.value,
					player   = player,
				})
				sim.despawn(&t.state.gems, handle)
				break
			}
		}
	}
	players := sim.iterate_present(&t.state.players)
	for character, player in sim.next(&players) {
		for character.xp >= xp_next(t.state, character.level) {
			character.xp -= xp_next(t.state, character.level)
			character.level += 1
			character.pending_levelups += 1
			sim.emit(t, Event_Level_Up {
				position = sim.Position(character.pos),
				level    = character.level,
				player   = player,
			})
		}
	}
}

// 11. Read back player positions for the next tick.
@(private)
read_back :: proc(state: ^State, world: ^World) {
	players := sim.iterate_present(&state.players)
	for character in sim.next(&players) {
		if character.alive {
			body_pos := physics.body_position(world.phys, character.body)
			character.pos = {body_pos.x, body_pos.y, body_pos.z}
		}
	}
}

// Bench helper: hold the enemy population at `count`, pre-spawned at RNG positions over the arena.
bench_prepare :: proc(state: ^State, world: ^World, count: int) {
	state.enemy_cap = u32(count)
	state.phase = .Match // the spawner refills to `count` from tick 1 on
	state.endless = true
	set_tuning(state, .Stress)
	state.circle_radius = 0
	prespawn_enemies(state, count)
}

// Spawns `count` enemies of random kinds at random positions over the arena, drawn from a stream of the session's
// seed (setup outside any tick), until the table is full; bench_prepare starts its fixed population with it.
prespawn_enemies :: proc(state: ^State, count: int) {
	rng := sim.rng_seed(u64(state.seed))
	for _ in 0 ..< count {
		x := f32(sim.rng_below(&rng, 5600)) / 100 - 28
		z := f32(sim.rng_below(&rng, 5600)) / 100 - 28
		if !spawn_enemy(state, kind_of_roll(sim.rng_below(&rng, 10)), {x, z}, 0) {
			break
		}
	}
}

// XP needed for the next level from `level` (levels start at 1).
xp_next :: proc(state: ^State, level: i32) -> i32 {
	tune := tuning(state)
	return tune.xp_first + (max(level, 1) - 1) * tune.xp_step
}
