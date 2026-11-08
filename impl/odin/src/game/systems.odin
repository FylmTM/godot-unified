// The game systems in GAME.md order. Float math is scalar f32 `+ − × ÷` and sqrt only, written in
// the order the spec gives; no `matrix` types and no core:math (determinism traps, see README).
package game

import "base:intrinsics"

import b3 "../box3d"

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

@(private)
sqrtf :: #force_inline proc(x: f32) -> f32 {
	return intrinsics.sqrt(x)
}

Enemy_Stats :: struct {
	hp:     i32,
	speed:  f32,
	radius: f32,
	damage: i32,
	xp:     i32,
}

ENEMY_STATS := [Enemy_Kind]Enemy_Stats {
	.Grunt  = {10, 2.0, 0.4, 5, 1},
	.Runner = {6, 3.2, 0.35, 3, 1},
	.Brute  = {40, 1.2, 0.7, 12, 5},
}

// One tick: systems 1-11. `tick` advances to the new tick number at the end.
tick :: proc(s: ^State, ph: ^Physics, sc: ^Scratch, inputs: ^Inputs) {
	t := s.tick + 1
	sys_players(s, ph, inputs)
	sys_levelup(s, inputs)
	sys_spawner(s, t)
	sys_enemies(s, ph, sc, t)
	sys_contact(s, ph)
	sys_attack(s)
	sys_projectiles(s, ph, sc)
	sys_barrels(s, ph, t)
	sys_deaths(s)
	b3.World_Step(ph.world, DT, SUBSTEPS)
	read_back(s, ph)
	s.tick = t
}

// 1. Players: join, respawn, movement and dash.
@(private)
sys_players :: proc(s: ^State, ph: ^Physics, inputs: ^Inputs) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		in_ := inputs[p]
		absent := in_.buttons & BUTTON_ABSENT != 0
		if !pl.active {
			if absent {
				continue
			}
			player_activate(s, ph, p) // first non-absent input: the player joins
		}
		if pl.dash_cooldown > 0 {
			pl.dash_cooldown -= 1
		}
		pressed := in_.buttons & BUTTON_DASH != 0 && pl.prev_buttons & BUTTON_DASH == 0
		pl.prev_buttons = in_.buttons
		if !pl.alive {
			pl.respawn -= 1
			if pl.respawn > 0 {
				continue
			}
			player_spawn(s, ph, p)
		}
		if pressed && pl.dash_cooldown == 0 {
			pl.dash_ticks = 8
			pl.dash_cooldown = 90
		}
		dx := f32(in_.move_x) / 127
		dz := f32(in_.move_z) / 127
		vx := dx * pl.speed
		vz := dz * pl.speed
		if pl.dash_ticks > 0 {
			vx = vx * 3
			vz = vz * 3
			pl.dash_ticks -= 1
		}
		body := body_id(ph, pl.body)
		v := b3.Body_GetLinearVelocity(body)
		b3.Body_SetLinearVelocity(body, {vx, v.y, vz})
	}
}

// 2. Level-up choice.
@(private)
sys_levelup :: proc(s: ^State, inputs: ^Inputs) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		c := inputs[p].choice
		if !pl.active || pl.pending_levelups <= 0 || c < 1 || c > 3 {
			continue
		}
		switch c {
		case 1:
			pl.fire_interval = max(pl.fire_interval - 2, 6)
		case 2:
			pl.damage_bonus += 3
		case 3:
			pl.speed = pl.speed + 0.5
		}
		pl.pending_levelups -= 1
	}
}

// 3. Spawner: n enemies every 20 ticks while below the cap.
@(private)
sys_spawner :: proc(s: ^State, t: u32) {
	if t % 20 != 0 {
		return
	}
	wave := t / 600
	n := min(4 + wave * 3, 40)
	for _ in 0 ..< n {
		if u32(s.enemies.count) >= s.enemy_cap {
			break
		}
		k := rng_next(s) % 8
		jitter := f32(rng_next(s) % 1000) / 1000 * 2 - 1
		x := 27 * RING_C[k] + jitter
		z := 27 * RING_S[k] + jitter
		r := rng_next(s) % 10
		kind: Enemy_Kind = r <= 6 ? .Grunt : (r <= 8 ? .Runner : .Brute)
		spawn_enemy(s, kind, {x, z})
	}
}

spawn_enemy :: proc(s: ^State, kind: Enemy_Kind, pos: [2]f32) -> i32 {
	idx := pool_alloc(&s.enemies)
	if idx < 0 {
		return -1
	}
	st := ENEMY_STATS[kind]
	e := &s.enemies.items[idx]
	e.kind = kind
	e.pos = pos
	e.hp = st.hp
	e.speed = st.speed
	e.radius = st.radius
	e.damage = st.damage
	return idx
}

@(private)
cell_of :: #force_inline proc(pos: [2]f32) -> (cx, cz: i32) {
	cx = clamp(i32((pos.x + 30) * 0.5), 0, GRID_N - 1)
	cz = clamp(i32((pos.y + 30) * 0.5), 0, GRID_N - 1)
	return
}

// Counting sort of alive enemies into 2 m cells; items within a cell are in index order.
@(private)
build_grid :: proc(s: ^State, sc: ^Scratch) {
	sc.cell_count = {}
	hw := s.enemies.high_water
	for i in 0 ..< hw {
		e := &s.enemies.items[i]
		if !e.alive {
			sc.enemy_cell[i] = -1
			continue
		}
		cx, cz := cell_of(e.pos)
		c := cz * GRID_N + cx
		sc.enemy_cell[i] = c
		sc.cell_count[c] += 1
	}
	sum: i32 = 0
	for c in 0 ..< GRID_CELLS {
		sc.cell_start[c] = sum
		sum += sc.cell_count[c]
	}
	sc.cell_start[GRID_CELLS] = sum
	sc.cell_count = {} // reused as the fill cursor
	for i in 0 ..< hw {
		c := sc.enemy_cell[i]
		if c < 0 {
			continue
		}
		sc.cell_items[sc.cell_start[c] + sc.cell_count[c]] = i
		sc.cell_count[c] += 1
	}
}

// Nearest alive player to pos in XZ (lowest index on ties); -1 if none.
@(private)
nearest_player :: proc(s: ^State, pos: [2]f32) -> (best: int, best_d2: f32) {
	best = -1
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		if !pl.alive {
			continue
		}
		dx := pl.pos.x - pos.x
		dz := pl.pos.z - pos.y
		d2 := dx * dx + dz * dz
		if best < 0 || d2 < best_d2 {
			best = p
			best_d2 = d2
		}
	}
	return
}

// 4. Enemies: seek + separation (phase 1, old positions), integrate + push-out (phase 2).
@(private)
sys_enemies :: proc(s: ^State, ph: ^Physics, sc: ^Scratch, t: u32) {
	build_grid(s, sc)
	ray_filter := b3.DefaultQueryFilter()
	ray_filter.maskBits = CAT_CRATE | CAT_BARREL
	hw := s.enemies.high_water
	for i in 0 ..< hw {
		e := &s.enemies.items[i]
		if !e.alive {
			continue
		}
		if (u32(i) + t) % 8 == 0 {
			r := b3.World_CastRayClosest(ph.world, {e.pos.x, 3, e.pos.y}, {0, -3, 0}, ray_filter)
			e.climbing = r.hit && r.point.y > 0.8
		}
		speed := e.climbing ? e.speed * 0.5 : e.speed
		desired: [2]f32
		if p, _ := nearest_player(s, e.pos); p >= 0 {
			dx := s.players[p].pos.x - e.pos.x
			dz := s.players[p].pos.z - e.pos.y
			l := sqrtf(dx * dx + dz * dz)
			if l > 0.0001 {
				desired = {dx / l * speed, dz / l * speed}
			}
		}
		sep: [2]f32
		cx, cz := cell_of(e.pos)
		for nz in cz - 1 ..= cz + 1 {
			if nz < 0 || nz >= GRID_N {
				continue
			}
			for nx in cx - 1 ..= cx + 1 {
				if nx < 0 || nx >= GRID_N {
					continue
				}
				c := nz * GRID_N + nx
				for k in sc.cell_start[c] ..< sc.cell_start[c + 1] {
					j := sc.cell_items[k]
					if j == i {
						continue
					}
					o := &s.enemies.items[j]
					ox := e.pos.x - o.pos.x
					oz := e.pos.y - o.pos.y
					d2 := ox * ox + oz * oz
					rr := e.radius + o.radius
					if d2 < rr * rr && d2 > 0.00000001 {
						f := 0.5 / d2
						sep.x = sep.x + ox * f
						sep.y = sep.y + oz * f
					}
				}
			}
		}
		desired.x = desired.x + sep.x
		desired.y = desired.y + sep.y
		vx := e.vel.x * 0.8 + desired.x * 0.2
		vz := e.vel.y * 0.8 + desired.y * 0.2
		vmax := speed * 1.5
		s2 := vx * vx + vz * vz
		if s2 > vmax * vmax {
			k := vmax / sqrtf(s2)
			vx = vx * k
			vz = vz * k
		}
		sc.new_vel[i] = {vx, vz}
	}
	for i in 0 ..< hw {
		e := &s.enemies.items[i]
		if !e.alive {
			continue
		}
		e.vel = sc.new_vel[i]
		x := e.pos.x + e.vel.x * DT
		z := e.pos.y + e.vel.y * DT
		r := e.radius
		for k in 0 ..< 8 {
			px := 14 * RING_C[k]
			pz := 14 * RING_S[k]
			ext := 1 + r
			dx := x - px
			dz := z - pz
			adx := abs(dx)
			adz := abs(dz)
			if adx < ext && adz < ext {
				if ext - adx < ext - adz {
					x = dx >= 0 ? px + ext : px - ext
				} else {
					z = dz >= 0 ? pz + ext : pz - ext
				}
			}
		}
		lim := 30 - r
		e.pos = {clamp(x, -lim, lim), clamp(z, -lim, lim)}
	}
}

@(private)
player_dies :: proc(s: ^State, ph: ^Physics, p: int) {
	pl := &s.players[p]
	pl.alive = false
	pl.respawn = RESPAWN_TICKS
	pl.dash_ticks = 0
	destroy_body(ph, &pl.body)
}

// 5. Contact damage, one hit per enemy per 30 ticks.
@(private)
sys_contact :: proc(s: ^State, ph: ^Physics) {
	for i in 0 ..< s.enemies.high_water {
		e := &s.enemies.items[i]
		if !e.alive {
			continue
		}
		if e.contact_cooldown > 0 {
			e.contact_cooldown -= 1
			continue
		}
		for p in 0 ..< MAX_PLAYERS {
			pl := &s.players[p]
			if !pl.alive {
				continue
			}
			dx := pl.pos.x - e.pos.x
			dz := pl.pos.z - e.pos.y
			rr := e.radius + 0.45
			if dx * dx + dz * dz < rr * rr {
				pl.hp -= e.damage
				e.contact_cooldown = 30
				if pl.hp <= 0 {
					player_dies(s, ph, p)
				}
				break
			}
		}
	}
}

// 6. Auto-attack: fire at the nearest enemy within 14 m.
@(private)
sys_attack :: proc(s: ^State) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		if !pl.alive {
			continue
		}
		if pl.fire_cooldown > 0 {
			pl.fire_cooldown -= 1
			if pl.fire_cooldown > 0 {
				continue
			}
		}
		best: i32 = -1
		best_d2: f32 = 14 * 14
		for i in 0 ..< s.enemies.high_water {
			e := &s.enemies.items[i]
			if !e.alive {
				continue
			}
			dx := e.pos.x - pl.pos.x
			dz := e.pos.y - pl.pos.z
			d2 := dx * dx + dz * dz
			if d2 < best_d2 {
				best = i
				best_d2 = d2
			}
		}
		if best < 0 {
			continue
		}
		e := &s.enemies.items[best]
		dx := e.pos.x - pl.pos.x
		dz := e.pos.y - pl.pos.z
		l := sqrtf(dx * dx + dz * dz)
		if l <= 0.0001 {
			continue
		}
		idx := pool_alloc(&s.projectiles)
		if idx < 0 {
			continue
		}
		pr := &s.projectiles.items[idx]
		pr.pos = pl.pos
		pr.vel = {dx / l * 16, 0, dz / l * 16}
		pr.life = 60
		pr.damage = 5 + pl.damage_bonus
		pl.fire_cooldown = pl.fire_interval
	}
}

// 7. Projectiles: move, hit enemies (grid, first index wins), else ray-cast the segment.
@(private)
sys_projectiles :: proc(s: ^State, ph: ^Physics, sc: ^Scratch) {
	build_grid(s, sc)
	ray_filter := b3.DefaultQueryFilter()
	ray_filter.maskBits = CAT_STATIC | CAT_CRATE | CAT_BARREL
	for pi in 0 ..< s.projectiles.high_water {
		pr := &s.projectiles.items[pi]
		if !pr.alive {
			continue
		}
		step := [3]f32{pr.vel.x * DT, pr.vel.y * DT, pr.vel.z * DT}
		np := [3]f32{pr.pos.x + step.x, pr.pos.y + step.y, pr.pos.z + step.z}
		hit: i32 = -1
		cx, cz := cell_of({np.x, np.z})
		for nz in cz - 1 ..= cz + 1 {
			if nz < 0 || nz >= GRID_N {
				continue
			}
			for nx in cx - 1 ..= cx + 1 {
				if nx < 0 || nx >= GRID_N {
					continue
				}
				c := nz * GRID_N + nx
				for k in sc.cell_start[c] ..< sc.cell_start[c + 1] {
					j := sc.cell_items[k]
					if hit >= 0 && j >= hit {
						break // cells are index-ordered: nothing lower left here
					}
					e := &s.enemies.items[j]
					if e.hp <= 0 {
						continue
					}
					dx := np.x - e.pos.x
					dz := np.z - e.pos.y
					rr := e.radius + 0.15
					if dx * dx + dz * dz < rr * rr {
						hit = j
					}
				}
			}
		}
		if hit >= 0 {
			s.enemies.items[hit].hp -= pr.damage
			pool_free(&s.projectiles, pi)
			continue
		}
		r := b3.World_CastRayClosest(ph.world, b3.Vec3{pr.pos.x, pr.pos.y, pr.pos.z}, b3.Vec3{step.x, step.y, step.z}, ray_filter)
		if r.hit {
			if r.userMaterialId >= MAT_ITEM_BASE && r.userMaterialId < MAT_ITEM_BASE + ITEM_COUNT {
				it := &s.items[r.userMaterialId - MAT_ITEM_BASE]
				if it.kind == .Barrel && it.alive {
					it.hp -= pr.damage
				}
			}
			pool_free(&s.projectiles, pi)
			continue
		}
		pr.pos = np
		pr.life -= 1
		if pr.life <= 0 {
			pool_free(&s.projectiles, pi)
		}
	}
}

// 8. Barrels: respawn due barrels, then explode barrels at HP <= 0 in barrel order.
@(private)
sys_barrels :: proc(s: ^State, ph: ^Physics, t: u32) {
	for i in 0 ..< ITEM_COUNT {
		it := &s.items[i]
		if it.kind == .Barrel && !it.alive && it.respawn_tick == t {
			it.alive = true
			it.hp = BARREL_HP
			it.respawn_tick = 0
			it.body = create_item_body(ph, i)
		}
	}
	for i in 0 ..< ITEM_COUNT {
		it := &s.items[i]
		if it.kind != .Barrel || !it.alive || it.hp > 0 {
			continue
		}
		c := b3.Body_GetPosition(body_id(ph, it.body))
		center := [3]f32{c.x, c.y, c.z}
		for j in 0 ..< ITEM_COUNT {
			o := &s.items[j]
			if j == i || !o.alive {
				continue
			}
			explosion_impulse(ph, center, body_id(ph, o.body))
		}
		for p in 0 ..< MAX_PLAYERS {
			if s.players[p].alive {
				explosion_impulse(ph, center, body_id(ph, s.players[p].body))
			}
		}
		for k in 0 ..< s.enemies.high_water {
			e := &s.enemies.items[k]
			if !e.alive {
				continue
			}
			dx := e.pos.x - center.x
			dz := e.pos.y - center.z
			if dx * dx + dz * dz < 25 {
				e.hp -= 25
			}
		}
		for p in 0 ..< MAX_PLAYERS {
			pl := &s.players[p]
			if !pl.alive {
				continue
			}
			dx := pl.pos.x - center.x
			dz := pl.pos.z - center.z
			if dx * dx + dz * dz < 9 {
				pl.hp -= 15
				if pl.hp <= 0 {
					player_dies(s, ph, p)
				}
			}
		}
		destroy_body(ph, &it.body)
		it.alive = false
		it.respawn_tick = t + BARREL_RESPAWN_TICKS
		s.explosions += 1
	}
}

@(private)
explosion_impulse :: proc(ph: ^Physics, center: [3]f32, body: b3.BodyId) {
	q := b3.Body_GetPosition(body)
	dx := q.x - center.x
	dy := q.y - center.y
	dz := q.z - center.z
	d := sqrtf(dx * dx + dy * dy + dz * dz)
	if d >= 5 {
		return
	}
	hx, hz: f32
	hl := sqrtf(dx * dx + dz * dz)
	if hl > 0.0001 {
		hx = dx / hl
		hz = dz / hl
	}
	uy: f32 = 0.5
	ul := sqrtf(hx * hx + uy * uy + hz * hz)
	k := 12 * (1 - d / 5)
	b3.Body_ApplyLinearImpulseToCenter(body, {hx / ul * k, uy / ul * k, hz / ul * k}, true)
}

// 9. Deaths, gems, XP and level thresholds.
@(private)
sys_deaths :: proc(s: ^State) {
	for i in 0 ..< s.enemies.high_water {
		e := &s.enemies.items[i]
		if !e.alive || e.hp > 0 {
			continue
		}
		pos := e.pos
		value := ENEMY_STATS[e.kind].xp
		pool_free(&s.enemies, i)
		s.kills += 1
		gi := pool_alloc(&s.gems)
		if gi >= 0 {
			s.gems.items[gi].pos = pos
			s.gems.items[gi].value = value
		} else if p, _ := nearest_player(s, pos); p >= 0 {
			s.players[p].xp += value
		}
	}
	for gi in 0 ..< s.gems.high_water {
		g := &s.gems.items[gi]
		if !g.alive {
			continue
		}
		for p in 0 ..< MAX_PLAYERS {
			pl := &s.players[p]
			if !pl.alive {
				continue
			}
			dx := pl.pos.x - g.pos.x
			dz := pl.pos.z - g.pos.y
			if dx * dx + dz * dz < 2.25 {
				pl.xp += g.value
				pool_free(&s.gems, gi)
				break
			}
		}
	}
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		for pl.xp >= 10 + pl.level * 5 {
			pl.xp -= 10 + pl.level * 5
			pl.level += 1
			pl.pending_levelups += 1
		}
	}
}

// 11. Read back player positions for the next tick.
@(private)
read_back :: proc(s: ^State, ph: ^Physics) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		if pl.alive {
			q := b3.Body_GetPosition(body_id(ph, pl.body))
			pl.pos = {q.x, q.y, q.z}
		}
	}
}

// Bench helper: pre-spawn n enemies at RNG positions spread over the arena.
prespawn_enemies :: proc(s: ^State, n: int) {
	for _ in 0 ..< n {
		x := f32(rng_next(s) % 5600) / 100 - 28
		z := f32(rng_next(s) % 5600) / 100 - 28
		r := rng_next(s) % 10
		kind: Enemy_Kind = r <= 6 ? .Grunt : (r <= 8 ? .Runner : .Brute)
		if spawn_enemy(s, kind, {x, z}) < 0 {
			break
		}
	}
}
