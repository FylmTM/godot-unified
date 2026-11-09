// Level-up picks are a command (survivor.Cmd_Pick): delivered once, so a repeated or substituted input
// never picks again, and each pick takes one pending level-up.
package test_survivor

import "core:testing"

import "../survivor"
import "unified:sim"

pick_inputs :: proc(upgrades: ..survivor.Upgrade) -> (in_: survivor.Inputs) {
	in_.present = {0}
	for u in upgrades {
		c, ok := sim.command_make(survivor.GAME.commands, survivor.Cmd_Pick{u})
		assert(ok)
		sim.add_command(&in_, c)
	}
	return
}

@(test)
a_pick_applies_once :: proc(t: ^testing.T) {
	s := sim.create(&survivor.GAME, 5)
	defer sim.destroy(s)
	step_with(s, {0}, {})
	s.state.players[0].pending_levelups = 3
	pl := &s.state.players[0]

	in_ := pick_inputs(.Damage)
	sim.step(s, &in_)
	testing.expect_value(t, pl.damage_bonus, 3)
	testing.expect_value(t, pl.pending_levelups, 2)

	// The tick's input repeated (the client filling skipped ticks, the relay substituting a late input)
	// carries no command: commands are never repeated.
	in_.n_commands = 0
	in_.replaced = {0}
	for _ in 0 ..< 5 {
		sim.step(s, &in_)
	}
	testing.expect_value(t, pl.damage_bonus, 3)
	testing.expect_value(t, pl.pending_levelups, 2)

	// Two picks in one tick take two level-ups, in order; a third with nothing left is ignored.
	in_ = pick_inputs(.Move_Speed, .Damage, .Fire_Rate)
	speed := pl.speed
	interval := pl.fire_interval
	sim.step(s, &in_)
	testing.expect_value(t, pl.pending_levelups, 0)
	testing.expect_value(t, pl.speed, speed + survivor.SPEED_LEVELUP)
	testing.expect_value(t, pl.damage_bonus, 6)
	testing.expect_value(t, pl.fire_interval, interval)
}

@(test)
a_pick_that_is_not_an_option_is_ignored :: proc(t: ^testing.T) {
	s := sim.create(&survivor.GAME, 5)
	defer sim.destroy(s)
	step_with(s, {0}, {})
	s.state.players[0].pending_levelups = 1
	in_ := pick_inputs(.Damage)
	in_.commands[0].data[0] = 7 // not an Upgrade (bytes from the network)
	sim.step(s, &in_)
	testing.expect_value(t, s.state.players[0].pending_levelups, 1)
}
