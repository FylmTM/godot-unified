// Level-up picks are edge-triggered by their press sequence: an input repeated by the netcode (the
// client filling skipped ticks, the relay substituting a late input with the last one) applies once.
package test_survivor

import "core:testing"

import "../survivor"
import "unified:sim"

@(test)
repeated_and_substituted_choice_applies_once :: proc(t: ^testing.T) {
	s := sim.create(&survivor.GAME, 5)
	defer sim.destroy(s)
	step_with(s, {0}, {})
	s.state.players[0].pending_levelups = 3
	pl := &s.state.players[0]

	pick := survivor.Input {
		choice = survivor.choice_encode(2, 7), // damage +3, press 7
	}
	in_: survivor.Inputs
	in_.present = {0}
	in_.input[0] = pick
	sim.step(s, &in_)
	testing.expect_value(t, pl.damage_bonus, 3)
	testing.expect_value(t, pl.pending_levelups, 2)

	// The same input again: as the client repeats it after a delay change or catch-up...
	sim.step(s, &in_)
	// ...and as the relay substitutes it (flagged replaced) for ticks whose input came too late.
	in_.replaced = {0}
	for _ in 0 ..< 5 {
		sim.step(s, &in_)
	}
	testing.expect_value(t, pl.damage_bonus, 3)
	testing.expect_value(t, pl.pending_levelups, 2)

	// A new press (next sequence) applies, even with the same option.
	in_.replaced = {}
	in_.input[0].choice = survivor.choice_encode(2, survivor.choice_next_seq(7))
	sim.step(s, &in_)
	testing.expect_value(t, pl.damage_bonus, 6)
	testing.expect_value(t, pl.pending_levelups, 1)

	// No option, or sequence 0, is no pick.
	in_.input[0].choice = survivor.choice_encode(0, 9)
	sim.step(s, &in_)
	in_.input[0].choice = survivor.choice_encode(3, 0)
	sim.step(s, &in_)
	testing.expect_value(t, pl.pending_levelups, 1)
}

@(test)
choice_encoding :: proc(t: ^testing.T) {
	for seq in u8(1) ..= 63 {
		for opt in 1 ..= 3 {
			c := survivor.choice_encode(opt, seq)
			testing.expect_value(t, survivor.choice_option(c), opt)
			testing.expect_value(t, survivor.choice_seq(c), seq)
		}
	}
	testing.expect_value(t, survivor.choice_next_seq(63), 1)
	testing.expect_value(t, survivor.choice_next_seq(0), 1)
	testing.expect_value(t, survivor.choice_next_seq(1), 2)
}
