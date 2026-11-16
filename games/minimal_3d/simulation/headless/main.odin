package main

import "unified:headless"
import "unified:headless/modes"

import g "../minimal_3d"

HEADLESS := headless.Headless(g.State, g.Input, g.World, g.Event, g.Cmd, g.PLAYERS) {
	game = &g.GAME,
	scripted_input = proc(seed: u64, slot: int, tick: u32, state: ^g.State) -> g.Input {
		return g.scripted_input(seed, slot, tick)
	},
	scripted_commands = g.scripted_commands,
	bench = {what = "minimal_3d with 4 players, a rollback at the prediction cap every tick", ticks = 600},
}

main :: proc() {
	modes.run(&HEADLESS)
}
