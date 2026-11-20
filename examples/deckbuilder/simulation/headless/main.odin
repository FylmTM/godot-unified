// deckbuilder's headless binary: the modes of src/headless/README.md (`-- help` lists them) on the game with the
// `quick` tuning, which the scripted player crosses the act in; `--game deckbuilder` runs the game as played; with EOS
// lobbies (eos-host, eos-client: two processes over EOS, src/eos/README.md).
package main

import "unified:eos"
import "unified:headless/modes"

import g "../deckbuilder"

main :: proc() {
	modes.run(
		&g.GAME_QUICK,
		variants = {&g.GAME}, // --game deckbuilder: the `play` tuning, as the game runs it
		// Test runs: no keychain dialog, and no device ID left behind for the next build to trip on (macOS).
		lobbies = {eos.lobby({no_keychain_prompts = true, forget_device = true})},
	)
}
