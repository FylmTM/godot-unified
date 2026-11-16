// drift's headless binary: every mode of src/headless/SPEC.md (sim, synctest, replay, session, relay, client,
// snapshot, resume, bench) on the game, through unified:headless/modes. The level is embedded (the committed
// export of game/levels/arena.tscn); `--level FILE` loads another.
package main

import "core:fmt"

import "../drift"
import "unified:headless"
import "unified:headless/modes"
import "unified:sim"

ARENA_LEVEL :: #load("../../game/levels/arena.level")

HEADLESS := headless.Headless(drift.State, drift.Input, drift.World, drift.Event, drift.Cmd, drift.PLAYERS) {
	game = &drift.GAME,
	scripted_input = drift.scripted_input,
	scripted_commands = drift.scripted_commands,
	summary = summary,
	bench = {
		what  = "drift on the arena (2D physics locked to a plane: ships, splitting rocks), a rollback at the prediction cap every tick",
		ticks = 1800,
	},
}

main :: proc() {
	HEADLESS.content = ARENA_LEVEL
	modes.run(&HEADLESS)
}

// A JSON fragment describing the state (for the CLI output; temp-allocated).
summary :: proc(state: ^drift.State) -> string {
	present := 0
	players := sim.iterate_present(&state.players)
	for _ in sim.next(&players) do present += 1
	return fmt.tprintf(
		`"phase":"%v","players_present":%d,"matches":%d,"waves":%d,"station_hp":%d,"score":%d,"rocks":%d`,
		state.phase,
		present,
		state.matches,
		state.waves,
		state.station_hp,
		state.score,
		state.rocks.count,
	)
}
