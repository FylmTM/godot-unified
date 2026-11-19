// minimal_3d's rule tests, each on a sync-tested run (headless.Run: every step re-simulated 8 ticks back and
// compared), the shape a game's own scenarios take.
package test_minimal_3d

import "core:testing"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:netcode"
import "unified:sim"

import g "../minimal_3d"

// Steps the run once with `slot`'s commands (none: a plain step).
step_with :: proc(run: ^headless.Run(g.Game), slot: int, commands: ..g.Cmd) {
	inputs := headless.run_inputs(run)
	for command in commands do sim.add_command(&inputs, slot, command)
	headless.run_step(run, &inputs)
}

// A throw emits its event at once, at most THROW_SPEED_MAX, and the ball is gone once it lands.
@(test)
a_thrown_ball_lands_and_is_gone :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	step_with(&run, 0, g.Cmd_Throw_Ball{speed = 255})
	testing.expect_value(t, headless.run_events(&run, g.Event_Ball_Thrown), 1)
	for &raw in sim.events_at(run.simulation, run.simulation.tick) {
		thrown, is_throw := sim.event_value(&raw, g.Event).(g.Event_Ball_Thrown)
		if is_throw do testing.expect_value(t, thrown.speed, g.THROW_SPEED_MAX)
	}
	testing.expect_value(t, run.simulation.state.balls.count, 1)
	for _ in 0 ..< 2 * g.TICK_HZ do step_with(&run, 0)
	testing.expect_value(t, run.simulation.state.balls.count, 0)
	scenarios.expect_synced(t, &run)
}

// A throw inside THROW_COOLDOWN_S of the last one is dropped; one after it throws.
@(test)
a_throw_waits_out_the_cooldown :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	step_with(&run, 0, g.Cmd_Throw_Ball{speed = 4}, g.Cmd_Throw_Ball{speed = 4}) // the second in the same tick: dropped
	step_with(&run, 0, g.Cmd_Throw_Ball{speed = 4}) // a tick later: dropped
	testing.expect_value(t, run.simulation.state.balls.count, 1)
	for _ in 0 ..< sim.ticks(g.THROW_COOLDOWN_S, g.TICK_HZ) do step_with(&run, 0)
	step_with(&run, 0, g.Cmd_Throw_Ball{speed = 4})
	testing.expect_value(t, run.simulation.state.balls.count, 2)
	scenarios.expect_synced(t, &run)
}

// The co-op pause: from the tick after anyone's Cmd_Set_Paused, nothing moves (players, balls), a throw sent while
// paused is dropped, game time stands still, and a cooldown started before it is still running after it, by exactly
// the pause; a resume takes it back. Each change is announced once.
@(test)
a_co_op_pause_stops_the_game :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	step_with(&run, 0, g.Cmd_Throw_Ball{speed = 8})
	step_with(&run, 1, g.Cmd_Set_Paused{true}, g.Cmd_Set_Paused{true}) // twice: one change, one event
	testing.expect_value(t, headless.run_events(&run, g.Event_Paused), 1)
	state := &run.simulation.state
	time := state.clock.time
	ball := state.balls.items[0]
	moved := sim.slot_data(run.simulation, 0).position
	for _ in 0 ..< 30 {
		inputs := headless.run_inputs(&run)
		inputs.input[0] = {
			dx = 127,
		}
		sim.add_command(&inputs, 0, g.Cmd_Throw_Ball{speed = 4})
		headless.run_step(&run, &inputs)
	}
	testing.expect_value(t, state.clock.time, time)
	testing.expect_value(t, state.balls.count, 1) // the throws sent while paused are gone
	testing.expect_value(t, state.balls.items[0], ball)
	testing.expect_value(t, sim.slot_data(run.simulation, 0).position, moved)
	data := sim.slot_data(run.simulation, 0)
	testing.expect(t, sim.timer_running(state.clock.time, data.throw_ready), "the cooldown waits out the pause")
	step_with(&run, 0, g.Cmd_Set_Paused{false})
	step_with(&run, 0)
	testing.expect_value(t, state.clock.time, time + 1)
	testing.expect_value(t, headless.run_events(&run, g.Event_Paused), 2) // so far: the pause and the resume
	scenarios.expect_synced(t, &run)
}

// A co-op pause in a 2-client session on the virtual clock under a bad network (the script's slot 0 pauses for
// SCRIPT_PAUSE_TICKS): no desync, and the relay's log replayed shows game time standing still for exactly that long.
@(test)
a_co_op_pause_holds_in_a_session :: proc(t: ^testing.T) {
	result := headless.session_run(&g.GAME, {clients = 2, profile = netcode.PROFILES[.Bad], ticks = 600, seed = 42})
	defer headless.session_result_destroy(&result)
	testing.expectf(t, result.ok && result.desyncs == 0, "%d desyncs", result.desyncs)
	replay := sim.create(&g.GAME, 42)
	defer sim.destroy(replay)
	held, last := 0, u32(0)
	for k in 0 ..< len(result.log.ticks) {
		inputs := sim.log_inputs(&result.log, k)
		sim.step(replay, &inputs)
		held += int(replay.state.clock.time == last)
		last = replay.state.clock.time
	}
	testing.expect_value(t, held, g.SCRIPT_PAUSE_TICKS)
	testing.expect_value(t, replay.state.clock.time, replay.tick - g.SCRIPT_PAUSE_TICKS)
}
