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
	checkpoints   = {0x8130817e3fa6c53e, 0xe713ff707457920f, 0xf0414c189e06d158, 0xd2339a0ed6fb31de},
	trace         = 0x4f89dc92cf1f4a17,
	snapshot      = 0xae8e5693fdbc59c0,
	log           = 0x885b85911ff53839,
	compat        = 0x530bee2789605b61,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
