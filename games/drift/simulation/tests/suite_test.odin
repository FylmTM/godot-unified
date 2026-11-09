// drift's end-to-end suite: every standard scenario of unified:headless/scenarios on the game and its arena
// (2D physics locked to a plane: ships, rocks that split, a kinematic station, ray-cast bullets, under
// rollback), and its reference run (testdata/, made by `python tools/dev.py regen drift`). The game's own
// scenarios are in drift_test.odin.
package test_drift

import "core:testing"

import dr "../drift"
import "unified:headless"
import "unified:headless/scenarios"

ARENA :: #load("../../game/levels/arena.level")

HEADLESS := headless.Headless(dr.State, dr.Input, dr.World, dr.MAX_PLAYERS) {
	game            = &dr.GAME,
	script          = dr.script,
	script_commands = dr.script_commands,
	content         = ARENA,
}

SUITE := scenarios.Suite(dr.State, dr.Input, dr.World, dr.MAX_PLAYERS) {
	h = &HEADLESS,
	players = 4,
	seed = 42,
	ticks = 3600,
	ref = {dir = #directory + "/testdata", ticks = 1800, snapshot_tick = 900, seed = 7, players = 4},
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
a_late_joiner_agrees :: proc(t: ^testing.T) {scenarios.late_join_agrees(t, &SUITE, .Wan, 3, 900)}

@(test)
the_reference_run_replays :: proc(t: ^testing.T) {scenarios.reference_replays(t, &SUITE)}
@(test)
the_reference_run_resumes :: proc(t: ^testing.T) {scenarios.reference_resumes(t, &SUITE)}
