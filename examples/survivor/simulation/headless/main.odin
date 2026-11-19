// The survivor's headless binary: the modes of src/headless/README.md (`-- help` lists them) on the survivor game with
// the `stress` tuning, through unified:headless/modes; `--game survivor` runs the game as played; with EOS lobbies
// (eos-host, eos-client: two processes over EOS, src/eos/README.md).
package main

import g "../survivor"
import "unified:eos"
import "unified:headless/modes"

main :: proc() {
	modes.run(
		&g.GAME_STRESS,
		benches = {{what = "survivor (stress tuning) holding 1000 enemies", entities = 1000, ticks = 600}},
		variants = {&g.GAME}, // --game survivor: the `play` tuning, as the game runs it
		// Test runs: no keychain dialog, and no device ID left behind for the next build to trip on (macOS).
		lobbies = {eos.lobby({no_keychain_prompts = true, forget_device = true})},
	)
}
