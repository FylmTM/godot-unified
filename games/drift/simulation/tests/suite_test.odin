// drift's end-to-end suite: the standard scenarios of unified:headless/scenarios on the game and its arena
// (2D physics locked to a plane: ships, rocks that split, a kinematic station, ray-cast bullets, under
// rollback), and its reference run. The game's own scenarios are in drift_test.odin.
package test_drift

import "core:testing"

import g "../drift"
import "unified:headless/scenarios"

SUITE := scenarios.Suite(g.Game) {
	game    = &g.GAME,
	players = 4,
	seed    = 42,
	ticks   = scenarios.LONG ? 3600 : 600,
}

// The reference run (src/headless/README.md, Reference runs).
REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 1800,
	snapshot_tick = 900,
	checkpoints   = {0xb926282d047067cd, 0x1c2be4be8f8fae4e, 0x0199592bd0a51afc, 0x3dba8dad1e8f0725},
	trace         = 0x036e4f83ee05e87f,
	snapshot      = 0x621e10196994fb8f,
	log           = 0x169abe5b67fea65a,
}

// By default the minimal set, each scenario proving something about this game (the toy's suite proves the
// library): rollback every tick, players leaving and coming back (presence churn), a bad-network session, a session
// whose inputs change every tick, a late joiner and the reference run, on short runs.
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

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}

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
