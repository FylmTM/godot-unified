// friendslop's reference run (src/headless/README.md, Reference runs).
package test_friendslop

import "core:testing"
import "unified:headless/scenarios"
@(require) import "unified:physics" // the workers check (in the long tier while the game ships one worker)
@(require) import "unified:sim"

import g "../friendslop"

REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 1800,
	snapshot_tick = 900,
	checkpoints   = {0xa8d58e3ed5fc5495, 0x7069dfe607b701bd, 0x5f92c49def72fc7d, 0x8b6e1565d4d2f280},
	trace         = 0x5e9e0056addb0da1,
	snapshot      = 0x5c988bfb78c7ad0b,
	log           = 0xd5f701536ec8df32,
	compat        = 0x826f4fb6641d0f86,
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
