package holdout

import "unified:dmath"
import "unified:nav"
import "unified:physics"
import "unified:sim"

GRID_CELL :: 2 // m
GRID_N :: 38 // cells along each axis: 76 m, the yard inside its walls with a cell to spare
GRID_ORIGIN :: -GRID_N * GRID_CELL / 2

// The alive enemies by GRID_CELL cells on the floor plan (scratch, rebuilt before separation): the enemies near a point
// are those in its cell and the 8 around it (sim.grid_near), in index order; height is checked apart (SAME_FLOOR).
Enemy_Grid :: sim.Grid(GRID_N * GRID_N, MAX_ENEMIES)

// What blocks an enemy's sight of a player and a bolt's or a blast's path: the level and the core.
SIGHT_FILTER :: physics.Filter {
	category = CAT_ENEMY,
	mask     = CAT_LEVEL | CAT_CORE,
}

// Makes an enemy of `kind` on the mesh near `near` (a gate): a kinematic body (a capsule with a head sphere on top, its
// origin at its feet) tagged with its handle's key. False when the table is full or no mesh is near.
spawn_enemy :: proc(state: ^State, world: ^World, kind: Enemy_Kind, near: [3]f32) -> bool {
	poly, at := nav.nearest(&world.mesh, near, GOAL_REACH * 2)
	if poly == nav.NO_POLY do return false
	enemy, handle := sim.spawn(&state.enemies) or_return
	spec := &ENEMY_SPECS[kind]
	warp := enemy.warp + 1
	facing := dmath.normalize((world.core - at).xz)
	enemy^ = {
		pos    = at,
		facing = facing,
		poly   = poly,
		hp     = spec.hp,
		kind   = kind,
		warp   = warp,
	}
	def := physics.body_def(.Kinematic, at, dmath.quat_yaw(facing))
	enemy.body = physics.create_body(world.phys, def, sim.handle_key(handle))
	top := spec.radius + 2 * spec.half_height
	capsule := physics.Capsule{{0, spec.radius, 0}, {0, top - spec.radius, 0}, spec.radius}
	physics.create_capsule_shape(world.phys, enemy.body, physics.shape_def(CAT_ENEMY), capsule)
	head := physics.Sphere{{0, top + spec.head_radius * 0.7, 0}, spec.head_radius}
	physics.create_sphere_shape(world.phys, enemy.body, physics.shape_def(CAT_HEAD), head)
	return true
}

// The standard benchmark's population (Game.bench_prepare, `uni bench`): the last wave under way with `count` enemies
// of every kind spread over the mesh polygons that lead to the core, and a core that doesn't fall during the run.
bench_prepare :: proc(state: ^State, world: ^World, count: int) {
	state.phase, state.wave, state.core_hp = .Wave, WAVES, max(i32) / 2
	field := nav.field(&world.fields, world.core_poly)
	rng := sim.rng_seed(u64(count))
	for i in 0 ..< count {
		poly := int(sim.rng_below(&rng, u32(nav.poly_count(&world.mesh))))
		if field.cost[poly] >= nav.UNREACHABLE do continue
		spawn_enemy(state, world, Enemy_Kind(i % len(Enemy_Kind)), world.mesh.centers[poly])
	}
}

// The point an enemy's eyes and spit leave from: the middle of its head.
enemy_head :: proc(enemy: ^Enemy) -> [3]f32 {
	spec := &ENEMY_SPECS[enemy.kind]
	return enemy.pos + {0, 2 * spec.radius + 2 * spec.half_height + spec.head_radius * 0.7, 0}
}

// Each runner and spitter looks for a player every SIGHT_EVERY_TICKS (time-sliced by its index, sim.due): the nearest
// player who is up within AGGRO_RADIUS that it can see (a ray from its head to their centre the level and the core
// don't block), else none (it goes for the core). Between looks it keeps its target while that player is up.
choose_targets :: proc(t: ^Tick) {
	enemies := sim.iterate(&t.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		if !ENEMY_SPECS[enemy.kind].chases do continue
		target := sim.player_data(t, enemy.target)
		if target == nil || target.downed || !sim.player_present(t, enemy.target) do enemy.target, enemy.sees = {}, false
		if !sim.due(t, handle.index, SIGHT_EVERY_TICKS) do continue
		eye := enemy_head(enemy)
		best: sim.Player
		best_distance := AGGRO_RADIUS * AGGRO_RADIUS
		players := sim.iterate_present(t)
		for data, player in sim.next(&players) {
			if data.downed do continue
			center := player_center(t, player)
			distance := dmath.dist_sq3(center, eye)
			if distance >= best_distance do continue
			if _, blocked := physics.world_cast_ray_closest(t.world.phys, eye, center - eye, SIGHT_FILTER); blocked {
				continue
			}
			best, best_distance = player, distance
		}
		enemy.target, enemy.sees = best, best != {}
	}
}

// Where an enemy goes and how close it stops: its target player's point on the mesh, else the core's.
enemy_goal :: proc(t: ^Tick, enemy: ^Enemy) -> (poly: nav.Poly, goal: [3]f32, stop: f32) {
	spec := &ENEMY_SPECS[enemy.kind]
	if enemy.target != {} {
		poly, goal = nav.nearest(&t.world.mesh, player_center(t, enemy.target), GOAL_REACH)
		stop = SPIT_RANGE if enemy.kind == .Spitter && enemy.sees else spec.radius + PLAYER_RADIUS + spec.reach * 0.5
		if poly != nav.NO_POLY do return
	}
	poly, goal = t.world.core_poly, t.world.core_goal
	stop = SPIT_RANGE if enemy.kind == .Spitter else 0
	return
}

// Each enemy walks the mesh toward its goal (enemy_goal) along the goal's distance field (nav.field, memoized in the
// World), pushed apart from the enemies near it on its floor (SEPARATION, at most SEPARATION_SPEED), and stops where
// it attacks from; its body follows (a kinematic target transform, so the step gives it a velocity for the rewound
// shots).
move_enemies :: proc(t: ^Tick) {
	grid := &t.world.grid
	sim.grid_begin(grid, {GRID_ORIGIN, GRID_ORIGIN}, GRID_CELL, GRID_N, GRID_N)
	alive := sim.iterate(&t.state.enemies)
	for enemy, handle in sim.next(&alive) do sim.grid_add(grid, i32(handle.index), enemy.pos.xz)
	sim.grid_end(grid)
	mesh := &t.world.mesh
	enemies := sim.iterate(&t.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		spec := &ENEMY_SPECS[enemy.kind]
		goal_poly, goal, stop := enemy_goal(t, enemy)
		velocity: [2]f32
		to_goal := goal - enemy.pos
		if stop > 0 && dmath.length_sq(to_goal.xz) <= stop * stop && abs(to_goal.y) < SAME_FLOOR {
			enemy.facing = dmath.normalize(to_goal.xz)
		} else if at_core(t, enemy.pos, spec.radius) && enemy.target == {} {
			enemy.facing = dmath.normalize((t.world.core - enemy.pos).xz)
		} else {
			next := nav.steer(mesh, nav.field(&t.world.fields, goal_poly), enemy.poly, enemy.pos, goal)
			heading := dmath.normalize((next - enemy.pos).xz)
			if heading != {} do enemy.facing = heading
			velocity = heading * spec.speed
		}
		push: [2]f32
		for row in sim.grid_near(grid, enemy.pos.xz) {
			for other_index in row {
				if other_index == i32(handle.index) do continue
				other := &t.state.enemies.items[other_index]
				away := enemy.pos - other.pos
				distance_sq := dmath.length_sq(away.xz)
				if distance_sq >= SEPARATION * SEPARATION || abs(away.y) > SAME_FLOOR do continue
				if distance_sq < 0.0001 {
					away.x = other_index < i32(handle.index) ? 0.01 : -0.01 // stacked exactly: the later one steps aside
					distance_sq = 0.0001
				}
				push += away.xz * ((SEPARATION - dmath.sqrt(distance_sq)) / dmath.sqrt(distance_sq))
			}
		}
		velocity += dmath.clamp_length(push * SEPARATION_SPEED, SEPARATION_SPEED)
		if velocity != {} {
			to := enemy.pos + {velocity.x, 0, velocity.y} * t.dt
			enemy.poly, enemy.pos = nav.move(mesh, enemy.poly, enemy.pos, to)
		}
		target := physics.Transform{enemy.pos, dmath.quat_yaw(enemy.facing)}
		physics.body_set_target_transform(t.world.phys, enemy.body, target, t.dt)
	}
}

// Whether a body of `radius` at `pos` stands within CORE_REACH of the core's side (and on its floor).
at_core :: proc(t: ^Tick, pos: [3]f32, radius: f32) -> bool {
	offset := pos - t.world.core
	gap := [2]f32{abs(offset.x), abs(offset.z)} - CORE_HALF - radius
	return dmath.max(gap.x, gap.y) <= CORE_REACH && abs(offset.y) < SAME_FLOOR
}

// Each enemy whose attack timer ran out attacks what it reached: a runner its target player in reach, a spitter fires a
// bolt at its target player in sight (or the core in SPIT_RANGE), and any enemy at the core's side with no player
// target hits the core.
enemy_attacks :: proc(t: ^Tick) {
	enemies := sim.iterate(&t.state.enemies)
	for enemy in sim.next(&enemies) {
		if sim.timer_running(t, enemy.attack) do continue
		spec := &ENEMY_SPECS[enemy.kind]
		attacked := false
		if enemy.kind == .Spitter {
			from := enemy_head(enemy)
			at: [3]f32
			aimed := false
			if enemy.target != {} && enemy.sees {
				at, aimed = player_center(t, enemy.target), true
			} else if enemy.target == {} {
				core_mid := t.world.core + {0, 1.5, 0}
				reach := SPIT_RANGE + CORE_HALF + 2 // it stopped SPIT_RANGE from the mesh's edge around the core
				aimed = dmath.length_sq((core_mid - enemy.pos).xz) <= reach * reach
				at = core_mid
			}
			if aimed && dmath.length_sq(at - from) <= SPIT_REACH * SPIT_REACH {
				attacked = fire_bolt(t, from, at, spec.damage)
			}
		} else if enemy.target != {} {
			offset := player_center(t, enemy.target) - (enemy.pos + {0, spec.radius + spec.half_height, 0})
			reach := spec.radius + PLAYER_RADIUS + spec.reach
			if dmath.length_sq(offset.xz) <= reach * reach && abs(offset.y) < SAME_FLOOR {
				hurt_player(t, enemy.target, spec.damage)
				attacked = true
			}
		}
		if !attacked && enemy.target == {} && at_core(t, enemy.pos, spec.radius) && enemy.kind != .Spitter {
			hurt_core(t, i32(spec.damage))
			attacked = true
		}
		if attacked do sim.timer_start(t, &enemy.attack, spec.attack_s)
	}
}

// Takes `damage` from an enemy (at `at`, on its head when `headshot`, by `killer`, {} for none): at 0 it dies, its body
// gone with it.
damage_enemy :: proc(
	t: ^Tick,
	handle: sim.Handle(Enemy),
	damage: i16,
	at: [3]f32,
	headshot: bool,
	killer: sim.Player,
) {
	enemy := sim.get(&t.state.enemies, handle)
	if enemy == nil do return
	enemy.hp -= damage
	enemy.hit_at = t.time
	sim.emit(t, Event_Enemy_Hit{at = sim.Position(at), enemy = handle, damage = damage, headshot = headshot})
	if enemy.hp > 0 do return
	sim.emit(t, Event_Enemy_Died{at = sim.Position(enemy.pos), enemy = enemy.kind, killer = killer})
	t.state.kills += 1
	if data := sim.player_data(t, killer); data != nil && sim.player_present(t, killer) do data.kills += 1
	physics.despawn(t.world.phys, &t.state.enemies, handle)
}

// Takes `damage` from the core (no lower than 0).
hurt_core :: proc(t: ^Tick, damage: i32) {
	if t.state.core_hp <= 0 do return
	t.state.core_hp = dmath.max(t.state.core_hp - damage, 0)
	sim.emit(t, Event_Core_Hit{damage = damage, hp = t.state.core_hp})
}
