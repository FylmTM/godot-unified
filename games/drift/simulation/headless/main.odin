// drift's headless binary: every mode of src/headless/SPEC.md (sim, synctest, replay, session, relay, client,
// snapshot, resume, bench) on the game, through unified:headless/modes. The level is embedded (the committed
// export of game/levels/arena.tscn); `--level FILE` loads another.
package main

import "core:fmt"

import "../drift"
import "unified:headless"
import "unified:headless/modes"

ARENA_LEVEL :: #load("../../game/levels/arena.level")

HEADLESS := headless.Headless(drift.State, drift.Input, drift.World, drift.MAX_PLAYERS) {
	game            = &drift.GAME,
	script          = drift.script,
	script_commands = drift.script_commands,
	summary         = summary,
}

main :: proc() {
	HEADLESS.content = ARENA_LEVEL
	modes.run(&HEADLESS)
}

// A JSON fragment describing the state (for the CLI output; temp-allocated).
summary :: proc(s: ^drift.State) -> string {
	present := 0
	for sh in s.ships {
		if sh.active do present += 1
	}
	return fmt.tprintf(
		`"phase":"%v","players_present":%d,"matches":%d,"waves":%d,"station_hp":%d,"score":%d,"rocks":%d`,
		s.phase,
		present,
		s.matches,
		s.waves,
		s.station_hp,
		s.score,
		s.rocks.count,
	)
}
