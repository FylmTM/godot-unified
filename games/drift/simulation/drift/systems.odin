// The tick (games/drift/SPEC.md "Rules", in that order).
package drift

import "unified:dmath"
import "unified:physics"
import "unified:sim"

tick :: proc(s: ^State, w: ^World, t: u32, inputs: ^Inputs, events: Events) {
	presence(s, w, inputs, events)
	commands(s, w, t, inputs, events)
	for p in 0 ..< MAX_PLAYERS {
		if s.ships[p].active do ship(s, w, p, t, &inputs.input[p], events)
	}
	physics.set_velocity_2d(w.phys, s.station, {}, s.phase == .Over ? 0 : STATION_SPIN)
	physics.step(w.phys, DT, 4)
	bullets(s, w, t, events)
	rocks(s, w, t, events)
	gates(s, w, events)
	gems(s, w, t, events)
	if s.phase == .Match do waves(s, w, t, events)
	phases(s, w, t, inputs, events)
}

// ---- presence and commands

presence :: proc(s: ^State, w: ^World, inputs: ^Inputs, events: Events) {
	for p in 0 ..< MAX_PLAYERS {
		here := p in inputs.present
		sh := &s.ships[p]
		if here == sh.active do continue
		if here {
			sh^ = {
				active = true,
			}
			create_ship(s, w, p)
			sim.emit(events, Event_Kind.Joined, pos = v3(w.spawns[p]), slot = p)
		} else {
			physics.destroy_body(w.phys, &sh.body)
			sh^ = {}
			sim.emit(events, Event_Kind.Left, slot = p)
		}
	}
}

commands :: proc(s: ^State, w: ^World, t: u32, inputs: ^Inputs, events: Events) {
	for p in 0 ..< MAX_PLAYERS {
		for &c in sim.commands(inputs, p) {
			if _, ok := sim.command_as(&c, Cmd_Start); ok && s.phase == .Lobby {
				s.phase = .Match
				s.match_tick = t
				s.next_wave_tick = t
				s.waves = 0
				s.rocks_left = 0
				s.score = 0
				s.matches += 1
				sim.emit(events, Event_Kind.Match_Started, slot = p)
			}
			if _, ok := sim.command_as(&c, Cmd_Restart); ok && s.phase == .Over {
				reset(s, w)
			}
		}
	}
}

// ---- ships

ship :: proc(s: ^State, w: ^World, p: int, t: u32, in_: ^Input, events: Events) {
	sh := &s.ships[p]
	pos, heading := physics.pose_2d(w.phys, sh.body)
	vel, _ := physics.velocity_2d(w.phys, sh.body)
	mass := physics.mass(w.phys, sh.body)
	move := [2]f32{f32(in_.move_x), f32(in_.move_y)} / 127
	sh.thrust = move != {}
	if sh.thrust do physics.apply_impulse_2d(w.phys, sh.body, move * (THRUST_ACCEL * mass * DT))
	// turn toward the aim: the angular velocity from the cross product (the sine of the error), the full rate
	// when the aim is behind
	spin: f32 = 0
	aim := dmath.normalize2({f32(in_.aim_x), f32(in_.aim_y)})
	if aim != {} {
		c := heading.x * aim.y - heading.y * aim.x
		d := heading.x * aim.x + heading.y * aim.y
		if d < 0 {
			spin = c >= 0 ? TURN_MAX : -TURN_MAX
		} else {
			spin = clamp(TURN_GAIN * c, -TURN_MAX, TURN_MAX)
		}
	}
	vel, _ = physics.velocity_2d(w.phys, sh.body)
	physics.set_velocity_2d(w.phys, sh.body, vel, spin)
	if sh.boost_cd > 0 do sh.boost_cd -= 1
	if sh.fire_cd > 0 do sh.fire_cd -= 1
	if sh.gate_cd > 0 do sh.gate_cd -= 1
	if in_.buttons & BUTTON_BOOST != 0 && sh.boost_cd == 0 {
		physics.apply_impulse_2d(w.phys, sh.body, heading * (BOOST_SPEED * mass))
		sh.boost_cd = BOOST_COOLDOWN_TICKS
		sim.emit(events, Event_Kind.Boosted, pos = v3(pos), slot = p)
	}
	if in_.buttons & BUTTON_FIRE != 0 && sh.fire_cd == 0 {
		sh.fire_cd = FIRE_EVERY_TICKS
		muzzle := pos + heading * (SHIP_RADIUS + 0.1)
		if b, _, ok := sim.spawn(&s.bullets); ok {
			b^ = {
				pos   = muzzle,
				vel   = heading * BULLET_SPEED + vel,
				ttl   = BULLET_LIFE_TICKS,
				owner = u8(p),
			}
			sh.shots += 1
			sim.emit(events, Event_Kind.Fired, pos = v3(muzzle), slot = p)
		}
	}
}

// ---- bullets: a ray per tick against rocks, the station and walls

BULLET_QUERY :: physics.Query {
	category = CAT_BULLET,
	mask     = CAT_STATIC | CAT_ROCK | CAT_STATION,
}

bullets :: proc(s: ^State, w: ^World, t: u32, events: Events) {
	for i in 0 ..< s.bullets.high_water {
		b := sim.at(&s.bullets, i) or_continue
		step := b.vel * DT
		hit, ok := physics.ray_closest(w.phys, v3(b.pos), v3(step), BULLET_QUERY)
		if ok {
			if hit.material >= MAT_ROCK && hit.material < MAT_ROCK + MAX_ROCKS {
				ri := i32(hit.material - MAT_ROCK)
				if r, alive := sim.at(&s.rocks, ri); alive && r.hp > 0 {
					r.hp -= 1
					r.hit_tick = t
					dir := dmath.normalize2(b.vel)
					physics.apply_impulse_2d(w.phys, r.body, dir * BULLET_PUSH)
					key := sim.handle_key(sim.handle(&s.rocks, ri))
					sim.emit(events, Event_Kind.Rock_Hit, entity = key, pos = hit.point, slot = int(b.owner))
				}
			}
			sim.despawn(&s.bullets, int(i))
			continue
		}
		b.pos += step
		b.ttl -= 1
		if b.ttl == 0 do sim.despawn(&s.bullets, int(i))
	}
}

// ---- rocks: splits, the station

rocks :: proc(s: ^State, w: ^World, t: u32, events: Events) {
	station, _ := physics.pose_2d(w.phys, s.station)
	// a fixed number of passes over the rocks alive now: splits spawn into free slots this tick may also visit,
	// so the loop reads the high water once
	hw := s.rocks.high_water
	for i in 0 ..< hw {
		r := sim.at(&s.rocks, i) or_continue
		pos, _ := physics.pose_2d(w.phys, r.body)
		radius := ROCK_RADIUS[r.size]
		// touching the station (its corners' circle): damage, and the rock is gone
		if s.phase != .Over && dmath.dist_sq2(pos, station) < (STATION_RADIUS + radius) * (STATION_RADIUS + radius) {
			dmg := ROCK_STATION_DAMAGE[r.size]
			if s.phase == .Match do s.station_hp = max(s.station_hp - dmg, 0)
			sim.emit(events, Event_Kind.Station_Hit, pos = v3(pos), value = f32(dmg))
			kill_rock(s, w, i)
			continue
		}
		if r.hp > 0 do continue
		size, variant := r.size, int(r.variant)
		vel, spin := physics.velocity_2d(w.phys, r.body)
		kill_rock(s, w, i)
		if size == .Small {
			sim.emit(events, Event_Kind.Rock_Destroyed, pos = v3(pos), value = f32(size))
			s.gems_dropped += 1
			if s.gems_dropped % 2 == 1 {
				if g, _, ok := sim.spawn(&s.gems); ok do g^ = {
					pos        = pos,
					vel        = vel * 0.3,
					spawn_tick = t,
				}
			}
			continue
		}
		sim.emit(events, Event_Kind.Rock_Split, pos = v3(pos), value = f32(size))
		child := Rock_Size(u8(size) - 1)
		d := dmath.normalize2(vel)
		if d == {} do d = {1, 0}
		perp := [2]f32{-d.y, d.x}
		off := perp * (ROCK_RADIUS[child] * 0.9)
		create_rock(s, w, child, variant, pos + off, vel + perp * ROCK_SPLIT_SPEED, spin * 0.5, events)
		create_rock(
			s,
			w,
			child,
			(variant + 1) % ROCK_VARIANTS,
			pos - off,
			vel - perp * ROCK_SPLIT_SPEED,
			-spin * 0.5,
			events,
		)
	}
}

kill_rock :: proc(s: ^State, w: ^World, i: i32) {
	physics.destroy_body(w.phys, &s.rocks.items[i].body)
	sim.despawn(&s.rocks, int(i))
}

// ---- gates

gates :: proc(s: ^State, w: ^World, events: Events) {
	for g in 0 ..< w.n_gates {
		if s.gates[g].charge > 0 do s.gates[g].charge -= 1
	}
	for p in 0 ..< MAX_PLAYERS {
		sh := &s.ships[p]
		if !sh.active || sh.gate_cd > 0 do continue
		pos, rot := physics.pose_2d(w.phys, sh.body)
		for g in 0 ..< w.n_gates {
			def := &w.gates[g]
			if def.pair < 0 || s.gates[g].charge > 0 do continue
			if dmath.dist_sq2(pos, def.pos) > GATE_RADIUS * GATE_RADIUS do continue
			to := w.gates[def.pair].pos
			vel, spin := physics.velocity_2d(w.phys, sh.body)
			physics.teleport(w.phys, sh.body, v3(to), physics.quat_2d(rot))
			physics.set_velocity_2d(w.phys, sh.body, vel, spin)
			s.gates[g].charge = GATE_CHARGE_TICKS
			s.gates[def.pair].charge = GATE_CHARGE_TICKS
			sh.gate_cd = GATE_CHARGE_TICKS
			sim.emit(events, Event_Kind.Warped, pos = v3(to), value = f32(g), slot = p)
			break
		}
	}
}

// ---- gems

gems :: proc(s: ^State, w: ^World, t: u32, events: Events) {
	ships: [MAX_PLAYERS][2]f32
	for p in 0 ..< MAX_PLAYERS {
		if s.ships[p].active do ships[p], _ = physics.pose_2d(w.phys, s.ships[p].body)
	}
	outer: for i in 0 ..< s.gems.high_water {
		g := sim.at(&s.gems, i) or_continue
		g.pos += g.vel * DT
		g.vel *= GEM_DRAG
		for p in 0 ..< MAX_PLAYERS {
			if !s.ships[p].active do continue
			if dmath.dist_sq2(ships[p], g.pos) > GEM_PICK_RADIUS * GEM_PICK_RADIUS do continue
			s.ships[p].gems += 1
			s.score += 1
			s.station_hp = min(s.station_hp + GEM_REPAIR, STATION_HP)
			sim.emit(events, Event_Kind.Gem_Picked, pos = v3(g.pos), slot = p)
			sim.despawn(&s.gems, int(i))
			continue outer
		}
		if t - g.spawn_tick >= GEM_LIFE_TICKS do sim.despawn(&s.gems, int(i))
	}
}

// ---- waves

waves :: proc(s: ^State, w: ^World, t: u32, events: Events) {
	if t >= s.next_wave_tick {
		s.rocks_left += 3 + 2 * u32(s.waves)
		s.waves += 1
		s.next_wave_tick = t + WAVE_EVERY_TICKS
		s.next_rock_tick = t
		sim.emit(events, Event_Kind.Wave, value = f32(s.waves))
	}
	if s.rocks_left == 0 || t < s.next_rock_tick do return
	sp := &w.spawners[s.spawner % u32(w.n_spawners)]
	speed := ROCK_SPEED + ROCK_SPEED_PER_WAVE * f32(s.waves - 1)
	// a little spread: the drift direction turned by up to ±0.25 rad (a small-angle rotation, renormalised)
	a := (sim.rng_f32(&s.rng) - 0.5) * 0.5
	dir := dmath.normalize2({sp.dir.x - sp.dir.y * a, sp.dir.y + sp.dir.x * a})
	spin := (sim.rng_f32(&s.rng) - 0.5) * 2
	variant := int(sim.rng_below(&s.rng, ROCK_VARIANTS))
	if create_rock(s, w, .Large, variant, sp.pos, dir * speed, spin, events) {
		s.spawner += 1
		s.rocks_left -= 1
	}
	s.next_rock_tick = t + ROCK_EVERY_TICKS
}

// ---- phases

phases :: proc(s: ^State, w: ^World, t: u32, inputs: ^Inputs, events: Events) {
	if inputs.present == {} {
		if s.phase != .Lobby do reset(s, w)
		return
	}
	switch s.phase {
	case .Lobby:
	case .Match:
		if s.station_hp <= 0 {
			s.phase = .Over
			s.over_tick = t
			sim.emit(events, Event_Kind.Match_Over, value = f32(t - s.match_tick) * DT)
		}
	case .Over:
		if t - s.over_tick >= OVER_HOLD_TICKS do reset(s, w)
	}
}

// Back to the lobby: rocks, bullets and gems cleared, ships at their spawns, the station repaired.
reset :: proc(s: ^State, w: ^World) {
	for i in 0 ..< s.rocks.high_water {
		if sim.alive(&s.rocks, i) do kill_rock(s, w, i)
	}
	// despawned one by one, not zeroed: the tables keep their generations, so views never see a key twice
	for i in 0 ..< s.bullets.high_water do if sim.alive(&s.bullets, i) do sim.despawn(&s.bullets, int(i))
	for i in 0 ..< s.gems.high_water do if sim.alive(&s.gems, i) do sim.despawn(&s.gems, int(i))
	for p in 0 ..< MAX_PLAYERS {
		sh := &s.ships[p]
		if !sh.active do continue
		physics.teleport(w.phys, sh.body, v3(w.spawns[p]), physics.quat_2d({0, -1}))
		sh.fire_cd, sh.boost_cd, sh.gate_cd = 0, 0, 0
	}
	for &g in s.gates do g = {}
	s.phase = .Lobby
	s.station_hp = STATION_HP
	s.waves = 0
	s.rocks_left = 0
}

v3 :: #force_inline proc "contextless" (v: [2]f32) -> [3]f32 {
	return {v.x, v.y, 0}
}
