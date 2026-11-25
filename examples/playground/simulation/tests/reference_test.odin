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
	checkpoints   = {0xdc31974faa5a5419, 0xe401c1b4d6f83e3e, 0x64750dcb1f2ded75, 0xb4a2326da61743be},
	trace         = 0x7ae62dfa057aaa93,
	snapshot      = 0x45e5d5a373064b0b,
	log           = 0xa02b54627f284888,
	compat        = 0x7f8e99c0b4ae71ef,
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
