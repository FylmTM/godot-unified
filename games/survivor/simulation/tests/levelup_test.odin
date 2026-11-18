// Level-up picks are a command (g.Cmd_Pick): each pick takes one pending level-up, in order, and a pick with nothing
// pending is ignored. That a command reaches the sim exactly once, and never with a value that is no Upgrade, is the
// library's (tests/sim, tests/netcode).
package test_survivor

import "core:testing"

import g "../survivor"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:sim"

// One sync-tested tick in which slot 0 picks `upgrades`, in order.
pick :: proc(run: ^headless.Run(g.Game), upgrades: ..g.Upgrade) {
	inputs := headless.run_inputs(run)
	for upgrade in upgrades {
		sent := sim.add_command(&inputs, 0, g.Cmd_Pick{upgrade})
		assert(sent)
	}
	headless.run_step(run, &inputs)
}

@(test)
each_pick_takes_one_pending_level_up :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 5, seated = 1)
	defer headless.run_end(&run)
	character := sim.slot_data(run.simulation, 0)
	character.pending_levelups = 3
	headless.run_pin(&run)

	pick(&run, .Damage)
	testing.expect_value(t, character.damage_bonus, g.DAMAGE_LEVELUP)
	testing.expect_value(t, character.pending_levelups, 2)

	// Two picks in one tick take two level-ups, in order; a third with nothing left is ignored.
	speed := character.speed
	interval := character.fire_interval
	pick(&run, .Move_Speed, .Damage, .Fire_Rate)
	testing.expect_value(t, character.pending_levelups, 0)
	testing.expect_value(t, character.speed, speed + g.SPEED_LEVELUP)
	testing.expect_value(t, character.damage_bonus, 2 * g.DAMAGE_LEVELUP)
	testing.expect_value(t, character.fire_interval, interval)
	scenarios.expect_synced(t, &run)
}
