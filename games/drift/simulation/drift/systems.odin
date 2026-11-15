// The tick (games/drift/SPEC.md "Rules", in that order).
package drift

import "unified:dmath"
import "unified:physics"
import "unified:sim"

tick :: proc(t: ^Tick) {
	presence(t)
	commands(t)
	ships := sim.iterate_present(&t.state.players)
	for ship, player in sim.next(&ships) do pilot(t, ship, player)
	physics.set_velocity_2d(t.world.phys, t.state.station, {}, t.state.phase == .Over ? 0 : STATION_SPIN)
	physics.step(t.world.phys, DT, 4)
	move_bullets(t)
	update_rocks(t)
	warp_ships(t)
	update_gems(t)
	if t.state.phase == .Match do spawn_waves(t)
	advance_phase(t)
}

// ---- presence and commands

// The library has applied the tick's joins and leaves (sim.Presence): a player who left loses their ship's body, one
// who joined (a zeroed ship) or came back (their ship as they left it) gets one at their slot's spawn.
presence :: proc(t: ^Tick) {
	for player in t.left {
		// still known: the library never forgets a member on the tick it leaves
		ship := sim.player_get(&t.state.players, player)
		physics.destroy_body(t.world.phys, &ship.body)
		ship.thrust = false
	}
	for player in t.joined do spawn_ship(t, player)
	for player in t.returned do spawn_ship(t, player)
}

spawn_ship :: proc(t: ^Tick, player: sim.Player) {
	slot, _ := sim.player_slot(&t.state.players, player)
	create_ship(t.world, sim.player_get(&t.state.players, player), t.world.spawns[slot])
	sim.emit(t, Event_Spawned{position = position_of(t.world.spawns[slot]), player = player})
}

commands :: proc(t: ^Tick) {
	players := sim.iterate_present(&t.state.players)
	for _, player in sim.next(&players) {
		for &raw in sim.commands(t, player) {
			switch _ in sim.command_value(&raw, Cmd) {
			case Cmd_Start:
				if t.state.phase == .Lobby {
					t.state.phase = .Match
					t.state.match_tick = t.number
					t.state.next_wave_tick = t.number
					t.state.waves = 0
					t.state.rocks_left = 0
					t.state.score = 0
					t.state.matches += 1
					sim.emit(t, Event_Match_Started{player = player})
				}
			case Cmd_Restart:
				if t.state.phase == .Over do reset(t)
			}
		}
	}
}

// ---- ships: the player's input flies their ship

pilot :: proc(t: ^Tick, ship: ^Ship, player: sim.Player) {
	input := sim.input(t, player)
	pos, heading := physics.pose_2d(t.world.phys, ship.body)
	vel, _ := physics.velocity_2d(t.world.phys, ship.body)
	mass := physics.mass(t.world.phys, ship.body)
	move := [2]f32{f32(input.move_x), f32(input.move_y)} / 127
	ship.thrust = move != {}
	if ship.thrust do physics.apply_impulse_2d(t.world.phys, ship.body, move * (THRUST_ACCEL * mass * DT))
	// turn toward the aim: the angular velocity from the cross product (the sine of the error), the full rate
	// when the aim is behind
	spin: f32 = 0
	aim := dmath.normalize2({f32(input.aim_x), f32(input.aim_y)})
	if aim != {} {
		cross := heading.x * aim.y - heading.y * aim.x
		dot := heading.x * aim.x + heading.y * aim.y
		if dot < 0 {
			spin = cross >= 0 ? TURN_MAX : -TURN_MAX
		} else {
			spin = clamp(TURN_GAIN * cross, -TURN_MAX, TURN_MAX)
		}
	}
	vel, _ = physics.velocity_2d(t.world.phys, ship.body)
	physics.set_velocity_2d(t.world.phys, ship.body, vel, spin)
	if ship.boost_cooldown > 0 do ship.boost_cooldown -= 1
	if ship.fire_cooldown > 0 do ship.fire_cooldown -= 1
	if ship.gate_cooldown > 0 do ship.gate_cooldown -= 1
	if input.buttons & BUTTON_BOOST != 0 && ship.boost_cooldown == 0 {
		physics.apply_impulse_2d(t.world.phys, ship.body, heading * (BOOST_SPEED * mass))
		ship.boost_cooldown = BOOST_COOLDOWN_TICKS
		sim.emit(t, Event_Boosted{position = position_of(pos), player = player})
	}
	if input.buttons & BUTTON_FIRE != 0 && ship.fire_cooldown == 0 {
		ship.fire_cooldown = FIRE_EVERY_TICKS
		muzzle := pos + heading * (SHIP_RADIUS + 0.1)
		if bullet, _, ok := sim.spawn(&t.state.bullets); ok {
			bullet^ = {
				pos   = muzzle,
				vel   = heading * BULLET_SPEED + vel,
				owner = player,
				ttl   = BULLET_LIFE_TICKS,
			}
			ship.shots += 1
			sim.emit(t, Event_Fired{position = position_of(muzzle), player = player})
		}
	}
}

// ---- bullets: a ray per tick against rocks, the station and walls

BULLET_QUERY :: physics.Query {
	category = CAT_BULLET,
	mask     = CAT_STATIC | CAT_ROCK | CAT_STATION,
}

move_bullets :: proc(t: ^Tick) {
	bullets := sim.iterate(&t.state.bullets)
	for bullet, handle in sim.next(&bullets) {
		step := bullet.vel * DT
		hit, ok := physics.ray_closest(t.world.phys, v3(bullet.pos), v3(step), BULLET_QUERY)
		if ok {
			if hit.material >= MAT_ROCK && hit.material < MAT_ROCK + MAX_ROCKS {
				rock_index := int(hit.material - MAT_ROCK)
				rock := &t.state.rocks.items[rock_index]
				if sim.alive(&t.state.rocks, rock_index) && rock.hp > 0 {
					rock.hp -= 1
					rock.hit_tick = t.number
					direction := dmath.normalize2(bullet.vel)
					physics.apply_impulse_2d(t.world.phys, rock.body, direction * BULLET_PUSH)
					sim.emit(t, Event_Rock_Hit {
						rock     = sim.handle(&t.state.rocks, rock_index),
						position = sim.Position(hit.point),
						player   = bullet.owner,
						size     = rock.size,
					})
				}
			}
			sim.despawn(&t.state.bullets, handle)
			continue
		}
		bullet.pos += step
		bullet.ttl -= 1
		if bullet.ttl == 0 do sim.despawn(&t.state.bullets, handle)
	}
}

// ---- rocks: splits, the station

update_rocks :: proc(t: ^Tick) {
	station, _ := physics.pose_2d(t.world.phys, t.state.station)
	// one pass over the slots in use now: a split's rocks that reuse a free slot ahead of the walk are visited
	// this tick, the ones past the high water mark (where the walk started it) the next
	high_water := t.state.rocks.high_water
	rocks := sim.iterate(&t.state.rocks)
	for rock, handle in sim.next(&rocks) {
		if i32(handle.index) >= high_water do break
		pos, _ := physics.pose_2d(t.world.phys, rock.body)
		radius := ROCK_RADIUS[rock.size]
		// touching the station (its corners' circle): damage, and the rock is gone
		if t.state.phase != .Over &&
		   dmath.dist_sq2(pos, station) < (STATION_RADIUS + radius) * (STATION_RADIUS + radius) {
			damage := ROCK_STATION_DAMAGE[rock.size]
			if t.state.phase == .Match do t.state.station_hp = max(t.state.station_hp - damage, 0)
			sim.emit(t, Event_Station_Hit {
				position = position_of(pos),
				damage   = damage,
				size     = rock.size,
			})
			kill_rock(t.state, t.world, handle)
			continue
		}
		if rock.hp > 0 do continue
		size, variant := rock.size, int(rock.variant)
		vel, spin := physics.velocity_2d(t.world.phys, rock.body)
		kill_rock(t.state, t.world, handle)
		if size == .Small {
			sim.emit(t, Event_Rock_Destroyed {
				rock     = handle,
				position = position_of(pos),
				size     = size,
			})
			t.state.gems_dropped += 1
			if t.state.gems_dropped % 2 == 1 {
				if gem, _, ok := sim.spawn(&t.state.gems); ok do gem^ = {
					pos        = pos,
					vel        = vel * 0.3,
					spawn_tick = t.number,
				}
			}
			continue
		}
		sim.emit(t, Event_Rock_Split {
			rock     = handle,
			position = position_of(pos),
			size     = size,
		})
		child := Rock_Size(u8(size) - 1)
		direction := dmath.normalize2(vel)
		if direction == {} do direction = {1, 0}
		perpendicular := [2]f32{-direction.y, direction.x}
		offset := perpendicular * (ROCK_RADIUS[child] * 0.9)
		create_rock(t.state, t.world, child, variant, pos + offset, vel + perpendicular * ROCK_SPLIT_SPEED, spin * 0.5)
		create_rock(
			t.state,
			t.world,
			child,
			(variant + 1) % ROCK_VARIANTS,
			pos - offset,
			vel - perpendicular * ROCK_SPLIT_SPEED,
			-spin * 0.5,
		)
	}
}

kill_rock :: proc(state: ^State, world: ^World, handle: sim.Handle(Rock)) {
	physics.destroy_body(world.phys, &sim.get(&state.rocks, handle).body)
	sim.despawn(&state.rocks, handle)
}

// ---- gates

warp_ships :: proc(t: ^Tick) {
	for gate in 0 ..< t.world.gate_count {
		if t.state.gates[gate].charge > 0 do t.state.gates[gate].charge -= 1
	}
	ships := sim.iterate_present(&t.state.players)
	for ship, player in sim.next(&ships) {
		if ship.gate_cooldown > 0 do continue
		pos, rotation := physics.pose_2d(t.world.phys, ship.body)
		for gate in 0 ..< t.world.gate_count {
			gate_def := &t.world.gates[gate]
			if gate_def.pair < 0 || t.state.gates[gate].charge > 0 do continue
			if dmath.dist_sq2(pos, gate_def.pos) > GATE_RADIUS * GATE_RADIUS do continue
			to := t.world.gates[gate_def.pair].pos
			vel, spin := physics.velocity_2d(t.world.phys, ship.body)
			physics.teleport(t.world.phys, ship.body, v3(to), physics.quat_2d(rotation))
			physics.set_velocity_2d(t.world.phys, ship.body, vel, spin)
			t.state.gates[gate].charge = GATE_CHARGE_TICKS
			t.state.gates[gate_def.pair].charge = GATE_CHARGE_TICKS
			ship.gate_cooldown = GATE_CHARGE_TICKS
			sim.emit(t, Event_Warped {
				position  = position_of(to),
				player    = player,
				from_gate = u8(gate),
				to_gate   = u8(gate_def.pair),
			})
			break
		}
	}
}

// ---- gems

// A present ship where it is this tick (update_gems).
Gem_Picker :: struct {
	ship:   ^Ship,
	player: sim.Player,
	pos:    [2]f32,
}

update_gems :: proc(t: ^Tick) {
	// the present ships in slot order: the first within reach picks a gem up
	pickers: [PLAYERS]Gem_Picker
	picker_count := 0
	ships := sim.iterate_present(&t.state.players)
	for ship, player in sim.next(&ships) {
		pos, _ := physics.pose_2d(t.world.phys, ship.body)
		pickers[picker_count] = {ship, player, pos}
		picker_count += 1
	}
	gems := sim.iterate(&t.state.gems)
	each_gem: for gem, handle in sim.next(&gems) {
		gem.pos += gem.vel * DT
		gem.vel *= GEM_DRAG
		for &picker in pickers[:picker_count] {
			if dmath.dist_sq2(picker.pos, gem.pos) > GEM_PICK_RADIUS * GEM_PICK_RADIUS do continue
			picker.ship.gems += 1
			t.state.score += 1
			t.state.station_hp = min(t.state.station_hp + GEM_REPAIR, STATION_HP)
			sim.emit(t, Event_Gem_Picked{position = position_of(gem.pos), player = picker.player})
			sim.despawn(&t.state.gems, handle)
			continue each_gem
		}
		if t.number - gem.spawn_tick >= GEM_LIFE_TICKS do sim.despawn(&t.state.gems, handle)
	}
}

// ---- waves: one stream of numbers (the state's Rng) generates them in order

spawn_waves :: proc(t: ^Tick) {
	if t.number >= t.state.next_wave_tick {
		t.state.rocks_left += 3 + 2 * u32(t.state.waves)
		t.state.waves += 1
		t.state.next_wave_tick = t.number + WAVE_EVERY_TICKS
		t.state.next_rock_tick = t.number
		sim.emit(t, Event_Wave{wave = t.state.waves})
	}
	if t.state.rocks_left == 0 || t.number < t.state.next_rock_tick do return
	spawner := &t.world.spawners[t.state.spawner % u32(t.world.spawner_count)]
	speed := ROCK_SPEED + ROCK_SPEED_PER_WAVE * f32(t.state.waves - 1)
	// a little spread: the drift direction turned by up to ±0.25 rad (a small-angle rotation, renormalised)
	turn := (sim.rng_f32(&t.state.rng) - 0.5) * 0.5
	direction := dmath.normalize2({spawner.dir.x - spawner.dir.y * turn, spawner.dir.y + spawner.dir.x * turn})
	spin := (sim.rng_f32(&t.state.rng) - 0.5) * 2
	variant := int(sim.rng_below(&t.state.rng, ROCK_VARIANTS))
	if _, ok := create_rock(t.state, t.world, .Large, variant, spawner.pos, direction * speed, spin); ok {
		t.state.spawner += 1
		t.state.rocks_left -= 1
	}
	t.state.next_rock_tick = t.number + ROCK_EVERY_TICKS
}

// ---- phases

advance_phase :: proc(t: ^Tick) {
	if !anyone_present(t.state) {
		if t.state.phase != .Lobby do reset(t)
		return
	}
	switch t.state.phase {
	case .Lobby:
	case .Match:
		if t.state.station_hp <= 0 {
			t.state.phase = .Over
			t.state.over_tick = t.number
			sim.emit(t, Event_Match_Over{seconds_survived = f32(t.number - t.state.match_tick) * DT})
		}
	case .Over:
		if t.number - t.state.over_tick >= OVER_HOLD_TICKS do reset(t)
	}
}

anyone_present :: proc(state: ^State) -> bool {
	players := sim.iterate_present(&state.players)
	_, _, ok := sim.next(&players)
	return ok
}

// Back to the lobby: rocks, bullets and gems cleared, the present ships at their slots' spawns, the station
// repaired.
reset :: proc(t: ^Tick) {
	rocks := sim.iterate(&t.state.rocks)
	for _, handle in sim.next(&rocks) do kill_rock(t.state, t.world, handle)
	// despawned one by one, not zeroed: the tables keep their generations, so views never see a key twice
	bullets := sim.iterate(&t.state.bullets)
	for _, handle in sim.next(&bullets) do sim.despawn(&t.state.bullets, handle)
	gems := sim.iterate(&t.state.gems)
	for _, handle in sim.next(&gems) do sim.despawn(&t.state.gems, handle)
	ships := sim.iterate_present(&t.state.players)
	for ship, player in sim.next(&ships) {
		slot, _ := sim.player_slot(&t.state.players, player)
		physics.teleport(t.world.phys, ship.body, v3(t.world.spawns[slot]), physics.quat_2d({0, -1}))
		ship.fire_cooldown, ship.boost_cooldown, ship.gate_cooldown = 0, 0, 0
	}
	for &gate in t.state.gates do gate = {}
	t.state.phase = .Lobby
	t.state.station_hp = STATION_HP
	t.state.waves = 0
	t.state.rocks_left = 0
}

// A point on the plane in 3D (z = 0): what physics takes.
v3 :: #force_inline proc "contextless" (point: [2]f32) -> [3]f32 {
	return {point.x, point.y, 0}
}

// A point on the plane as an event's position.
position_of :: #force_inline proc "contextless" (point: [2]f32) -> sim.Position {
	return {point.x, point.y, 0}
}
