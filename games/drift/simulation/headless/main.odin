// drift's headless binary: every mode of src/headless/SPEC.md (sim, synctest, replay, session, relay, client,
// snapshot, resume, bench) on the game, through unified:headless/modes. The level is embedded (the committed
// export of game/levels/arena.tscn); `--level FILE` loads another.
package main

import "core:fmt"

import "../drift"
import "unified:headless/modes"
import "unified:sim"

main :: proc() {
	modes.run(&drift.GAME, {
		content = #load("../../game/levels/arena.level"),
		summary = summary,
		bench = {
			what  = "drift on the arena (2D physics locked to a plane: ships, splitting rocks)",
			ticks = 1800,
		},
	})
}

// A JSON fragment describing the state (for the CLI output; temp-allocated).
summary :: proc(state: ^drift.State) -> string {
	return fmt.tprintf(
		`"phase":"%v","players_present":%d,"matches":%d,"waves":%d,"station_hp":%d,"score":%d,"rocks":%d`,
		state.phase,
		sim.present_count(&state.players),
		state.matches,
		state.waves,
		state.station_hp,
		state.score,
		state.rocks.count,
	)
}
