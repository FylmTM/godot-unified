// The tick (games/drift/SPEC.md "Rules", in that order).
package drift

import "unified:dmath"
import "unified:physics"
import "unified:sim"

tick :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	presence(tick)
	commands(tick)
	for player in 0 ..< PLAYERS {
		if state.ships[player].active do pilot(tick, player)
	}
	physics.set_velocity_2d(world.phys, state.station, {}, state.phase == .Over ? 0 : STATION_SPIN)
	physics.step(world.phys, DT, 4)
	move_bullets(tick)
	update_rocks(tick)
	warp_ships(tick)
	update_gems(tick)
	if state.phase == .Match do spawn_waves(tick)
	advance_phase(tick)
}

// ---- presence and commands

presence :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	for player in 0 ..< PLAYERS {
		here := player in tick.inputs.present
		ship := &state.ships[player]
		if here == ship.active do continue
		if here {
			ship^ = {
				active = true,
			}
			create_ship(state, world, player)
			sim.emit(tick, Joined{position = position_of(world.spawns[player]), player = u8(player)})
		} else {
			physics.destroy_body(world.phys, &ship.body)
			ship^ = {}
			sim.emit(tick, Left{player = u8(player)})
		}
	}
}

commands :: proc(tick: ^Tick) {
	state := tick.state
	for player in 0 ..< PLAYERS {
		for &raw in sim.commands(tick.inputs, player) {
			switch _ in sim.command_value(&raw, Command) {
			case Cmd_Start:
				if state.phase == .Lobby {
					state.phase = .Match
					state.match_tick = tick.number
					state.next_wave_tick = tick.number
					state.waves = 0
					state.rocks_left = 0
					state.score = 0
					state.matches += 1
					sim.emit(tick, Match_Started{player = u8(player)})
				}
			case Cmd_Restart:
				if state.phase == .Over do reset(state, tick.world)
			}
		}
	}
}

// ---- ships: the player's input flies their ship

pilot :: proc(tick: ^Tick, player: int) {
	state, world := tick.state, tick.world
	ship := &state.ships[player]
	input := &tick.inputs.input[player]
	pos, heading := physics.pose_2d(world.phys, ship.body)
	vel, _ := physics.velocity_2d(world.phys, ship.body)
	mass := physics.mass(world.phys, ship.body)
	move := [2]f32{f32(input.move_x), f32(input.move_y)} / 127
	ship.thrust = move != {}
	if ship.thrust do physics.apply_impulse_2d(world.phys, ship.body, move * (THRUST_ACCEL * mass * DT))
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
	vel, _ = physics.velocity_2d(world.phys, ship.body)
	physics.set_velocity_2d(world.phys, ship.body, vel, spin)
	if ship.boost_cooldown > 0 do ship.boost_cooldown -= 1
	if ship.fire_cooldown > 0 do ship.fire_cooldown -= 1
	if ship.gate_cooldown > 0 do ship.gate_cooldown -= 1
	if input.buttons & BUTTON_BOOST != 0 && ship.boost_cooldown == 0 {
		physics.apply_impulse_2d(world.phys, ship.body, heading * (BOOST_SPEED * mass))
		ship.boost_cooldown = BOOST_COOLDOWN_TICKS
		sim.emit(tick, Boosted{position = position_of(pos), player = u8(player)})
	}
	if input.buttons & BUTTON_FIRE != 0 && ship.fire_cooldown == 0 {
		ship.fire_cooldown = FIRE_EVERY_TICKS
		muzzle := pos + heading * (SHIP_RADIUS + 0.1)
		if bullet, _, ok := sim.spawn(&state.bullets); ok {
			bullet^ = {
				pos   = muzzle,
				vel   = heading * BULLET_SPEED + vel,
				ttl   = BULLET_LIFE_TICKS,
				owner = u8(player),
			}
			ship.shots += 1
			sim.emit(tick, Fired{position = position_of(muzzle), player = u8(player)})
		}
	}
}

// ---- bullets: a ray per tick against rocks, the station and walls

BULLET_QUERY :: physics.Query {
	category = CAT_BULLET,
	mask     = CAT_STATIC | CAT_ROCK | CAT_STATION,
}

move_bullets :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	bullets := sim.iterate(&state.bullets)
	for bullet, handle in sim.next(&bullets) {
		step := bullet.vel * DT
		hit, ok := physics.ray_closest(world.phys, v3(bullet.pos), v3(step), BULLET_QUERY)
		if ok {
			if hit.material >= MAT_ROCK && hit.material < MAT_ROCK + MAX_ROCKS {
				rock_index := int(hit.material - MAT_ROCK)
				rock := &state.rocks.items[rock_index]
				if sim.alive(&state.rocks, rock_index) && rock.hp > 0 {
					rock.hp -= 1
					rock.hit_tick = tick.number
					direction := dmath.normalize2(bullet.vel)
					physics.apply_impulse_2d(world.phys, rock.body, direction * BULLET_PUSH)
					sim.emit(
						tick,
						Rock_Hit {
							rock = sim.handle(&state.rocks, rock_index),
							position = sim.Position(hit.point),
							player = bullet.owner,
							size = rock.size,
						},
					)
				}
			}
			sim.despawn(&state.bullets, handle)
			continue
		}
		bullet.pos += step
		bullet.ttl -= 1
		if bullet.ttl == 0 do sim.despawn(&state.bullets, handle)
	}
}

// ---- rocks: splits, the station

update_rocks :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	station, _ := physics.pose_2d(world.phys, state.station)
	// one pass over the slots in use now: a split's rocks that reuse a free slot ahead of the walk are visited
	// this tick, the ones past the high water mark (where the walk started it) the next
	high_water := state.rocks.high_water
	rocks := sim.iterate(&state.rocks)
	for rock, handle in sim.next(&rocks) {
		if i32(handle.index) >= high_water do break
		pos, _ := physics.pose_2d(world.phys, rock.body)
		radius := ROCK_RADIUS[rock.size]
		// touching the station (its corners' circle): damage, and the rock is gone
		if state.phase != .Over &&
		   dmath.dist_sq2(pos, station) < (STATION_RADIUS + radius) * (STATION_RADIUS + radius) {
			damage := ROCK_STATION_DAMAGE[rock.size]
			if state.phase == .Match do state.station_hp = max(state.station_hp - damage, 0)
			sim.emit(tick, Station_Hit{position = position_of(pos), damage = damage, size = rock.size})
			kill_rock(state, world, handle)
			continue
		}
		if rock.hp > 0 do continue
		size, variant := rock.size, int(rock.variant)
		vel, spin := physics.velocity_2d(world.phys, rock.body)
		kill_rock(state, world, handle)
		if size == .Small {
			sim.emit(tick, Rock_Destroyed{rock = handle, position = position_of(pos), size = size})
			state.gems_dropped += 1
			if state.gems_dropped % 2 == 1 {
				if gem, _, ok := sim.spawn(&state.gems); ok do gem^ = {
					pos        = pos,
					vel        = vel * 0.3,
					spawn_tick = tick.number,
				}
			}
			continue
		}
		sim.emit(tick, Rock_Split{rock = handle, position = position_of(pos), size = size})
		child := Rock_Size(u8(size) - 1)
		direction := dmath.normalize2(vel)
		if direction == {} do direction = {1, 0}
		perpendicular := [2]f32{-direction.y, direction.x}
		offset := perpendicular * (ROCK_RADIUS[child] * 0.9)
		create_rock(state, world, child, variant, pos + offset, vel + perpendicular * ROCK_SPLIT_SPEED, spin * 0.5)
		create_rock(
			state,
			world,
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

warp_ships :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	for gate in 0 ..< world.gate_count {
		if state.gates[gate].charge > 0 do state.gates[gate].charge -= 1
	}
	for player in 0 ..< PLAYERS {
		ship := &state.ships[player]
		if !ship.active || ship.gate_cooldown > 0 do continue
		pos, rotation := physics.pose_2d(world.phys, ship.body)
		for gate in 0 ..< world.gate_count {
			gate_def := &world.gates[gate]
			if gate_def.pair < 0 || state.gates[gate].charge > 0 do continue
			if dmath.dist_sq2(pos, gate_def.pos) > GATE_RADIUS * GATE_RADIUS do continue
			to := world.gates[gate_def.pair].pos
			vel, spin := physics.velocity_2d(world.phys, ship.body)
			physics.teleport(world.phys, ship.body, v3(to), physics.quat_2d(rotation))
			physics.set_velocity_2d(world.phys, ship.body, vel, spin)
			state.gates[gate].charge = GATE_CHARGE_TICKS
			state.gates[gate_def.pair].charge = GATE_CHARGE_TICKS
			ship.gate_cooldown = GATE_CHARGE_TICKS
			sim.emit(
				tick,
				Warped {
					position = position_of(to),
					player = u8(player),
					from_gate = u8(gate),
					to_gate = u8(gate_def.pair),
				},
			)
			break
		}
	}
}

// ---- gems

update_gems :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	ship_pos: [PLAYERS][2]f32
	for player in 0 ..< PLAYERS {
		if state.ships[player].active do ship_pos[player], _ = physics.pose_2d(world.phys, state.ships[player].body)
	}
	gems := sim.iterate(&state.gems)
	each_gem: for gem, handle in sim.next(&gems) {
		gem.pos += gem.vel * DT
		gem.vel *= GEM_DRAG
		for player in 0 ..< PLAYERS {
			if !state.ships[player].active do continue
			if dmath.dist_sq2(ship_pos[player], gem.pos) > GEM_PICK_RADIUS * GEM_PICK_RADIUS do continue
			state.ships[player].gems += 1
			state.score += 1
			state.station_hp = min(state.station_hp + GEM_REPAIR, STATION_HP)
			sim.emit(tick, Gem_Picked{position = position_of(gem.pos), player = u8(player)})
			sim.despawn(&state.gems, handle)
			continue each_gem
		}
		if tick.number - gem.spawn_tick >= GEM_LIFE_TICKS do sim.despawn(&state.gems, handle)
	}
}

// ---- waves: one stream of numbers (the state's Rng) generates them in order

spawn_waves :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	if tick.number >= state.next_wave_tick {
		state.rocks_left += 3 + 2 * u32(state.waves)
		state.waves += 1
		state.next_wave_tick = tick.number + WAVE_EVERY_TICKS
		state.next_rock_tick = tick.number
		sim.emit(tick, Wave{wave = state.waves})
	}
	if state.rocks_left == 0 || tick.number < state.next_rock_tick do return
	spawner := &world.spawners[state.spawner % u32(world.spawner_count)]
	speed := ROCK_SPEED + ROCK_SPEED_PER_WAVE * f32(state.waves - 1)
	// a little spread: the drift direction turned by up to ±0.25 rad (a small-angle rotation, renormalised)
	turn := (sim.rng_f32(&state.rng) - 0.5) * 0.5
	direction := dmath.normalize2({spawner.dir.x - spawner.dir.y * turn, spawner.dir.y + spawner.dir.x * turn})
	spin := (sim.rng_f32(&state.rng) - 0.5) * 2
	variant := int(sim.rng_below(&state.rng, ROCK_VARIANTS))
	if _, ok := create_rock(state, world, .Large, variant, spawner.pos, direction * speed, spin); ok {
		state.spawner += 1
		state.rocks_left -= 1
	}
	state.next_rock_tick = tick.number + ROCK_EVERY_TICKS
}

// ---- phases

advance_phase :: proc(tick: ^Tick) {
	state := tick.state
	if tick.inputs.present == {} {
		if state.phase != .Lobby do reset(state, tick.world)
		return
	}
	switch state.phase {
	case .Lobby:
	case .Match:
		if state.station_hp <= 0 {
			state.phase = .Over
			state.over_tick = tick.number
			sim.emit(tick, Match_Over{seconds_survived = f32(tick.number - state.match_tick) * DT})
		}
	case .Over:
		if tick.number - state.over_tick >= OVER_HOLD_TICKS do reset(state, tick.world)
	}
}

// Back to the lobby: rocks, bullets and gems cleared, ships at their spawns, the station repaired.
reset :: proc(state: ^State, world: ^World) {
	rocks := sim.iterate(&state.rocks)
	for _, handle in sim.next(&rocks) do kill_rock(state, world, handle)
	// despawned one by one, not zeroed: the tables keep their generations, so views never see a key twice
	bullets := sim.iterate(&state.bullets)
	for _, handle in sim.next(&bullets) do sim.despawn(&state.bullets, handle)
	gems := sim.iterate(&state.gems)
	for _, handle in sim.next(&gems) do sim.despawn(&state.gems, handle)
	for player in 0 ..< PLAYERS {
		ship := &state.ships[player]
		if !ship.active do continue
		physics.teleport(world.phys, ship.body, v3(world.spawns[player]), physics.quat_2d({0, -1}))
		ship.fire_cooldown, ship.boost_cooldown, ship.gate_cooldown = 0, 0, 0
	}
	for &gate in state.gates do gate = {}
	state.phase = .Lobby
	state.station_hp = STATION_HP
	state.waves = 0
	state.rocks_left = 0
}

// A point on the plane in 3D (z = 0): what physics takes.
v3 :: #force_inline proc "contextless" (point: [2]f32) -> [3]f32 {
	return {point.x, point.y, 0}
}

// A point on the plane as an event's position.
position_of :: #force_inline proc "contextless" (point: [2]f32) -> sim.Position {
	return {point.x, point.y, 0}
}
