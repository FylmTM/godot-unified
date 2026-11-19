// drift's end-to-end suite: the standard scenarios of unified:headless/scenarios on the game and its arena
// (2D physics locked to a plane: ships, rocks that split, a kinematic station, ray-cast bullets, under
// rollback), and its reference run. The game's own scenarios are in drift_test.odin.
package test_drift

import "core:testing"

import g "../drift"
import ext "../extension"
import "unified:godot"
import "unified:headless/scenarios"
@(require) import "unified:physics" // the workers check (in the long tier while the game ships one worker)
@(require) import "unified:sim"

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
	checkpoints   = {0x917ffea53bc9483e, 0x803c289a77998fa5, 0x6f604193bbb1f1b4, 0x9a9d3eb01cf41a54},
	trace         = 0xe8d39a04c1333845,
	snapshot      = 0xcf0b53b7d1f6b975,
	log           = 0xe35358923a8f328c,
	compat        = 0x8ab961afcdc8b985,
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

// Box3D steps the same on any worker count (src/physics/README.md, Capacity): the reference run on the other count too
// (4, or 1 for a game that ships more; the_reference_run_reproduces runs PHYSICS_WORKERS). In every `uni test --long`,
// and in every `uni test` once the game ships more than one worker.
when scenarios.LONG || g.PHYSICS_WORKERS > 1 {
	OTHER_WORKERS :: 4 when g.PHYSICS_WORKERS == 1 else 1

	@(test)
	the_reference_run_matches_on_other_workers :: proc(t: ^testing.T) {
		game := g.GAME
		game.world_create = proc(seed: u64, levels: []sim.Level_File, setup: sim.No_Setup) -> ^g.World {
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

// The extension installs: what Godot would report when it loads it (a Data_ struct with padding, a bad Glue), here in
// a second.
@(test)
the_extension_installs :: proc(t: ^testing.T) {
	for problem in godot.install_problems(&g.GAME, ext.GLUE, ext.constants) do testing.expect(t, false, problem)
}
