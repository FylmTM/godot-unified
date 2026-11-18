// minimal_3d's tests: the standard scenarios of unified:headless/scenarios (src/headless/SPEC.md), the set every game
// starts with, and unified's determinism lint. Its pinned reference run is in reference_test.odin, which `uni init`
// leaves out of a new game: it pins its own once its rules settle (a `REFERENCE :: scenarios.Reference` with seed,
// players, ticks and snapshot_tick, and a test calling reference_reproduces; the first run prints the rest to paste).
package test_minimal_3d

import "core:testing"
import "unified:headless/scenarios"
import "unified:lint"

import g "../minimal_3d"

SUITE := scenarios.Suite(g.Game) {
	game    = &g.GAME,
	players = g.PLAYERS,
	seed    = 1,
	ticks   = 600,
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
determinism_lint :: proc(t: ^testing.T) {lint.check_game(t, #directory + "/..")}
