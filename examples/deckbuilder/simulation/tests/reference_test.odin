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
	checkpoints   = {0xee9f74afd0cce925, 0xa5263228b6620a8c, 0x86ae71c9efea9dc2, 0xe39c89c4b6d05944},
	trace         = 0x1eaa5955239ceaf6,
	snapshot      = 0xfbcf46003cb60b36,
	log           = 0x3dffe822fa35574b,
	compat        = 0x37b7b065826ed490,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME_QUICK, REFERENCE)}
