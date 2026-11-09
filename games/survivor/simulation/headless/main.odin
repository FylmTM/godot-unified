// The survivor's headless binary: every mode of spec/headless.md (CLI) (sim, synctest, replay, session,
// relay, client, snapshot, resume, bench) on the survivor game with the `stress` tuning, through
// unified:headless; plus `bot` (bot.odin), which measures the `play` tuning.
package main

import "../survivor"
import "unified:headless"

HEADLESS := headless.Headless(survivor.State, survivor.Input, survivor.World, survivor.MAX_PLAYERS) {
	game = &survivor.GAME_STRESS,
	variants = {&survivor.GAME}, // --game survivor: the `play` tuning, as the game runs it
	script = survivor.script,
	summary = survivor.summary,
	bench_prepare = survivor.bench_prepare,
	bench_count = proc(s: ^survivor.State) -> int {return int(s.enemies.count)},
}

main :: proc() {
	bot_main()
	headless.run(&HEADLESS)
}
