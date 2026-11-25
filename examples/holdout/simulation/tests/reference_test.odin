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
	checkpoints   = {0x823aba4a7f6b4aac, 0x1a281d48d2542b34, 0x2822264fb6427d18, 0xb192608190c0da5d},
	trace         = 0x5219f09a3c1039e5,
	snapshot      = 0x09f0ce547d26ade0,
	log           = 0xc985d5298c36dee1,
	compat        = 0xccf0bec450ae2f89,
}

@(test)
the_reference_run_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(t, &g.GAME, REFERENCE)}
