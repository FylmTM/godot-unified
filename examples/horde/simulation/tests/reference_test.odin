// horde's reference run (src/headless/README.md, Reference runs). A new game starts from it unpinned (`uni init`
// leaves the results out): its run warns with the literal to paste until it is pinned, once the game's rules settle.
package test_horde

import "core:testing"
import "unified:headless/scenarios"

import g "../horde"

REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 1200,
	snapshot_tick = 600,
	checkpoints   = {0xd438f3cd2392e6c5, 0x7a8c8596457c5136, 0xa5c30073fbaf15ed, 0xd664fa8616084a68},
	trace         = 0x57c6c1a3bd9d43ca,
	snapshot      = 0xdc265049853ad33d,
	log           = 0x7662a42700d04fe9,
	compat        = 0xde29c89516d8984c,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
