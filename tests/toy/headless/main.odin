// The toy game's headless binary: every mode of src/headless/SPEC.md (CLI) on the toy, through
// unified:headless/cli. `python tools/dev.py check` drives it for the real-UDP, multi-process test (a
// relay and three client processes): a netcode transport test at library level.
package main

import "../../toy"
import "unified:headless"
import "unified:headless/cli"

HEADLESS := headless.Headless(toy.State, toy.Input, toy.World, toy.SLOTS) {
	game = &toy.GAME,
	script = proc(seed: u64, slot: int, t: u32, state: ^toy.State) -> toy.Input {
		return toy.script(seed, slot, t)
	},
}

main :: proc() {
	cli.run(&HEADLESS)
}
