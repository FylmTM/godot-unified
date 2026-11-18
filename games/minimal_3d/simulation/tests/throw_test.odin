// minimal_3d's rule tests, each on a sync-tested run (headless.Run: every step re-simulated 8 ticks back and
// compared), the shape a game's own scenarios take.
package test_minimal_3d

import "core:testing"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:sim"

import g "../minimal_3d"

// A throw emits its event at once, at most THROW_SPEED_MAX, and the ball is gone once it lands.
@(test)
a_thrown_ball_lands_and_is_gone :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	inputs := headless.run_inputs(&run)
	sim.add_command(&inputs, 0, g.Cmd_Throw_Ball{speed = 255})
	headless.run_step(&run, &inputs)
	testing.expect_value(t, headless.run_events(&run, g.Event_Ball_Thrown), 1)
	for &raw in sim.events_at(run.simulation, run.simulation.tick) {
		thrown, is_throw := sim.event_value(&raw, g.Event).(g.Event_Ball_Thrown)
		if is_throw do testing.expect_value(t, thrown.speed, g.THROW_SPEED_MAX)
	}
	testing.expect_value(t, run.simulation.state.balls.count, 1)
	for _ in 0 ..< 2 * g.TICK_HZ {
		inputs = headless.run_inputs(&run)
		headless.run_step(&run, &inputs)
	}
	testing.expect_value(t, run.simulation.state.balls.count, 0)
	scenarios.expect_synced(t, &run)
}

// With MAX_BALLS in the air, a throw is lost and emits nothing.
@(test)
a_throw_past_the_last_ball_is_lost :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = g.PLAYERS)
	defer headless.run_end(&run)
	for _ in 0 ..= g.MAX_BALLS / (g.PLAYERS * sim.COMMANDS_PER_SLOT) {
		inputs := headless.run_inputs(&run)
		for slot in 0 ..< g.PLAYERS {
			for _ in 0 ..< sim.COMMANDS_PER_SLOT do sim.add_command(&inputs, slot, g.Cmd_Throw_Ball{speed = 4})
		}
		headless.run_step(&run, &inputs)
	}
	testing.expect_value(t, run.simulation.state.balls.count, g.MAX_BALLS)
	testing.expect_value(t, headless.run_events(&run, g.Event_Ball_Thrown), g.MAX_BALLS)
	scenarios.expect_synced(t, &run)
}
