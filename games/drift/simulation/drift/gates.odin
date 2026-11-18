package drift

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// The gates recharge; a ship whose centre comes within GATE_RADIUS of a charged gate warps to its pair, keeping its
// heading and velocity; both gates recharge, and the ship waits as long before it may warp again.
warp_ships :: proc(t: ^Tick) {
	for &gate in t.state.gates[:t.world.gate_count] {
		if gate.charge > 0 do gate.charge -= 1
	}
	ships := sim.iterate_present(t)
	for ship, player in sim.next(&ships) {
		if ship.gate_cooldown > 0 do continue
		pos := physics.body_position_2d(t.world.phys, ship.body)
		for gate_def, gate in t.world.gates[:t.world.gate_count] {
			if gate_def.pair < 0 || t.state.gates[gate].charge > 0 do continue
			if dmath.dist_sq(pos, gate_def.pos) > GATE_RADIUS * GATE_RADIUS do continue
			to := t.world.gates[gate_def.pair].pos
			heading := physics.body_rotation_2d(t.world.phys, ship.body)
			physics.body_set_transform_2d(t.world.phys, ship.body, to, heading) // its velocities are kept
			t.state.gates[gate].charge = GATE_CHARGE_TICKS
			t.state.gates[gate_def.pair].charge = GATE_CHARGE_TICKS
			ship.gate_cooldown = GATE_CHARGE_TICKS
			sim.emit(t, Event_Warped {
				position  = sim.position_2d(to),
				player    = player,
				from_gate = u8(gate),
				to_gate   = u8(gate_def.pair),
			})
			break
		}
	}
}
