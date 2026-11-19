// The survivor's end-to-end suite: the standard scenarios of unified:headless/scenarios on the game with the `stress`
// tuning (what its headless binary runs), and its reference run. The game's own scenarios are in the other files of
// this package (scenario_test.odin: explosions, deaths and resets inside rollback windows).
package test_survivor

import "core:testing"

import g "../survivor"
import "unified:headless/scenarios"
@(require) import "unified:physics" // the workers check (in the long tier while the game ships one worker)
@(require) import "unified:sim"

SUITE := scenarios.Suite(g.Game) {
	game    = &g.GAME_STRESS,
	players = 4,
	seed    = 42,
	ticks   = scenarios.LONG ? 3600 : 600,
}

// The reference run (src/headless/README.md, Reference runs).
REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 3600,
	snapshot_tick = 1800,
	checkpoints   = {0xf413e427ccd51fd3, 0x9ae2442d9848f6d2, 0x38b3a4ca5f8b82fa, 0x355d415e7f966bf7},
	trace         = 0x0ad37fcc88bfa32c,
	snapshot      = 0x2797f92a43128f17,
	log           = 0x4fb0f3aedf07b0e5,
}

// By default the minimal set, each scenario proving something about this game (the toy's suite proves the
// library): rollback every tick, players coming and going (presence churn), a bad-network session, a session whose
// inputs change every tick, a late joiner and the reference run, on short runs.
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

// Box3D steps the same on any worker count (src/physics/README.md, Capacity): the reference run on the other count too
// (4, or 1 for a game that ships more; the_reference_run_reproduces runs PHYSICS_WORKERS). In every `uni test --long`,
// and in every `uni test` once the game ships more than one worker.
when scenarios.LONG || g.PHYSICS_WORKERS > 1 {
	OTHER_WORKERS :: 4 when g.PHYSICS_WORKERS == 1 else 1

	@(test)
	the_reference_run_matches_on_other_workers :: proc(t: ^testing.T) {
		game := g.GAME_STRESS
		game.world_create = proc(seed: u64, levels: []sim.Level_File, setup: g.Setup) -> ^g.World {
			world := g.world_create(seed, levels, setup)
			physics.world_set_worker_count(world.phys, OTHER_WORKERS)
			return world
		}
		scenarios.reference_reproduces(t, &game, REFERENCE)
	}
}

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
