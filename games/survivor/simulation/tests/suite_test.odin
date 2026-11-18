// The survivor's end-to-end suite: the standard scenarios of unified:headless/scenarios on the game
// with the `stress` tuning (what its headless binary runs), and its reference run. The game's own scenarios follow the standard ones here and
// in the other files of this package (scenario_test.odin: explosions, deaths and resets inside
// rollback windows).
package test_survivor

import "core:testing"

import g "../survivor"
import "unified:headless/scenarios"

SUITE := scenarios.Suite(g.Game) {
	game    = &g.GAME_STRESS,
	players = 4,
	seed    = 42,
	ticks   = scenarios.LONG ? 3600 : 600,
}

// The reference run (src/headless/SPEC.md, Reference runs).
REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 3600,
	snapshot_tick = 1800,
	checkpoints   = {0x8ecc3dfed447de08, 0xb0f40a276d268744, 0x749b4de73b7274c5, 0xb25497c2ab16d77c},
	trace         = 0x6a918b583aebc4af,
	snapshot      = 0xdef62f033d43a401,
	log           = 0x159e278909cd2d0f,
}

// By default the minimal set, each scenario proving something about this game (the toy's suite proves the
// library): rollback every tick, a bad-network session, a session whose inputs change every tick, a late joiner and
// the reference run, on short runs.
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
		scenarios.LONG ? 1200 : 300,
	)}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME_STRESS, REFERENCE)}

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
