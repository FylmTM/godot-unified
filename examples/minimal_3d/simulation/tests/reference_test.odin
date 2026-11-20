// minimal_3d's reference run (src/headless/README.md, Reference runs). A new game starts from it unpinned (`uni init`
// leaves the results out): its run warns with the literal to paste until it is pinned, once the game's rules settle.
package test_minimal_3d

import "core:testing"
import "unified:headless/scenarios"

import g "../minimal_3d"

REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 1200,
	snapshot_tick = 600,
	checkpoints   = {0x0dd67e932863c420, 0xce2c95c490e0f7e2, 0xbd9943fe8ed36c51, 0x55ec1c1e97ca8a5c},
	trace         = 0xb7b8f72e7b76d55d,
	snapshot      = 0xbc7ea4d18d330936,
	log           = 0x00296055709c5de7,
	compat        = 0x2f73f4c420db0051,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
