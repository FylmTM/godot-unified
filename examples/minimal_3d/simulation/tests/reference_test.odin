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
	checkpoints   = {0x9a47b7035c52c84d, 0xbd63adcbae8d5ed8, 0x7b716222eedda388, 0xd0439e5299dffee5},
	trace         = 0xa3591734855e241b,
	snapshot      = 0x07b5669bcc88dd51,
	log           = 0x82c9e223ef5c1d45,
	compat        = 0x1e6eab6f5d281907,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
