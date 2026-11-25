// drift's end-to-end suite: the standard scenarios of unified:headless/scenarios (src/headless/README.md) on the game
// and its arena (2D physics locked to a plane: ships, rocks that split, a kinematic station, ray-cast bullets, under
// rollback), its replay regressions (the recorded sessions in replays/), unified's determinism lint and the
// extension's install check. The reference run is in reference_test.odin, the game's own scenarios in drift_test.odin.
package test_drift

import "core:testing"
import "unified:godot"
import "unified:headless/scenarios"
import "unified:lint"

import g "../drift"
import ext "../extension"

SUITE := scenarios.Suite(g.Game) {
	game    = &g.GAME,
	players = 4,
	seed    = 42,
	ticks   = scenarios.LONG ? 3600 : 600,
}

// By default the minimal set, each scenario proving something about this game (the toy's suite proves the
// library): rollback every tick, players leaving and coming back (presence churn), a bad-network session, a session
// whose inputs change every tick and a late joiner, on short runs.
// `uni test --long` adds the other standard scenarios and runs them all at full length.
@(test)
rollback_every_tick :: proc(t: ^testing.T) {scenarios.rollback_every_tick(t, &SUITE)}
@(test)
presence_churn :: proc(t: ^testing.T) {scenarios.presence_churn(t, &SUITE)}
@(test)
four_clients_agree_on_a_bad_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 4, .Bad)}
@(test)
four_clients_agree_when_inputs_change_every_tick :: proc(t: ^testing.T) {scenarios.session_agrees(
		t,
		&SUITE,
		4,
		.Wan,
		churn = true,
	)}
@(test)
a_late_joiner_agrees :: proc(t: ^testing.T) {scenarios.late_join_agrees(
		t,
		&SUITE,
		.Wan,
		3,
		scenarios.LONG ? 900 : 300,
	)}
// Every recorded session in replays/ (one replay folder each) computes what was blessed, tick by tick; after a meant
// rules change, `uni test drift --bless` (src/headless/README.md, Replay regressions).
@(test)
the_replays_reproduce :: proc(t: ^testing.T) {scenarios.replays_reproduce(t, &g.GAME, #directory + "/replays")}
@(test)
determinism_lint :: proc(t: ^testing.T) {lint.check_game(t, #directory + "/..")}

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
}

// The extension installs: what Godot would report when it loads it (a Data_ struct with padding, a bad Glue), here in
// a second.
@(test)
the_extension_installs :: proc(t: ^testing.T) {
	for problem in godot.install_problems(&g.GAME, ext.GLUE, ext.constants) do testing.expect(t, false, problem)
}
