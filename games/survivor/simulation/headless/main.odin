// The survivor's headless binary: every mode of spec/CORE.md §3 (sim, synctest, replay, session,
// relay, client, snapshot, resume, bench) on the survivor game, through unified:headless.
package main

import "../survivor"
import "unified:headless"

HEADLESS := headless.Headless(survivor.State, survivor.Input, survivor.World, survivor.MAX_PLAYERS) {
	game = &survivor.GAME,
	script = survivor.script,
	summary = survivor.summary,
	bench_prepare = survivor.bench_prepare,
	bench_count = proc(s: ^survivor.State) -> int {return int(s.enemies.count)},
}

main :: proc() {
	headless.run(&HEADLESS)
}
