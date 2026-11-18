package drift

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// The station turns, except while the match is over.
turn_station :: proc(t: ^Tick) {
	spin: f32 = t.state.phase == .Over ? 0 : STATION_SPIN
	physics.body_set_angular_velocity_2d(t.world.phys, t.state.station, spin)
}

// After the physics step, a rock touching the station (its corners' circle) is gone, and costs it the rock's
// station_damage during a match. Nothing hits it while the match is over.
hit_station :: proc(t: ^Tick) {
	if t.state.phase == .Over do return
	station := physics.body_position_2d(t.world.phys, t.state.station)
	rocks := sim.iterate(&t.state.rocks)
	for rock, handle in sim.next(&rocks) {
		pos := physics.body_position_2d(t.world.phys, rock.body)
		reach := STATION_RADIUS + ROCK_STATS[rock.size].radius
		if dmath.dist_sq(pos, station) >= reach * reach do continue
		damage := ROCK_STATS[rock.size].station_damage
		if t.state.phase == .Match do t.state.station_hp = dmath.max(t.state.station_hp - damage, 0)
		sim.emit(t, Event_Station_Hit{position = sim.position(pos), damage = damage, size = rock.size})
		physics.despawn(t.world.phys, &t.state.rocks, handle)
	}
}
