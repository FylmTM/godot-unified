// The tick (games/drift/SPEC.md "Rules", in that order).
package drift

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Advances the match one tick (GAME.tick): runs the systems below in the spec's order around the physics step.
tick :: proc(t: ^Tick) {
	presence(t)
	commands(t)
	ships := sim.iterate_present(&t.state.players)
	for ship, player in sim.next(&ships) do pilot(t, ship, player)
	physics.body_set_linear_velocity_2d(t.world.phys, t.state.station, {})
	physics.body_set_angular_velocity_2d(t.world.phys, t.state.station, t.state.phase == .Over ? 0 : STATION_SPIN)
	physics.step(t.world.phys)
	move_bullets(t)
	update_rocks(t)
	warp_ships(t)
	update_gems(t)
	if t.state.phase == .Match do spawn_waves(t)
	advance_phase(t)
}

// ---- presence and commands

// The library has applied the tick's joins and leaves (sim.Players): a player who left loses their ship's body, one
// who joined (a zeroed ship) or came back (their ship as they left it) gets one at their slot's spawn.
presence :: proc(t: ^Tick) {
	for player in t.player_changes.left {
		// still known: the library never forgets a member on the tick it leaves
		ship := sim.player_data(t, player)
		physics.destroy_body(t.world.phys, &ship.body)
		ship.thrust = false
	}
	for player in t.player_changes.arrived do spawn_ship(t, player)
}

// A joining player's ship, at their slot's spawn point.
spawn_ship :: proc(t: ^Tick, player: sim.Player) {
	slot := sim.player_slot(t, player)
	create_ship(t.world, sim.player_data(t, player), t.world.spawns[slot])
	sim.emit(t, Event_Spawned{position = position_of(t.world.spawns[slot]), player = player})
}

// Applies this tick's commands: `start` begins a match from the lobby, `restart` resets an over match at once.
// Either is ignored outside its phase.
commands :: proc(t: ^Tick) {
	players := sim.iterate_present(&t.state.players)
	for _, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			switch _ in sent {
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

// Flies one present player's ship from their input before the physics step: thrust, turning toward the aim,
// boost, and firing bullets; it also counts down the ship's cooldowns.
pilot :: proc(t: ^Tick, ship: ^Ship, player: sim.Player) {
	input := sim.input(t, player)
	pos := physics.body_position_2d(t.world.phys, ship.body)
	heading := physics.body_rotation_2d(t.world.phys, ship.body)
	mass := physics.body_mass(t.world.phys, ship.body)
	move := dmath.stick(input.move_x, input.move_y)
	ship.thrust = move != {}
	if ship.thrust do physics.body_apply_linear_impulse_to_center_2d(t.world.phys, ship.body, move * (THRUST_ACCEL * mass * t.dt))
	// turn toward the aim: the angular velocity from the cross product (the sine of the error), the full rate
	// when the aim is behind
	spin: f32 = 0
	aim := dmath.dir2_vec(input.aim)
	if aim != {} {
		cross := heading.x * aim.y - heading.y * aim.x
		dot := heading.x * aim.x + heading.y * aim.y
		if dot < 0 {
			spin = cross >= 0 ? TURN_MAX : -TURN_MAX
		} else {
			spin = dmath.clamp(TURN_GAIN * cross, -TURN_MAX, TURN_MAX)
		}
	}
	vel := physics.body_linear_velocity_2d(t.world.phys, ship.body) // after the thrust: what a bullet inherits
	physics.body_set_angular_velocity_2d(t.world.phys, ship.body, spin)
	if ship.boost_cooldown > 0 do ship.boost_cooldown -= 1
	if ship.fire_cooldown > 0 do ship.fire_cooldown -= 1
	if ship.gate_cooldown > 0 do ship.gate_cooldown -= 1
	if .Boost in input.buttons && ship.boost_cooldown == 0 {
		physics.body_apply_linear_impulse_to_center_2d(t.world.phys, ship.body, heading * (BOOST_SPEED * mass))
		ship.boost_cooldown = BOOST_COOLDOWN_TICKS
		sim.emit(t, Event_Boosted{position = position_of(pos), player = player})
	}
	if .Fire in input.buttons && ship.fire_cooldown == 0 {
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

BULLET_QUERY :: physics.Filter {
	category = CAT_BULLET,
	mask     = CAT_STATIC | CAT_ROCK | CAT_STATION,
}

// Moves every bullet one tick along a ray: a hit ends it (and a rock it hits loses 1 HP and is pushed), otherwise it
// expires when its lifetime runs out.
move_bullets :: proc(t: ^Tick) {
	bullets := sim.iterate(&t.state.bullets)
	for bullet, handle in sim.next(&bullets) {
		step := bullet.vel * t.dt
		hit, ok := physics.world_cast_ray_closest(t.world.phys, v3(bullet.pos), v3(step), BULLET_QUERY)
		if ok {
			if hit.category & CAT_ROCK != 0 {
				rock_handle := sim.handle_of_key(Rock, hit.tag)
				if rock := sim.get(&t.state.rocks, rock_handle); rock != nil && rock.hp > 0 {
					rock.hp -= 1
					rock.hit_tick = t.number
					direction := dmath.normalize(bullet.vel)
					physics.body_apply_linear_impulse_to_center_2d(t.world.phys, rock.body, direction * BULLET_PUSH)
					sim.emit(t, Event_Rock_Hit {
						rock     = rock_handle,
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

// Resolves the rocks after the physics step: one touching the station damages it and is gone, one out of HP splits
// into two of the next size, or, when small, is destroyed and every other one drops a gem.
update_rocks :: proc(t: ^Tick) {
	station := physics.body_position_2d(t.world.phys, t.state.station)
	// a split's rocks that reuse a free slot ahead of the walk are visited this tick, the ones in fresh slots the next
	rocks := sim.iterate(&t.state.rocks)
	for rock, handle in sim.next(&rocks) {
		pos := physics.body_position_2d(t.world.phys, rock.body)
		radius := ROCK_RADIUS[rock.size]
		// touching the station (its corners' circle): damage, and the rock is gone
		if t.state.phase != .Over &&
		   dmath.dist_sq2(pos, station) < (STATION_RADIUS + radius) * (STATION_RADIUS + radius) {
			damage := ROCK_STATION_DAMAGE[rock.size]
			if t.state.phase == .Match do t.state.station_hp = dmath.max(t.state.station_hp - damage, 0)
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
		vel := physics.body_linear_velocity_2d(t.world.phys, rock.body)
		spin := physics.body_angular_velocity_2d(t.world.phys, rock.body)
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
		direction := dmath.normalize(vel)
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

// Removes a rock: destroys its body and frees its table slot.
kill_rock :: proc(state: ^State, world: ^World, handle: sim.Handle(Rock)) {
	physics.despawn(world.phys, &state.rocks, handle)
}

// ---- gates

// Recharges the gates and warps a ship that comes within reach of a charged gate to its pair, keeping its heading
// and velocity; both gates then recharge.
warp_ships :: proc(t: ^Tick) {
	for gate in 0 ..< t.world.gate_count {
		if t.state.gates[gate].charge > 0 do t.state.gates[gate].charge -= 1
	}
	ships := sim.iterate_present(&t.state.players)
	for ship, player in sim.next(&ships) {
		if ship.gate_cooldown > 0 do continue
		pos := physics.body_position_2d(t.world.phys, ship.body)
		rotation := physics.body_rotation_2d(t.world.phys, ship.body)
		for gate in 0 ..< t.world.gate_count {
			gate_def := &t.world.gates[gate]
			if gate_def.pair < 0 || t.state.gates[gate].charge > 0 do continue
			if dmath.dist_sq2(pos, gate_def.pos) > GATE_RADIUS * GATE_RADIUS do continue
			to := t.world.gates[gate_def.pair].pos
			physics.body_set_transform_2d(t.world.phys, ship.body, to, rotation) // velocities kept
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
		pos := physics.body_position_2d(t.world.phys, ship.body)
		pickers[picker_count] = {ship, player, pos}
		picker_count += 1
	}
	gems := sim.iterate(&t.state.gems)
	each_gem: for gem, handle in sim.next(&gems) {
		gem.pos += gem.vel * t.dt
		gem.vel *= GEM_DRAG
		for &picker in pickers[:picker_count] {
			if dmath.dist_sq2(picker.pos, gem.pos) > GEM_PICK_RADIUS * GEM_PICK_RADIUS do continue
			picker.ship.gems += 1
			t.state.score += 1
			t.state.station_hp = dmath.min(t.state.station_hp + GEM_REPAIR, STATION_HP)
			sim.emit(t, Event_Gem_Picked{position = position_of(gem.pos), player = picker.player})
			sim.despawn(&t.state.gems, handle)
			continue each_gem
		}
		if t.number - gem.spawn_tick >= GEM_LIFE_TICKS do sim.despawn(&t.state.gems, handle)
	}
}

// ---- waves: one stream of numbers (the state's Rng) generates them in order

// During a match, starts a wave every WAVE_EVERY_TICKS and spawns its large rocks one at a time from the rock spawn
// markers in turn, with speed, spread, spin and shape from keyed rolls (Roll).
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
	turn := (sim.roll_f32(t, Roll.Rock_Turn) - 0.5) * 0.5
	direction := dmath.normalize({spawner.dir.x - spawner.dir.y * turn, spawner.dir.y + spawner.dir.x * turn})
	spin := (sim.roll_f32(t, Roll.Rock_Spin) - 0.5) * 2
	variant := int(sim.roll_below(t, ROCK_VARIANTS, Roll.Rock_Variant))
	if _, ok := create_rock(t.state, t.world, .Large, variant, spawner.pos, direction * speed, spin); ok {
		t.state.spawner += 1
		t.state.rocks_left -= 1
	}
	t.state.next_rock_tick = t.number + ROCK_EVERY_TICKS
}

// ---- phases

// Moves the phase on at the end of the tick: a match is over when the station's HP is 0, an over match resets after
// OVER_HOLD_TICKS, and the world resets whenever nobody is present.
advance_phase :: proc(t: ^Tick) {
	if sim.present_count(t) == 0 {
		if t.state.phase != .Lobby do reset(t)
		return
	}
	switch t.state.phase {
	case .Lobby:
	case .Match:
		if t.state.station_hp <= 0 {
			t.state.phase = .Over
			t.state.over_tick = t.number
			sim.emit(t, Event_Match_Over{seconds_survived = sim.seconds(t.number - t.state.match_tick, TICK_HZ)})
		}
	case .Over:
		if t.number - t.state.over_tick >= OVER_HOLD_TICKS do reset(t)
	}
}

// Back to the lobby: rocks, bullets and gems cleared, the present ships at their slots' spawns, the station
// repaired.
reset :: proc(t: ^Tick) {
	physics.despawn_all(t.world.phys, &t.state.rocks)
	sim.despawn_all(&t.state.bullets)
	sim.despawn_all(&t.state.gems)
	ships := sim.iterate_present(&t.state.players)
	for ship, player in sim.next(&ships) {
		slot := sim.player_slot(t, player)
		physics.body_set_transform_2d(t.world.phys, ship.body, t.world.spawns[slot], {0, -1})
		physics.body_set_linear_velocity(t.world.phys, ship.body, {})
		physics.body_set_angular_velocity(t.world.phys, ship.body, {})
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
