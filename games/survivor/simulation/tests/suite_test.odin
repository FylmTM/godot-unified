// The survivor's end-to-end suite: the standard scenarios of unified:headless/scenarios on the game
// with the `stress` tuning (what its headless binary runs), and its reference run (testdata/, made by
// `uni record-reference survivor`). The game's own scenarios follow the standard ones here and
// in the other files of this package (scenario_test.odin: explosions, deaths and resets inside
// rollback windows).
package test_survivor

import "core:testing"

import "../survivor"
import "unified:headless"
import "unified:headless/scenarios"

HEADLESS := headless.Headless(survivor.State, survivor.Input, survivor.World, survivor.PLAYERS) {
	game              = &survivor.GAME_STRESS,
	scripted_input    = survivor.scripted_input,
	scripted_commands = survivor.scripted_commands,
}

SUITE := scenarios.Suite(survivor.State, survivor.Input, survivor.World, survivor.PLAYERS) {
	game = &HEADLESS,
	players = 4,
	seed = 42,
	ticks = scenarios.LONG ? 3600 : 600,
	ref = {
		dir           = #directory + "/testdata",
		ticks         = 3600,
		snapshot_tick = 1800,
		seed          = 7,
		players       = 4,
	},
}

// By default the minimal set, each scenario proving something about this game (the toy's suite proves the
// library): rollback every tick, a bad-network session, a late joiner and the reference run, on short runs.
// `uni test --long` adds the other standard scenarios and runs them all at full length.
@(test)
rollback_every_tick :: proc(t: ^testing.T) {scenarios.rollback_every_tick(t, &SUITE)}
@(test)
four_clients_agree_on_a_bad_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 4, .Bad)}
@(test)
a_late_joiner_agrees :: proc(t: ^testing.T) {scenarios.late_join_agrees(
		t,
		&SUITE,
		.Wan,
		3,
		scenarios.LONG ? 1200 : 300,
	)}

@(test)
the_reference_run_replays :: proc(t: ^testing.T) {scenarios.reference_replays(t, &SUITE)}
@(test)
the_reference_run_resumes :: proc(t: ^testing.T) {scenarios.reference_resumes(t, &SUITE)}

when scenarios.LONG {
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
	a_bad_session_log_replays :: proc(t: ^testing.T) {scenarios.session_log_replays(t, &SUITE, 4, .Bad)}
}
