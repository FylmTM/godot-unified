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
	checkpoints   = {0x917ffea53bc9483e, 0x803c289a77998fa5, 0x6f604193bbb1f1b4, 0x9a9d3eb01cf41a54},
	trace         = 0xe8d39a04c1333845,
	snapshot      = 0x6c70a80d9767a7c0,
	log           = 0xc1882f61a37df966,
	compat        = 0x46f4f75bb26f8cc3,
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
