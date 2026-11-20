// holdout's reference run (src/headless/README.md, Reference runs): four scripted players through the lobby and into
// the first wave; every platform must reproduce it bit for bit. After a meant rules change, `uni test holdout --bless`.
package test_holdout

import "core:testing"
import "unified:headless/scenarios"

import g "../holdout"

REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 1200,
	snapshot_tick = 600,
	checkpoints   = {0xbea4ff90554be84b, 0xfc1ed8835d0057a9, 0x7db16348c42bb59c, 0xaeafb90e8c6e31a9},
	trace         = 0x93d6db0b713bb104,
	snapshot      = 0x70af25024ecffcab,
	log           = 0x18acc8bc1cc78d0d,
	compat        = 0x1c043c2ec9b78ec3,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
