// The survivor's players are session members: their progress follows the person, not the slot.
package test_survivor

import "core:testing"

import g "../survivor"
import "unified:sim"

// Progress belongs to the person, not the slot: the first player levels up and leaves (their body goes); someone new
// takes their slot with fresh progress; the first comes back in another slot with their progress and a new body at
// that slot's start spot.
@(test)
progress_follows_the_player :: proc(t: ^testing.T) {
	simulation := sim.create(&g.GAME, 3)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	inputs: g.Inputs
	sim.join(&inputs, 0, 1)
	sim.step(simulation, &inputs)
	first := sim.player_in_slot(simulation, 0)
	sim.player_data(players, first).level = 4
	sim.player_data(players, first).damage_bonus = 6

	inputs = {} // the first leaves
	sim.step(simulation, &inputs)
	inputs = {}
	sim.join(&inputs, 0, 2) // someone new takes slot 0
	sim.step(simulation, &inputs)
	testing.expect_value(t, sim.slot_data(simulation, 0).level, 1)
	testing.expect_value(t, sim.slot_data(simulation, 0).damage_bonus, 0)
	away := sim.player_data(players, first)
	testing.expect(t, away.level == 4 && away.body == {})

	inputs = {}
	inputs.present = {0}
	sim.join(&inputs, 1, 1) // the first comes back, in slot 1
	sim.step(simulation, &inputs)
	back := sim.player_data(players, first)
	testing.expect_value(t, back.level, 4)
	testing.expect_value(t, back.damage_bonus, 6)
	testing.expect(t, back.alive && back.body != {} && back.hp == g.PLAYER_HP)
	testing.expect_value(t, back.pos.x, g.PLAYER_START[1].x)
	testing.expect_value(t, back.pos.z, g.PLAYER_START[1].z)
	testing.expect_value(t, sim.slot_data(simulation, 0).level, 1)
}
