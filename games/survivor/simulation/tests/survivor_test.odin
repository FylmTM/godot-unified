// The survivor's players are session members: their progress follows the person, not the slot.
package test_survivor

import "core:testing"

import g "../survivor"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:sim"

// Progress belongs to the person, not the slot: the first player levels up and leaves (their body goes); someone new
// takes their slot with fresh progress; the first comes back in another slot with their progress and a new body at
// that slot's start spot.
@(test)
progress_follows_the_player :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 3, seated = 1) // member 1 in slot 0
	defer headless.run_end(&run)
	simulation := run.simulation
	players := &simulation.state.players
	first := sim.player_in_slot(simulation, 0)
	sim.player_data(players, first).level = 4
	sim.player_data(players, first).damage_bonus = 6
	headless.run_pin(&run)

	headless.run_seat(&run, 0, 0) // the first leaves
	step(&run)
	headless.run_seat(&run, 0, 2) // someone new takes slot 0
	step(&run)
	testing.expect_value(t, sim.slot_data(simulation, 0).level, 1)
	testing.expect_value(t, sim.slot_data(simulation, 0).damage_bonus, 0)
	away := sim.player_data(players, first)
	testing.expect(t, away.level == 4 && away.body == {})

	headless.run_seat(&run, 1, 1) // the first comes back, in slot 1
	step(&run)
	back := sim.player_data(players, first)
	testing.expect_value(t, back.level, 4)
	testing.expect_value(t, back.damage_bonus, 6)
	testing.expect(t, back.alive && back.body != {} && back.hp == g.PLAYER_HP)
	testing.expect_value(t, back.pos.x, simulation.world.spawns[1].x)
	testing.expect_value(t, back.pos.z, simulation.world.spawns[1].z)
	testing.expect_value(t, sim.slot_data(simulation, 0).level, 1)
	scenarios.expect_synced(t, &run)
}
