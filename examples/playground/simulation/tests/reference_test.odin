// playground's reference run (src/headless/README.md, Reference runs): four scripted players through four scenes.
package test_playground

import "core:testing"
import "unified:headless/scenarios"
@(require) import "unified:physics" // the workers check (long tier: the game ships one worker)
@(require) import "unified:sim"

import g "../playground"

REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 2000, // three scene changes (SCRIPT_SCENE_TICKS)
	snapshot_tick = 1000,
	checkpoints   = {0xbad04b9fd0d86c72, 0x87292d91f1f24cda, 0xda13a725c7b26f7f, 0x293cfb0582f922a6},
	trace         = 0x66029839dfa3627e,
	snapshot      = 0x6e5039793838174d,
	log           = 0x3c7ca787ca4d4b93,
	compat        = 0x726a7ad022d62c2e,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}

// Box3D steps to the same bits on any worker count: the reference run again on 4 (src/physics/README.md, Capacity).
when scenarios.LONG {
	@(test)
	the_reference_run_matches_on_4_workers :: proc(t: ^testing.T) {
		game := g.GAME
		game.world_create = proc(seed: u64, levels: []sim.Level_File, setup: g.Setup) -> ^g.World {
			world := g.world_create(seed, levels, setup)
			physics.world_set_worker_count(world.phys, 4)
			return world
		}
		scenarios.reference_reproduces(t, &game, REFERENCE)
	}
}
