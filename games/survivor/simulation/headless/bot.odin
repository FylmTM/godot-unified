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

bot_run :: proc(game: ^survivor.Game, seed: u64, players: int, limit_s: f32) -> (r: Bot_Run) {
	s := sim.create(game, seed)
	defer sim.destroy(s)
	r.seed = seed
	r.first_level_s = -1
	limit := u32(limit_s * survivor.TICK_HZ)
	for {
		in_: survivor.Inputs
		for p in 0 ..< players {
			in_.present += {p}
			in_.input[p] = survivor.bot_input(&s.state, p, s.tick + 1)
		}
		sim.step(s, &in_)
		st := &s.state
		if st.phase == .Lobby {
			if s.tick > 10 * survivor.TICK_HZ {
				break // never left the lobby
			}
			continue
		}
		elapsed := f32(s.tick - st.match_tick) * survivor.DT
		for e in sim.events_at(s, s.tick) {
			if e.kind == u16(survivor.Event_Kind.Level_Up) && r.first_level_s < 0 {
				r.first_level_s = elapsed
			}
		}
		r.max_enemies = max(r.max_enemies, st.enemies.count)
		for &pl in st.players {
			r.level = max(r.level, pl.level)
		}
		r.wave = st.wave + 1
		r.kills = st.kills
		if st.phase == .Over {
			r.survival_s = f32(st.over_tick - st.match_tick) * survivor.DT
			return
		}
		if s.tick - st.match_tick >= limit {
			r.survival_s = elapsed
			r.survived = true
			return
		}
	}
	return
}

mode_bot :: proc(args: []string) -> bool {
	players, seeds := 1, 8
	minutes: f32 = 10
	tuning := "play"
	for i := 0; i + 1 < len(args); i += 2 {
		v := args[i + 1]
		switch args[i] {
		case "--players":
			players, _ = strconv.parse_int(v)
		case "--seeds":
			seeds, _ = strconv.parse_int(v)
		case "--minutes":
			minutes, _ = strconv.parse_f32(v)
		case "--tuning":
			tuning = v
		case "--set":
			// --set field=value: override one field of the chosen tuning (exploration only)
			kv := strings.split(v, "=", context.temp_allocator)
			n := 0
			ok := len(kv) == 2
			if ok {
				n, ok = strconv.parse_int(kv[1])
			}
			tn := &survivor.TUNINGS[tuning == "stress" ? .Stress : .Play]
			switch kv[0] {
			case "every":
				tn.spawn_every_ticks = u32(n)
			case "base":
				tn.spawn_base = u32(n)
			case "per_wave":
				tn.spawn_per_wave = u32(n)
			case "cap":
				tn.spawn_cap = u32(n)
			case "extra":
				tn.extra_player_pct = u32(n)
			case "wave":
				tn.wave_ticks = u32(n)
			case "hp":
				tn.hp_pct_per_wave = i32(n)
			case "xp_first":
				tn.xp_first = i32(n)
			case "xp_step":
				tn.xp_step = i32(n)
			case:
				ok = false
			}
			if !ok {
				fmt.eprintfln("bot: bad --set %s", v)
				return false
			}
		case:
			fmt.eprintfln("bot: unknown option %s (--players N --seeds K --minutes M --tuning play|stress)", args[i])
			return false
		}
	}
	game := tuning == "stress" ? &survivor.GAME_STRESS : &survivor.GAME
	players = clamp(players, 1, survivor.MAX_PLAYERS)
	first := make([]f32, seeds)
	surv := make([]f32, seeds)
	defer delete(first)
	defer delete(surv)
	never := 0
	for k in 0 ..< seeds {
		r := bot_run(game, u64(k + 1), players, minutes * 60)
		fmt.printfln(
			`{{"seed":%d,"first_level_s":%.1f,"survival_s":%.1f,"survived":%v,"wave":%d,"level":%d,"max_enemies":%d,"kills":%d}}`,
			r.seed,
			r.first_level_s,
			r.survival_s,
			r.survived,
			r.wave,
			r.level,
			r.max_enemies,
			r.kills,
		)
		first[k] = r.first_level_s
		surv[k] = r.survival_s
		never += int(r.first_level_s < 0)
	}
	slice.sort(first)
	slice.sort(surv)
	fmt.printfln(
		`{{"mode":"bot","tuning":"%s","players":%d,"seeds":%d,"first_level_s":{{"min":%.1f,"median":%.1f,"max":%.1f}},"never_levelled":%d,"survival_s":{{"min":%.1f,"median":%.1f,"max":%.1f}}}}`,
		tuning,
		players,
		seeds,
		first[0],
		first[seeds / 2],
		first[seeds - 1],
		never,
		surv[0],
		surv[seeds / 2],
		surv[seeds - 1],
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
