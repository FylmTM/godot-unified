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
	checkpoints   = {0x707ca73b4f52cc45, 0x18917e90cdf81c67, 0xf507bd0b337b80d5, 0xe2a276ebdab772fd},
	trace         = 0xdd8d472f426797e4,
	snapshot      = 0x1924273a74183f0b,
	log           = 0x242b0b237cfa5547,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
