// drift's reference run (src/headless/README.md, Reference runs).
package test_drift

import "core:testing"
import "unified:headless/scenarios"
@(require) import "unified:physics" // the workers check (in the long tier while the game ships one worker)
@(require) import "unified:sim"

import g "../drift"

REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 1800,
	snapshot_tick = 900,
	checkpoints   = {0xe5dbccdaf5e8a990, 0x206b64de2d1073cc, 0x42564ff674adc2eb, 0xe384f8efd1626acb},
	trace         = 0x3d295b2c1a76890d,
	snapshot      = 0x2b6aa2a0b356846d,
	log           = 0x7b458bff5e2cf192,
	compat        = 0x0c48dc69c9b8110e,
}

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
