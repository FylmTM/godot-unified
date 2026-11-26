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
	snapshot      = 0x0ef4936a48792afd,
	log           = 0xa80db5cb7977baf4,
	compat        = 0x555f5ce4d8d4eaf7,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
