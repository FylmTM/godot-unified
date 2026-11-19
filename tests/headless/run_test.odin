// The stepped Run (src/headless/README.md, Runs): what a game's tests start from.
package test_headless

import "core:testing"

import "../toy"
import "unified:headless"
import "unified:sim"

// run_begin(seated = N): slots 0 ..< N hold members 1 .. N, present from tick 1 after one step of zero inputs; the
// next steps keep them seated.
@(test)
run_begin_seats_and_steps_once :: proc(t: ^testing.T) {
	run := headless.run_begin(&toy.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	testing.expect_value(t, run.simulation.tick, 1)
	testing.expect_value(t, sim.present_count(run.simulation), 2)
	testing.expect_value(t, sim.player_in_slot(run.simulation, 0).id, 1)
	testing.expect_value(t, sim.player_in_slot(run.simulation, 1).id, 2)
	testing.expect_value(t, sim.player_in_slot(run.simulation, 2), sim.Player{})
	inputs := headless.run_inputs(&run)
	headless.run_step(&run, &inputs)
	testing.expect_value(t, sim.present_count(run.simulation), 2)
	testing.expect_value(t, run.mismatches, 0)
	nobody := headless.run_begin(&toy.GAME, 1)
	defer headless.run_end(&nobody)
	testing.expect_value(t, nobody.simulation.tick, 0)
}

// Tick code that writes state only while draws are kept ("skip the work a draw needs" gone wrong) fails the standard
// sync-test: it re-simulates with every draw group on after forward ticks with none.
Peek_State :: struct {
	drawn:   u32, // ticks computed while draws were kept: a dev-dependent value in the block
	players: sim.Players(u32, sim.No_Profile, toy.Input, 1),
}

Peek_Game :: sim.Game(Peek_State, toy.Input, sim.No_World, toy.Event, sim.No_Commands, sim.No_Setup, sim.No_Profile, 1)

PEEK := Peek_Game {
	name = "peek",
	version = "1",
	tick_hz = 64,
	tick = proc(t: ^sim.Tick(Peek_Game)) {
		if sim.drawing(t) do t.state.drawn += 1
	},
}

@(test)
the_sync_test_catches_state_written_while_drawing :: proc(t: ^testing.T) {
	result := headless.run_synctest(&PEEK, 64, 8, 3, 1)
	testing.expectf(t, result.mismatches > 0, "%d mismatches", result.mismatches)
}
