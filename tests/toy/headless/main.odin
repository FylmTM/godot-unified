// The toy game's headless binary: every mode of src/headless/SPEC.md (CLI) on the toy, through
// unified:headless/modes. `uni test --suite net` drives it for the real-UDP, multi-process test (a
// relay and three client processes): a netcode transport test at library level.
package main

import "../../toy"
import "unified:headless"
import "unified:headless/modes"
import "unified:sim"

HEADLESS := headless.Headless(toy.State, toy.Input, toy.World, toy.PLAYERS) {
	game = &toy.GAME,
	scripted_input = proc(seed: u64, player: int, tick: u32, state: ^toy.State) -> toy.Input {
		return toy.scripted_input(seed, player, tick)
	},
	scripted_commands = proc(seed: u64, player: int, tick: u32, state: ^toy.State, out: ^sim.Command_Out) {
		toy.scripted_commands(seed, player, tick, out)
	},
}

main :: proc() {
	modes.run(&HEADLESS)
}
