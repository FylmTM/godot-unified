// headless.prediction_stats (the `predict-stats` mode): the rollbacks a client would have had over a log, guessing the
// others' inputs by repeating the last one and by the game's predict_input.
package test_headless

import "core:testing"

import "../toy"
import "unified:headless"
import "unified:sim"

// A log of two players who tap Spawn for two ticks every 16, slot 1 five ticks after slot 0, both present from tick 1.
@(private = "file")
tap_log :: proc(ticks: int) -> (input_log: sim.Input_Log(toy.Game)) {
	for tick in 1 ..= ticks {
		inputs: sim.Inputs(toy.Game)
		inputs.present = {0, 1}
		for slot in 0 ..< 2 {
			if (tick + slot * 5) % 16 < 2 do inputs.input[slot].buttons = {.Spawn}
		}
		if tick == 1 do inputs.joins = {
			0 = 1,
			1 = 2,
		}
		sim.log_append(&input_log, &inputs)
	}
	return
}

// Repeating the last input mispredicts every press and every release; a hook that releases a tap on its second
// predicted tick mispredicts only the presses: half the rollbacks. With no hook both counts are the same.
@(test)
prediction_stats_scores_a_hook :: proc(t: ^testing.T) {
	input_log := tap_log(1600)
	defer sim.log_destroy(&input_log)
	game := toy.GAME
	plain := headless.prediction_stats(&game, &input_log, 7)
	testing.expect_value(t, plain.predict_input, plain.repeat_last)
	testing.expectf(
		t,
		abs(plain.repeat_last - 2 * 2 * 100) <= 4,
		"%d rollbacks repeating the last input",
		plain.repeat_last,
	)
	game.predict_input = proc(last: toy.Input, ticks_ahead: u32) -> toy.Input {
		predicted := last
		if ticks_ahead >= 2 do predicted.buttons -= {.Spawn}
		return predicted
	}
	hooked := headless.prediction_stats(&game, &input_log, 7)
	testing.expect_value(t, hooked.repeat_last, plain.repeat_last)
	testing.expectf(
		t,
		abs(2 * hooked.predict_input - hooked.repeat_last) <= 4,
		"%d rollbacks with the hook, %d without",
		hooked.predict_input,
		hooked.repeat_last,
	)
}

// Held inputs (nobody changes anything after joining) cost no rollback past the join, at any depth.
@(test)
prediction_stats_of_held_inputs :: proc(t: ^testing.T) {
	input_log: sim.Input_Log(toy.Game)
	defer sim.log_destroy(&input_log)
	for tick in 1 ..= 200 {
		inputs: sim.Inputs(toy.Game)
		inputs.present = {0, 1}
		inputs.input = {
			0 = {dx = 3},
			1 = {dy = -2},
		}
		if tick == 1 do inputs.joins = {
			0 = 1,
			1 = 2,
		}
		sim.log_append(&input_log, &inputs)
	}
	for depth in ([]u32{1, 7, 14}) {
		stats := headless.prediction_stats(&toy.GAME, &input_log, depth)
		testing.expect_value(t, stats.repeat_last, 0)
	}
}
