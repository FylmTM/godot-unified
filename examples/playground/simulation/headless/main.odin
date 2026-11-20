// playground's headless binary: the modes of src/headless/README.md (`-- help` lists them) on the playground game,
// through unified:headless/modes; with EOS lobbies (eos-host, eos-client: two processes over EOS, src/eos/README.md).
package main

import "unified:eos"
import "unified:headless/modes"

import g "../playground"

main :: proc() {
	// No standard benchmark yet (`uni bench` runs only the game's sessions): once the game has a population worth
	// timing, give GAME its `benches = {{...}}`, with a Game.bench_prepare that builds it (src/headless/README.md).
	modes.run(
		&g.GAME,
		// Test runs: no keychain dialog, and no device ID left behind for the next build to trip on (macOS).
		lobbies = {eos.lobby({no_keychain_prompts = true, forget_device = true})},
	)
}
