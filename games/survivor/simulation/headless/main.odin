// The survivor's headless binary: every mode of src/headless/SPEC.md (CLI) (sim, synctest, replay, session,
// relay, client, snapshot, resume, bench) on the survivor game with the `stress` tuning, through
// unified:headless/modes, with EOS as its online transport (online.odin: eos-host, eos-client); plus
// `bot` (bot.odin), which measures the `play` tuning.
package main

import "core:fmt"

import "../survivor"
import "unified:headless"
import "unified:headless/modes"

HEADLESS := headless.Headless(survivor.State, survivor.Input, survivor.World, survivor.PLAYERS) {
	game = &survivor.GAME_STRESS,
	scripted_input = survivor.scripted_input,
	scripted_commands = survivor.scripted_commands,
	summary = summary,
	bench_prepare = survivor.bench_prepare,
	bench_count = proc(state: ^survivor.State) -> int {return int(state.enemies.count)},
	bench = {
		what     = "survivor (stress tuning) holding 1000 enemies, a rollback at the prediction cap every tick",
		entities = 1000,
		ticks    = 600,
	},
}

main :: proc() {
	bot_main()
	// --game survivor: the `play` tuning, as the game runs it
	modes.run(&HEADLESS, variants = {&survivor.GAME}, online = &EOS_ONLINE)
}

// A JSON fragment describing the state (for the CLI output; temp-allocated).
summary :: proc(state: ^survivor.State) -> string {
	levels: [survivor.PLAYERS]i32
	alive := 0
	for &character, player in state.players {
		levels[player] = character.level
		alive += int(character.alive)
	}
	return fmt.tprintf(
		`"phase":"%v","matches":%d,"wave":%d,"enemies":%d,"projectiles":%d,"gems":%d,"kills":%d,"explosions":%d,"players_alive":%d,"levels":%v`,
		state.phase,
		state.matches,
		state.wave,
		state.enemies.count,
		state.projectiles.count,
		state.gems.count,
		state.kills,
		state.explosions,
		alive,
		levels,
	)
}
