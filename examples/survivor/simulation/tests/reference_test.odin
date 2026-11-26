// survivor's reference run (src/headless/README.md, Reference runs), on the `stress` tuning like the suite.
package test_survivor

import "core:testing"
import "unified:headless/scenarios"
@(require) import "unified:physics" // the workers check (in the long tier while the game ships one worker)
@(require) import "unified:sim"

import g "../survivor"

REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 3600,
	snapshot_tick = 1800,
	checkpoints   = {0x193aa3701c663d5c, 0x609072960fe8f21e, 0xcbfd19327fb74a46, 0xa10a7d2f15feff01},
	trace         = 0x21f579ef9ab33700,
	snapshot      = 0xcf26f5fe777f0c86,
	log           = 0xb6d912bd40bce6a6,
	compat        = 0xede28b5c7a215061,
}

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
