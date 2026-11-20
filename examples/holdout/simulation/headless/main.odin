// holdout's headless binary: the modes of src/headless/README.md (`-- help` lists them) on the holdout game, through
// unified:headless/modes; its standard benchmark (Game.benches) holds the last wave at ENEMY_CAP enemies; with EOS
// lobbies (eos-host, eos-client: two processes over EOS, src/eos/README.md).
package main

import "unified:eos"
import "unified:headless/modes"

import g "../holdout"

main :: proc() {
	modes.run(
		&g.GAME,
		// Test runs: no keychain dialog, and no device ID left behind for the next build to trip on (macOS).
		lobbies = {eos.lobby({no_keychain_prompts = true, forget_device = true})},
	)
}
