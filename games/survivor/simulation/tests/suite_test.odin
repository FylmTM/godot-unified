// The survivor's end-to-end suite: every standard scenario of unified:headless/scenarios on the game
// with the `stress` tuning (what its headless binary runs), and its reference run (testdata/, made by
// `python tools/dev.py regen survivor`). The game's own scenarios follow the standard ones here and
// in the other files of this package (scenario_test.odin: explosions, deaths and resets inside
// rollback windows).
package test_survivor

import "core:testing"

import "../survivor"
import "unified:headless"
import "unified:headless/scenarios"

HEADLESS := headless.Headless(survivor.State, survivor.Input, survivor.World, survivor.MAX_PLAYERS) {
	game   = &survivor.GAME_STRESS,
	script = survivor.script,
}

SUITE := scenarios.Suite(survivor.State, survivor.Input, survivor.World, survivor.MAX_PLAYERS) {
	h = &HEADLESS,
	players = 4,
	seed = 42,
	ticks = 3600,
	ref = {dir = #directory + "/testdata", ticks = 3600, snapshot_tick = 1800, seed = 7, players = 4},
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
