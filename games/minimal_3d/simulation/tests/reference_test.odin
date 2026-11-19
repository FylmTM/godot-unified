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
	checkpoints   = {0xc04448ef566e3b89, 0x64ca9c9adb555bfc, 0xff798ee3ee62846c, 0xc70783ea69134b20},
	trace         = 0x417390c50dac143c,
	snapshot      = 0x20ea2903b8e44a71,
	log           = 0x28706904fa45b46a,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
