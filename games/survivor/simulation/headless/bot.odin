// `survivor bot`: plays matches with the bot policy (survivor.bot_input) to measure the tuning:
// time to the first level-up, survival time, the wave reached, and the enemy count. One JSON line
// per seed, then a summary line.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../survivor"
import "unified:sim"

Bot_Run :: struct {
	seed:          u64,
	first_level_s: f32, // -1: never
	survival_s:    f32, // match_over time, or the time limit if the match was still on
	survived:      bool, // still alive at the limit
	wave:          u32,
	level:         i32, // highest level reached
	max_enemies:   i32,
	kills:         u32,
}

bot_run :: proc(
	game: ^survivor.Game,
	tune: survivor.Tuning,
	seed: u64,
	player_count: int,
	limit_s: f32,
) -> (
	run: Bot_Run,
) {
	simulation := sim.create(game, seed)
	defer sim.destroy(simulation)
	simulation.state.tune = tune // --set overrides: the tuning is state, so it goes into the tick-0 state
	sim.save(simulation)
	run.seed = seed
	run.first_level_s = -1
	limit := u32(limit_s * survivor.TICK_HZ)
	out: sim.Command_Out
	defer delete(out.list)
	for {
		inputs := survivor.bot_tick(&simulation.state, player_count, simulation.tick + 1, &out)
		sim.step(simulation, &inputs)
		state := &simulation.state
		if state.phase == .Lobby {
			if simulation.tick > 10 * survivor.TICK_HZ {
				break // never left the lobby
			}
			continue
		}
		elapsed := f32(simulation.tick - state.match_tick) * survivor.DT
		for &raw in sim.events_at(simulation, simulation.tick) {
			if _, is_level_up := sim.event_value(&raw, survivor.Event).(survivor.Event_Level_Up);
			   is_level_up && run.first_level_s < 0 {
				run.first_level_s = elapsed
			}
		}
		run.max_enemies = max(run.max_enemies, state.enemies.count)
		for &character in state.players {
			run.level = max(run.level, character.level)
		}
		run.wave = state.wave + 1
		run.kills = state.kills
		if state.phase == .Over {
			run.survival_s = f32(state.over_tick - state.match_tick) * survivor.DT
			return
		}
		if simulation.tick - state.match_tick >= limit {
			run.survival_s = elapsed
			run.survived = true
			return
		}
	}
	return
}

mode_bot :: proc(args: []string) -> bool {
	player_count, seeds := 1, 8
	minutes: f32 = 10
	tuning := "play"
	sets: [dynamic]string
	defer delete(sets)
	for i := 0; i + 1 < len(args); i += 2 {
		value := args[i + 1]
		switch args[i] {
		case "--players":
			player_count, _ = strconv.parse_int(value)
		case "--seeds":
			seeds, _ = strconv.parse_int(value)
		case "--minutes":
			minutes, _ = strconv.parse_f32(value)
		case "--tuning":
			tuning = value
		case "--set":
			append(&sets, value) // applied once --tuning is known
		case:
			fmt.eprintfln("bot: unknown option %s (--players N --seeds K --minutes M --tuning play|stress)", args[i])
			return false
		}
	}
	game := tuning == "stress" ? &survivor.GAME_STRESS : &survivor.GAME
	tune := survivor.TUNINGS[tuning == "stress" ? .Stress : .Play]
	for set in sets {
		// --set field=value: override one field of the chosen tuning (exploration only)
		field_value := strings.split(set, "=", context.temp_allocator)
		number := 0
		ok := len(field_value) == 2
		if ok {
			number, ok = strconv.parse_int(field_value[1])
		}
		switch field_value[0] {
		case "every":
			tune.spawn_every_ticks = u32(number)
		case "base":
			tune.spawn_base = u32(number)
		case "per_wave":
			tune.spawn_per_wave = u32(number)
		case "cap":
			tune.spawn_cap = u32(number)
		case "extra":
			tune.extra_player_pct = u32(number)
		case "wave":
			tune.wave_ticks = u32(number)
		case "hp":
			tune.hp_pct_per_wave = i32(number)
		case "xp_first":
			tune.xp_first = i32(number)
		case "xp_step":
			tune.xp_step = i32(number)
		case:
			ok = false
		}
		if !ok {
			fmt.eprintfln("bot: bad --set %s", set)
			return false
		}
	}
	player_count = clamp(player_count, 1, survivor.PLAYERS)
	first := make([]f32, seeds)
	survival := make([]f32, seeds)
	defer delete(first)
	defer delete(survival)
	never := 0
	for k in 0 ..< seeds {
		run := bot_run(game, tune, u64(k + 1), player_count, minutes * 60)
		fmt.printfln(
			`{{"seed":%d,"first_level_s":%.1f,"survival_s":%.1f,"survived":%v,"wave":%d,"level":%d,"max_enemies":%d,"kills":%d}}`,
			run.seed,
			run.first_level_s,
			run.survival_s,
			run.survived,
			run.wave,
			run.level,
			run.max_enemies,
			run.kills,
		)
		first[k] = run.first_level_s
		survival[k] = run.survival_s
		never += int(run.first_level_s < 0)
	}
	slice.sort(first)
	slice.sort(survival)
	fmt.printfln(
		`{{"mode":"bot","tuning":"%s","players":%d,"seeds":%d,"first_level_s":{{"min":%.1f,"median":%.1f,"max":%.1f}},"never_levelled":%d,"survival_s":{{"min":%.1f,"median":%.1f,"max":%.1f}}}}`,
		tuning,
		player_count,
		seeds,
		first[0],
		first[seeds / 2],
		first[seeds - 1],
		never,
		survival[0],
		survival[seeds / 2],
		survival[seeds - 1],
	)
	return true
}

bot_main :: proc() -> bool {
	if len(os.args) >= 2 && os.args[1] == "bot" {
		ok := mode_bot(os.args[2:])
		os.exit(ok ? 0 : 1)
	}
	return false
}
