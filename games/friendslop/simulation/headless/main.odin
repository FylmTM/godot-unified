// friendslop's headless binary: every mode of src/headless/SPEC.md (sim, synctest, replay, session, relay,
// client, snapshot, resume, bench) on the game, through unified:headless/modes. The level is embedded (the
// committed export of game/levels/park.tscn); `--level FILE` loads another.
package main

import "core:fmt"

import "../friendslop"
import "unified:headless"
import "unified:headless/modes"

PARK_LEVEL :: #load("../../game/levels/park.level")

HEADLESS := headless.Headless(friendslop.State, friendslop.Input, friendslop.World, friendslop.MAX_PLAYERS) {
	game    = &friendslop.GAME,
	script  = friendslop.script,
	summary = summary,
}

main :: proc() {
	HEADLESS.content = PARK_LEVEL
	modes.run(&HEADLESS)
}

// A JSON fragment describing the state (for the CLI output; temp-allocated).
summary :: proc(s: ^friendslop.State) -> string {
	present := 0
	for p in s.players {
		if p.active do present += 1
	}
	return fmt.tprintf(
		`"phase":"%v","players_present":%d,"grabs":%d,"throws":%d,"hits":%d,"pad_launches":%d,"runs":%d`,
		s.phase,
		present,
		s.grabs,
		s.throws,
		s.hits,
		s.pad_launches,
		s.runs,
	)
}
