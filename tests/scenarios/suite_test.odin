// The toy game's end-to-end suite: every standard scenario of unified:headless/scenarios, and the
// library's own reference run (testdata/, made by `uni record-reference toy`). It is the
// template a game's suite copies (games/<game>/simulation/tests/suite_test.odin): the standard part
// is the same shape, but a game runs only its minimal set unless `scenarios.LONG`; a game adds its
// own scenarios after it.
package test_scenarios

import "core:testing"

import "../toy"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:sim"

HEADLESS := headless.Headless(toy.State, toy.Input, toy.World, toy.PLAYERS) {
	game = &toy.GAME,
	scripted_input = proc(seed: u64, player: int, tick: u32, state: ^toy.State) -> toy.Input {
		return toy.scripted_input(seed, player, tick)
	},
	scripted_commands = proc(seed: u64, player: int, tick: u32, state: ^toy.State, out: ^sim.Command_Out) {
		toy.scripted_commands(seed, player, tick, out)
	},
}

SUITE := scenarios.Suite(toy.State, toy.Input, toy.World, toy.PLAYERS) {
	game = &HEADLESS,
	players = 4,
	seed = 42,
	ticks = 3600,
	ref = {
		dir           = #directory + "/testdata",
		ticks         = 1800,
		snapshot_tick = 900,
		seed          = 7,
		players       = 4,
	},
}

@(test)
rollback_every_tick :: proc(t: ^testing.T) {scenarios.rollback_every_tick(t, &SUITE)}
@(test)
two_runs_match :: proc(t: ^testing.T) {scenarios.runs_match(t, &SUITE)}

@(test)
two_clients_agree_on_an_ideal_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 2, .Ideal)}
@(test)
two_clients_agree_on_a_wan :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 2, .Wan)}
@(test)
two_clients_agree_on_a_bad_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 2, .Bad)}
@(test)
four_clients_agree_on_an_ideal_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 4, .Ideal)}
@(test)
four_clients_agree_on_a_wan :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 4, .Wan)}
@(test)
four_clients_agree_on_a_bad_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 4, .Bad)}

@(test)
a_bad_session_log_replays :: proc(t: ^testing.T) {scenarios.session_log_replays(t, &SUITE, 4, .Bad)}
@(test)
a_late_joiner_agrees :: proc(t: ^testing.T) {scenarios.late_join_agrees(t, &SUITE, .Wan, 3, 1200)}

@(test)
the_reference_run_replays :: proc(t: ^testing.T) {scenarios.reference_replays(t, &SUITE)}
@(test)
the_reference_run_resumes :: proc(t: ^testing.T) {scenarios.reference_resumes(t, &SUITE)}
