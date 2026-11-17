// friendslop's headless binary: every mode of src/headless/SPEC.md (sim, synctest, replay, session, relay,
// client, snapshot, resume, bench) on the game, through unified:headless/modes. The level is embedded (the
// committed export of game/levels/park.tscn); `--level FILE` loads another.
package main

import "core:fmt"

import "../friendslop"
import "unified:headless"
import "unified:headless/modes"
import "unified:sim"

PARK_LEVEL :: #load("../../game/levels/park.level")

HEADLESS := headless.Headless(friendslop.Game) {
	game = &friendslop.GAME,
	scripted_input = friendslop.scripted_input,
	summary = summary,
	bench = {
		what  = "friendslop on the park level (Box3D characters and joints), a rollback at the prediction cap every tick",
		ticks = 600,
	},
}

main :: proc() {
	HEADLESS.content = PARK_LEVEL
	modes.run(&HEADLESS)
}

// A JSON fragment describing the state (for the CLI output; temp-allocated).
summary :: proc(state: ^friendslop.State) -> string {
	return fmt.tprintf(
		`"phase":"%v","players_present":%d,"grabs":%d,"throws":%d,"hits":%d,"pad_launches":%d,"runs":%d`,
		state.phase,
		sim.present_count(&state.players),
		state.grabs,
		state.throws,
		state.hits,
		state.pad_launches,
		state.runs,
	)
}
