package test_scenarios

import "core:testing"

import "../toy"
import "unified:headless"
import "unified:netcode"
import "unified:sim"

// A co-op pause in a 2-client session on the virtual clock under a bad network: the toy's slot 0 pauses for 40 ticks
// (its Command_Pause, state set by a command, every peer at the same tick). No desync, and the relay's log replayed shows
// game time standing still for exactly those 40 ticks, then moving on.
@(test)
a_co_op_pause_holds_in_a_session :: proc(t: ^testing.T) {
	result := headless.session_run(&toy.GAME, {clients = 2, profile = netcode.PROFILES[.Bad], ticks = 600, seed = 42})
	defer headless.session_result_destroy(&result)
	testing.expectf(t, result.ok && result.desyncs == 0, "%d desyncs", result.desyncs)
	replay := sim.create(&toy.GAME, 42)
	defer sim.destroy(replay)
	held, last := 0, sim.Game_Time(0)
	for k in 0 ..< len(result.log.ticks) {
		inputs := sim.log_inputs(&result.log, k)
		sim.step(replay, &inputs)
		held += int(replay.state.clock.time == last)
		last = replay.state.clock.time
	}
	testing.expect_value(t, replay.tick, 600)
	testing.expect_value(t, held, 40)
	testing.expect_value(t, replay.state.clock.time, 560)
	testing.expect(t, !replay.state.clock.paused)
}
