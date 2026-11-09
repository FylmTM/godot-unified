// The game systems in GAME.md order. Float math is scalar f32 `+ − × ÷` and sqrt only, written in
// the order the spec gives; no `matrix` types and no core:math (determinism traps, see README).
package survivor

import b3 "unified:box3d"
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

// One tick (t = the tick being computed): systems 1-11.
tick :: proc(s: ^State, w: ^World, t: u32, inputs: ^Inputs, ev: ^[dynamic]sim.Event) {
	sys_players(s, w, inputs, ev)
	sys_levelup(s, inputs, ev)
	sys_spawner(s, t)
	sys_enemies(s, w, t)
	sys_contact(s, w, ev)
	sys_attack(s)
	sys_projectiles(s, w, t)
	sys_barrels(s, w, t, ev)
	sys_deaths(s, t, ev)
	physics.step(w.phys, DT, SUBSTEPS)
	read_back(s, w)
	sys_phase(s, w, t, ev)
}

// 12. Phases: lobby -> match when a player leaves the start circle; match -> over when every
// present player is dead at once (or nobody is present); over -> lobby (world reset) after the hold.
@(private)
sys_phase :: proc(s: ^State, w: ^World, t: u32, ev: ^[dynamic]sim.Event) {
	present, alive := 0, 0
	for &pl in s.players {
		present += int(pl.active)
		alive += int(pl.active && pl.alive)
	}
	switch s.phase {
	case .Lobby:
		r2 := s.circle_radius * s.circle_radius
		for &pl, p in s.players {
			if pl.active && pl.alive && pl.pos.x * pl.pos.x + pl.pos.z * pl.pos.z > r2 {
				s.phase = .Match
				s.match_tick = t
				s.over_tick = 0
				s.wave = 0
				s.circle_radius = 0
				s.matches += 1
				sim.emit(ev, Event_Kind.Match_Started, u32(p), pl.pos, slot = p)
				break
			}
		}
	case .Match:
		s.wave = (t - s.match_tick) / tuning(s).wave_ticks
		if present == 0 {
			reset_world(s, w, ev)
		} else if alive == 0 && !s.endless {
			s.phase = .Over
			s.over_tick = t
			sim.emit(ev, Event_Kind.Match_Over, value = f32(t - s.match_tick) * DT)
		}
	case .Over:
		if t - s.over_tick >= OVER_HOLD_TICKS {
			reset_world(s, w, ev)
		}
	}
}

// Back to the lobby: every dynamic body is destroyed and rebuilt in creation order (items, then
// present players at their start spots with fresh progress); enemies, projectiles and gems go.
reset_world :: proc(s: ^State, w: ^World, ev: ^[dynamic]sim.Event) {
	for &it in s.items {
		destroy_body(w, &it.body)
	}
	for &pl in s.players {
		destroy_body(w, &pl.body)
	}
	for i in 0 ..< ITEM_COUNT {
		item_reset(s, w, i)
	}
	for p in 0 ..< MAX_PLAYERS {
		player_reset_stats(s, p)
		if s.players[p].active {
			player_spawn(s, w, p)
			sim.emit(ev, Event_Kind.Player_Respawned, u32(p), s.players[p].pos, slot = p)
		}
	}
	s.enemies = {}
	s.projectiles = {}
	s.gems = {}
	s.phase = .Lobby
	s.circle_radius = START_RADIUS
	s.match_tick = 0
	s.over_tick = 0
	s.wave = 0
}

// 1. Players: join, respawn, movement and dash.
@(private)
sys_players :: proc(s: ^State, w: ^World, inputs: ^Inputs, ev: ^[dynamic]sim.Event) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		in_ := inputs.input[p]
		present := p in inputs.present
		if present != pl.active {
			if present {
				player_activate(s, w, p)
				sim.emit(ev, Event_Kind.Player_Joined, u32(p), pl.pos, slot = p)
			} else {
				sim.emit(ev, Event_Kind.Player_Left, u32(p), pl.pos, slot = p)
				player_deactivate(s, w, p)
			}
		}
		if !present {
			continue
		}
		if pl.dash_cooldown > 0 {
			pl.dash_cooldown -= 1
		}
		pressed := in_.buttons & BUTTON_DASH != 0 && pl.prev_buttons & BUTTON_DASH == 0
		pl.prev_buttons = in_.buttons
		if !pl.alive {
			if s.phase == .Over {
				continue // nobody respawns until the reset
			}
			pl.respawn -= 1
			if pl.respawn > 0 {
				continue
			}
			player_spawn(s, w, p)
			sim.emit(ev, Event_Kind.Player_Respawned, u32(p), pl.pos, slot = p)
		}
		if pressed && pl.dash_cooldown == 0 {
			pl.dash_ticks = DASH_TICKS
			pl.dash_cooldown = DASH_COOLDOWN_TICKS
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
		body := body_id(w, pl.body)
		v := b3.Body_GetLinearVelocity(body)
		b3.Body_SetLinearVelocity(body, {vx, v.y, vz})
	}
}

// 2. Level-up choice.
@(private)
sys_levelup :: proc(s: ^State, inputs: ^Inputs, ev: ^[dynamic]sim.Event) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		c := inputs.input[p].choice
		option, seq := choice_option(c), choice_seq(c)
		if !pl.active || pl.pending_levelups <= 0 || option == 0 || seq == 0 || seq == pl.choice_seq {
			continue // no pick, nothing to pick, or a repeat of the pick already applied
		}
		pl.choice_seq = seq
		switch option {
		case 1:
			pl.fire_interval = max(pl.fire_interval - FIRE_LEVELUP_TICKS, FIRE_INTERVAL_MIN_TICKS)
		case 2:
			pl.damage_bonus += DAMAGE_LEVELUP
		case 3:
			pl.speed = pl.speed + SPEED_LEVELUP
		}
		pl.pending_levelups -= 1
	}
}

// 3. Spawner: n enemies every 20 ticks while below the cap.
@(private)
sys_spawner :: proc(s: ^State, t: u32) {
	tn := tuning(s)
	if s.phase != .Match || (t - s.match_tick) % tn.spawn_every_ticks != 0 {
		return
	}
	present: u32 = 0
	for &pl in s.players {
		present += u32(pl.active)
	}
	n := min(tn.spawn_base + s.wave * tn.spawn_per_wave, tn.spawn_cap)
	n = n * (100 + tn.extra_player_pct * (max(present, 1) - 1)) / 100
	for _ in 0 ..< n {
		if u32(s.enemies.count) >= s.enemy_cap {
			break
		}
		k := sim.rng_below(&s.rng, 8)
		jitter := f32(sim.rng_below(&s.rng, 1000)) / 1000 * 2 - 1
		x := 27 * dmath.DIR8_C[k] + jitter
		z := 27 * dmath.DIR8_S[k] + jitter
		r := sim.rng_below(&s.rng, 10)
		kind: Enemy_Kind = r <= 6 ? .Grunt : (r <= 8 ? .Runner : .Brute)
		spawn_enemy(s, kind, {x, z}, t)
	}
}

spawn_enemy :: proc(s: ^State, kind: Enemy_Kind, pos: [2]f32, t: u32) -> bool {
	e, _ := sim.spawn(&s.enemies) or_return
	st := ENEMY_STATS[kind]
	e.spawn_tick = t
	e.kind = kind
	e.pos = pos
	e.hp = st.hp * (100 + tuning(s).hp_pct_per_wave * i32(s.wave)) / 100
	e.speed = st.speed
	e.radius = st.radius
	e.damage = st.damage
	return true
}

@(private)
cell_of :: #force_inline proc(pos: [2]f32) -> (cx, cz: i32) {
	cx = dmath.to_i32_clamped((pos.x + 30) * 0.5, 0, GRID_N - 1)
	cz = dmath.to_i32_clamped((pos.y + 30) * 0.5, 0, GRID_N - 1)
	return
}

// Counting sort of alive enemies into 2 m cells; items within a cell are in index order.
@(private)
build_grid :: proc(s: ^State, sc: ^Scratch) {
	sc.cell_count = {}
	hw := s.enemies.high_water
	for i in 0 ..< hw {
		e, ok := sim.at(&s.enemies, i)
		if !ok {
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
sys_enemies :: proc(s: ^State, w: ^World, t: u32) {
	sc := &w.scratch
	build_grid(s, sc)
	ray_filter := physics.Query {
		mask = CAT_CRATE | CAT_BARREL,
	}
	hw := s.enemies.high_water
	for i in 0 ..< hw {
		e := sim.at(&s.enemies, i) or_continue
		if (u32(i) + t) % CLIMB_CHECK_TICKS == 0 {
			r, hit := physics.ray_first(w.phys, {e.pos.x, 3, e.pos.y}, {0, -3, 0}, ray_filter)
			e.climbing = hit && r.point.y > 0.8
		}
		speed := e.climbing ? e.speed * 0.5 : e.speed
		desired: [2]f32
		if p, _ := nearest_player(s, e.pos); p >= 0 {
			dx := s.players[p].pos.x - e.pos.x
			dz := s.players[p].pos.z - e.pos.y
			l := dmath.sqrt(dx * dx + dz * dz)
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
			k := vmax / dmath.sqrt(s2)
			vx = vx * k
			vz = vz * k
		}
		sc.new_vel[i] = {vx, vz}
	}
	for i in 0 ..< hw {
		e := sim.at(&s.enemies, i) or_continue
		e.vel = sc.new_vel[i]
		x := e.pos.x + e.vel.x * DT
		z := e.pos.y + e.vel.y * DT
		r := e.radius
		for k in 0 ..< 8 {
			px := 14 * dmath.DIR8_C[k]
			pz := 14 * dmath.DIR8_S[k]
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

// Damages an alive player; at HP <= 0 it dies (body destroyed, respawn timer set).
damage_player :: proc(s: ^State, w: ^World, p: int, amount: i32, ev: ^[dynamic]sim.Event) {
	pl := &s.players[p]
	if !pl.alive {
		return
	}
	pl.hp -= amount
	if pl.hp <= 0 {
		player_dies(s, w, p, ev)
	}
}

@(private)
player_dies :: proc(s: ^State, w: ^World, p: int, ev: ^[dynamic]sim.Event) {
	pl := &s.players[p]
	sim.emit(ev, Event_Kind.Player_Died, u32(p), pl.pos, slot = p)
	pl.alive = false
	pl.respawn = RESPAWN_TICKS
	pl.dash_ticks = 0
	destroy_body(w, &pl.body)
}

// 5. Contact damage, one hit per enemy per 30 ticks.
@(private)
sys_contact :: proc(s: ^State, w: ^World, ev: ^[dynamic]sim.Event) {
	for i in 0 ..< s.enemies.high_water {
		e := sim.at(&s.enemies, i) or_continue
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
				e.contact_cooldown = CONTACT_COOLDOWN_TICKS
				if pl.hp <= 0 {
					player_dies(s, w, p, ev)
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
			e := sim.at(&s.enemies, i) or_continue
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
		l := dmath.sqrt(dx * dx + dz * dz)
		if l <= 0.0001 {
			continue
		}
		pr, _ := sim.spawn(&s.projectiles) or_continue
		pr.pos = pl.pos
		pr.vel = {dx / l * 16, 0, dz / l * 16}
		pr.life = PROJECTILE_LIFE_TICKS
		pr.damage = 5 + pl.damage_bonus
		pl.fire_cooldown = pl.fire_interval
	}
}

// 7. Projectiles: move, hit enemies (grid, first index wins), else ray-cast the segment.
@(private)
sys_projectiles :: proc(s: ^State, w: ^World, t: u32) {
	sc := &w.scratch
	build_grid(s, sc)
	ray_filter := physics.Query {
		mask = CAT_STATIC | CAT_CRATE | CAT_BARREL,
	}
	for pi in 0 ..< s.projectiles.high_water {
		pr := sim.at(&s.projectiles, pi) or_continue
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
			s.enemies.items[hit].hit_tick = t
			sim.despawn(&s.projectiles, int(pi))
			continue
		}
		if r, hit := physics.ray_first(w.phys, pr.pos, step, ray_filter); hit {
			if r.material >= MAT_ITEM_BASE && r.material < MAT_ITEM_BASE + ITEM_COUNT {
				it := &s.items[r.material - MAT_ITEM_BASE]
				if it.kind == .Barrel && it.alive {
					it.hp -= pr.damage
				}
			}
			sim.despawn(&s.projectiles, int(pi))
			continue
		}
		pr.pos = np
		pr.life -= 1
		if pr.life <= 0 {
			sim.despawn(&s.projectiles, int(pi))
		}
	}
}

// 8. Barrels: respawn due barrels, then explode barrels at HP <= 0 in barrel order.
@(private)
sys_barrels :: proc(s: ^State, w: ^World, t: u32, ev: ^[dynamic]sim.Event) {
	for i in 0 ..< ITEM_COUNT {
		it := &s.items[i]
		if it.kind == .Barrel && !it.alive && it.respawn_tick == t {
			it.alive = true
			it.hp = BARREL_HP
			it.respawn_tick = 0
			it.body = create_item_body(w, i)
		}
	}
	for i in 0 ..< ITEM_COUNT {
		it := &s.items[i]
		if it.kind != .Barrel || !it.alive || it.hp > 0 {
			continue
		}
		c := b3.Body_GetPosition(body_id(w, it.body))
		center := [3]f32{c.x, c.y, c.z}
		for j in 0 ..< ITEM_COUNT {
			o := &s.items[j]
			if j == i || !o.alive {
				continue
			}
			explosion_impulse(w, center, body_id(w, o.body))
		}
		for p in 0 ..< MAX_PLAYERS {
			if s.players[p].alive {
				explosion_impulse(w, center, body_id(w, s.players[p].body))
			}
		}
		for k in 0 ..< s.enemies.high_water {
			e := sim.at(&s.enemies, k) or_continue
			dx := e.pos.x - center.x
			dz := e.pos.y - center.z
			if dx * dx + dz * dz < 25 {
				e.hp -= 25
				e.hit_tick = t
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
					player_dies(s, w, p, ev)
				}
			}
		}
		destroy_body(w, &it.body)
		sim.emit(ev, Event_Kind.Barrel_Exploded, entity = u32(i + 1), pos = center) // item keys are index + 1
		it.alive = false
		it.respawn_tick = t + BARREL_RESPAWN_TICKS
		s.explosions += 1
	}
}

@(private)
explosion_impulse :: proc(w: ^World, center: [3]f32, body: b3.BodyId) {
	q := b3.Body_GetPosition(body)
	dx := q.x - center.x
	dy := q.y - center.y
	dz := q.z - center.z
	d := dmath.sqrt(dx * dx + dy * dy + dz * dz)
	if d >= 5 {
		return
	}
	hx, hz: f32
	hl := dmath.sqrt(dx * dx + dz * dz)
	if hl > 0.0001 {
		hx = dx / hl
		hz = dz / hl
	}
	uy: f32 = 0.5
	ul := dmath.sqrt(hx * hx + uy * uy + hz * hz)
	k := 12 * (1 - d / 5)
	b3.Body_ApplyLinearImpulseToCenter(body, {hx / ul * k, uy / ul * k, hz / ul * k}, true)
}

// 9. Deaths, gems, XP and level thresholds.
@(private)
sys_deaths :: proc(s: ^State, t: u32, ev: ^[dynamic]sim.Event) {
	for i in 0 ..< s.enemies.high_water {
		e := sim.at(&s.enemies, i) or_continue
		if e.hp > 0 {
			continue
		}
		pos := e.pos
		value := ENEMY_STATS[e.kind].xp
		sim.emit(ev, Event_Kind.Enemy_Died, sim.handle_key(sim.handle(&s.enemies, i)), {pos.x, 0, pos.y}, f32(e.kind))
		sim.despawn(&s.enemies, int(i))
		s.kills += 1
		if g, _, ok := sim.spawn(&s.gems); ok {
			g.pos = pos
			g.value = value
			g.spawn_tick = t
		} else if p, _ := nearest_player(s, pos); p >= 0 {
			s.players[p].xp += value
		}
	}
	for gi in 0 ..< s.gems.high_water {
		g := sim.at(&s.gems, gi) or_continue
		for p in 0 ..< MAX_PLAYERS {
			pl := &s.players[p]
			if !pl.alive {
				continue
			}
			dx := pl.pos.x - g.pos.x
			dz := pl.pos.z - g.pos.y
			if dx * dx + dz * dz < 2.25 {
				pl.xp += g.value
				sim.emit(
					ev,
					Event_Kind.Gem_Collected,
					sim.handle_key(sim.handle(&s.gems, gi)),
					{g.pos.x, 0, g.pos.y},
					f32(g.value),
					p,
				)
				sim.despawn(&s.gems, int(gi))
				break
			}
		}
	}
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		for pl.xp >= xp_next(s, pl.level) {
			pl.xp -= xp_next(s, pl.level)
			pl.level += 1
			pl.pending_levelups += 1
			sim.emit(ev, Event_Kind.Level_Up, u32(p), pl.pos, f32(pl.level), p)
		}
	}
}

// 11. Read back player positions for the next tick.
@(private)
read_back :: proc(s: ^State, w: ^World) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		if pl.alive {
			q := b3.Body_GetPosition(body_id(w, pl.body))
			pl.pos = {q.x, q.y, q.z}
		}
	}
}

// Bench helper: hold the enemy population at n, pre-spawned at RNG positions over the arena.
bench_prepare :: proc(s: ^State, w: ^World, n: int) {
	s.enemy_cap = u32(n)
	s.phase = .Match // the spawner refills to n from tick 1 on
	s.endless = true
	set_tuning(s, .Stress)
	s.circle_radius = 0
	prespawn_enemies(s, n)
}

prespawn_enemies :: proc(s: ^State, n: int) {
	for _ in 0 ..< n {
		x := f32(sim.rng_below(&s.rng, 5600)) / 100 - 28
		z := f32(sim.rng_below(&s.rng, 5600)) / 100 - 28
		r := sim.rng_below(&s.rng, 10)
		kind: Enemy_Kind = r <= 6 ? .Grunt : (r <= 8 ? .Runner : .Brute)
		if !spawn_enemy(s, kind, {x, z}, 0) {
			break
		}
	}
}

// XP needed for the next level from `level` (levels start at 1).
xp_next :: proc(s: ^State, level: i32) -> i32 {
	tn := tuning(s)
	return tn.xp_first + (max(level, 1) - 1) * tn.xp_step
}
