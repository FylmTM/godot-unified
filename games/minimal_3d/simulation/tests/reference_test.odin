// minimal_3d's reference run (the sim-change skill): its results, pinned. `uni init` leaves this file out of a new
// game, which pins its own once its rules settle (suite_test.odin's header says how).
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
	snapshot      = 0xde55f3ab518d5aab,
	log           = 0x2d377183e451966c,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
