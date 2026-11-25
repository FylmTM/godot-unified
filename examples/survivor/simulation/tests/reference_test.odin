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
	checkpoints   = {0xdbb7441146c5206c, 0xe801faf84aa85a5f, 0x9698d942b73f4c0a, 0x99d4caffb727790d},
	trace         = 0x80c460ce5f1b391c,
	snapshot      = 0x5d760ee21e82e052,
	log           = 0x7470600c68dffda1,
	compat        = 0xef7aa2edcb00909b,
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
