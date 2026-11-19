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
