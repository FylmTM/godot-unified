// minimal_3d's reference run (the sim-change skill): its results, pinned. `uni init` leaves this file out of a new
// game.
package test_minimal_3d

import "core:testing"
import "unified:headless/scenarios"

import g "../minimal_3d"

REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 1200,
	snapshot_tick = 600,
	checkpoints   = {0x42a3951c90e38b9a, 0x99efa65f5f630340, 0x5bd1941b324d3885, 0x58892f035f607d56},
	trace         = 0x6630ceb22a81e9e0,
	snapshot      = 0x1f8270d52bc087d8,
	log           = 0xaa6e87c1d75a5b79,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
