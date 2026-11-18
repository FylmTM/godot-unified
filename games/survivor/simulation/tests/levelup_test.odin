// Level-up picks are a command (survivor.Cmd_Pick): delivered once, so a repeated or substituted input
// never picks again, and each pick takes one pending level-up.
package test_survivor

import "core:testing"

import "../survivor"
import "unified:sim"

pick_inputs :: proc(upgrades: ..survivor.Upgrade) -> (inputs: survivor.Inputs) {
	inputs.present = {0}
	for upgrade in upgrades {
		sim.add_command(&inputs, 0, survivor.Cmd_Pick{upgrade})
	}
	return
}

@(test)
a_pick_applies_once :: proc(t: ^testing.T) {
	simulation := sim.create(&survivor.GAME, 5)
	defer sim.destroy(simulation)
	step_with(simulation, {0}, {})
	character := sim.slot_data(simulation, 0)
	character.pending_levelups = 3

	inputs := pick_inputs(.Damage)
	sim.step(simulation, &inputs)
	testing.expect_value(t, character.damage_bonus, 3)
	testing.expect_value(t, character.pending_levelups, 2)

	// The tick's input repeated (the client filling skipped ticks, the relay substituting a late input)
	// carries no command: commands are never repeated.
	inputs.command_count = 0
	inputs.replaced = {0}
	for _ in 0 ..< 5 {
		sim.step(simulation, &inputs)
	}
	testing.expect_value(t, character.damage_bonus, 3)
	testing.expect_value(t, character.pending_levelups, 2)

	// Two picks in one tick take two level-ups, in order; a third with nothing left is ignored.
	inputs = pick_inputs(.Move_Speed, .Damage, .Fire_Rate)
	speed := character.speed
	interval := character.fire_interval
	sim.step(simulation, &inputs)
	testing.expect_value(t, character.pending_levelups, 0)
	testing.expect_value(t, character.speed, speed + survivor.SPEED_LEVELUP)
	testing.expect_value(t, character.damage_bonus, 6)
	testing.expect_value(t, character.fire_interval, interval)
}

@(test)
a_pick_that_is_not_an_option_is_ignored :: proc(t: ^testing.T) {
	simulation := sim.create(&survivor.GAME, 5)
	defer sim.destroy(simulation)
	step_with(simulation, {0}, {})
	sim.slot_data(simulation, 0).pending_levelups = 1
	inputs := pick_inputs(.Damage)
	inputs.commands[0].data[0] = 7 // not an Upgrade (bytes from the network)
	sim.step(simulation, &inputs)
	testing.expect_value(t, sim.slot_data(simulation, 0).pending_levelups, 1)
}
