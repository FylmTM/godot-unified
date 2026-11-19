package drift

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// The library has applied the tick's joins and leaves (sim.Players): a player who left loses their ship's body, one
// who joined (a zeroed ship) or came back (their ship as they left it) gets one at their slot's spawn.
update_players :: proc(t: ^Tick) {
	for player in t.player_changes.left {
		ship := sim.player_data(t, player) // still known: the library never forgets a member on the tick it leaves
		physics.destroy_body(t.world.phys, &ship.body)
		ship.thrust = false
	}
	for player in t.player_changes.arrived {
		spawn := t.world.spawns[sim.player_slot(t, player)]
		create_ship(t.world, sim.player_data(t, player), spawn)
		sim.emit(t, Event_Spawned{position = sim.position_2d(spawn), player = player})
	}
}

// Each present ship, before the physics step: the cooldowns count down; it thrusts along the stick (an impulse of
// stick * THRUST_ACCEL * mass * dt), turns toward the aim (the angular velocity TURN_GAIN * cross(heading, aim) capped
// at TURN_MAX, or the full TURN_MAX when the aim is behind), boosts (an impulse adding BOOST_SPEED along the heading,
// then BOOST_COOLDOWN_TICKS) and fires (every FIRE_EVERY_TICKS while held, a bullet from the nose at BULLET_SPEED
// along the heading plus the ship's velocity).
fly_ships :: proc(t: ^Tick) {
	ships := sim.iterate_present(t)
	for ship, player in sim.next(&ships) {
		input := sim.input(t, player)
		pos := physics.body_position_2d(t.world.phys, ship.body)
		heading := physics.body_rotation_2d(t.world.phys, ship.body)
		mass := physics.body_mass(t.world.phys, ship.body)
		if ship.boost_cooldown > 0 do ship.boost_cooldown -= 1
		if ship.fire_cooldown > 0 do ship.fire_cooldown -= 1
		if ship.gate_cooldown > 0 do ship.gate_cooldown -= 1

		move := dmath.stick(input.move_x, input.move_y)
		ship.thrust = move != {}
		if ship.thrust {
			physics.body_apply_linear_impulse_to_center_2d(
				t.world.phys,
				ship.body,
				move * (THRUST_ACCEL * mass * t.dt),
			)
		}
		// turn toward the aim: the rate from the cross product (the sine of the error), the full rate when it is behind
		spin: f32 = 0
		if aim := dmath.dir2_vec(input.aim); aim != {} {
			cross := dmath.cross2(heading, aim)
			if dmath.dot(heading, aim) < 0 {
				spin = cross >= 0 ? TURN_MAX : -TURN_MAX
			} else {
				spin = dmath.clamp(TURN_GAIN * cross, -TURN_MAX, TURN_MAX)
			}
		}
		physics.body_set_angular_velocity_2d(t.world.phys, ship.body, spin)

		vel := physics.body_linear_velocity_2d(t.world.phys, ship.body) // after the thrust: what a bullet inherits
		if .Boost in input.buttons && ship.boost_cooldown == 0 {
			physics.body_apply_linear_impulse_to_center_2d(t.world.phys, ship.body, heading * (BOOST_SPEED * mass))
			ship.boost_cooldown = BOOST_COOLDOWN_TICKS
			sim.emit(t, Event_Boosted{position = sim.position_2d(pos), player = player})
		}
		if .Fire in input.buttons && ship.fire_cooldown == 0 {
			ship.fire_cooldown = FIRE_EVERY_TICKS
			muzzle := pos + heading * (SHIP_RADIUS + MUZZLE_GAP)
			if bullet, _, ok := sim.spawn(&t.state.bullets); ok {
				bullet^ = {
					pos   = muzzle,
					vel   = heading * BULLET_SPEED + vel,
					owner = player,
					ttl   = BULLET_LIFE_TICKS,
				}
				ship.shots += 1
				sim.emit(t, Event_Fired{position = sim.position_2d(muzzle), player = player})
			}
		}
	}
}
