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
	snapshot      = 0x019bf0cc45447b65,
	log           = 0xedd5f824674b9d8e,
	compat        = 0xc419be2bd0526e23,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME_QUICK, REFERENCE)}
