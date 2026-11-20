// deckbuilder's reference run (src/headless/README.md, Reference runs), on the quick tuning.
package test_deckbuilder

import "core:testing"
import "unified:headless/scenarios"

import g "../deckbuilder"

REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 3600,
	snapshot_tick = 1800,
	checkpoints   = {0x602d792f023c55d6, 0x80d3adbdf7ebb08d, 0x962b3e80369b7bd0, 0xc4d1e781f87ae074},
	trace         = 0x46de1ed5c5c3a588,
	snapshot      = 0x078881a9cbd810f5,
	log           = 0x0671996ca4df92f1,
	compat        = 0x7d8b2d5f2b1a6bf9,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME_QUICK, REFERENCE)}
