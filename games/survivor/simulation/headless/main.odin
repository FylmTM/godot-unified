// The survivor's headless binary: the modes of src/headless/SPEC.md (`-- help` lists them) on the survivor game with
// the `stress` tuning, through unified:headless/modes; with EOS lobbies (eos-host, eos-client: two processes over
// EOS, src/eos/SPEC.md), and `bot` (bot.odin), which measures the `play` tuning.
package main

import "../survivor"
import "unified:eos"
import "unified:headless/modes"

main :: proc() {
	modes.run(
		&survivor.GAME_STRESS,
		{
			bench_prepare = survivor.bench_prepare,
			bench = {
				what     = "survivor (stress tuning) holding 1000 enemies",
				entities = 1000,
				ticks    = 600,
			},
		},
		variants = {&survivor.GAME}, // --game survivor: the `play` tuning, as the game runs it
		// Test runs: no keychain dialog, and no device ID left behind for the next build to trip on (macOS).
		lobbies = {eos.lobby({no_keychain_prompts = true, forget_device = true})},
		extra = {BOT},
	)
}
