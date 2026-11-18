// minimal_3d's tests: the standard scenarios of unified:headless/scenarios (src/headless/SPEC.md), the set every game
// starts with, and unified's determinism lint.
package test_minimal_3d

import "core:testing"
import "unified:headless/scenarios"
import "unified:lint"

import g "../minimal_3d"

SUITE := scenarios.Suite(g.Game) {
	game = &g.GAME,
	players = g.PLAYERS,
	seed = 1,
	ticks = 600,
	ref = {
		seed          = 7,
		players       = 4,
		ticks         = 1200,
		snapshot_tick = 600,
		checkpoints   = {0x42a3951c90e38b9a, 0x99efa65f5f630340, 0x5bd1941b324d3885, 0x58892f035f607d56},
		trace         = 0x6630ceb22a81e9e0,
		snapshot      = 0x1f8270d52bc087d8,
		log           = 0xaa6e87c1d75a5b79,
	},
}

@(test)
rollback_every_tick :: proc(t: ^testing.T) {scenarios.rollback_every_tick(t, &SUITE)}
@(test)
presence_churn :: proc(t: ^testing.T) {scenarios.presence_churn(t, &SUITE)}
@(test)
two_runs_match :: proc(t: ^testing.T) {scenarios.runs_match(t, &SUITE)}
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
a_late_joiner_agrees :: proc(t: ^testing.T) {scenarios.late_join_agrees(t, &SUITE, .Wan, 3, 300)}
@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &SUITE)}
@(test)
determinism_lint :: proc(t: ^testing.T) {lint.check_game(t, #directory + "/..")}
