// The survivor's headless binary: every mode of src/headless/SPEC.md (CLI) (sim, synctest, replay, session,
// relay, client, snapshot, resume, bench) on the survivor game with the `stress` tuning, through
// unified:headless/modes, with EOS as its online transport (online.odin: eos-host, eos-client); plus
// `bot` (bot.odin), which measures the `play` tuning.
package main

import "core:fmt"

import "../survivor"
import "unified:headless"
import "unified:headless/modes"

HEADLESS := headless.Headless(survivor.State, survivor.Input, survivor.World, survivor.MAX_PLAYERS) {
	game = &survivor.GAME_STRESS,
	script = survivor.script,
	script_commands = survivor.script_commands,
	summary = summary,
	bench_prepare = survivor.bench_prepare,
	bench_count = proc(s: ^survivor.State) -> int {return int(s.enemies.count)},
}

main :: proc() {
	bot_main()
	// --game survivor: the `play` tuning, as the game runs it
	modes.run(&HEADLESS, variants = {&survivor.GAME}, online = &EOS_ONLINE)
}

// A JSON fragment describing the state (for the CLI output; temp-allocated).
summary :: proc(s: ^survivor.State) -> string {
	levels: [survivor.MAX_PLAYERS]i32
	alive := 0
	for p in 0 ..< survivor.MAX_PLAYERS {
		levels[p] = s.players[p].level
		if s.players[p].alive {
			alive += 1
		}
	}
	return fmt.tprintf(
		`"phase":"%v","matches":%d,"wave":%d,"enemies":%d,"projectiles":%d,"gems":%d,"kills":%d,"explosions":%d,"players_alive":%d,"levels":%v`,
		s.phase,
		s.matches,
		s.wave,
		s.enemies.count,
		s.projectiles.count,
		s.gems.count,
		s.kills,
		s.explosions,
		alive,
		levels,
	)
}
