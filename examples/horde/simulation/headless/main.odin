// horde's headless binary: the modes of src/headless/README.md on the game (`-- help` lists them), through
// unified:headless/modes; with EOS lobbies (eos-host, eos-client: two processes over EOS, src/eos/README.md).
package main

import g "../horde"
import "unified:eos"
import "unified:headless/modes"

main :: proc() {
	// Test runs: no keychain dialog, and no device ID left behind for the next build to trip on (macOS).
	modes.run(&g.GAME, lobbies = {eos.lobby({no_keychain_prompts = true, forget_device = true})})
}
