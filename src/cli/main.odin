// unified: the CLI of spec/CORE.md §3. Every mode prints one JSON object as its last stdout line;
// a non-zero exit code means failure.
package main

import "core:fmt"
import "core:os"

import "../game"
import "../sim"

main :: proc() {
	platform_init()
	a := parse_args()
	ok := true
	switch a.mode {
	case "sim":
		ok = mode_sim(&a)
	case "synctest":
		ok = mode_synctest(&a)
	case "replay":
		ok = mode_replay(&a)
	case "snapshot":
		ok = mode_snapshot(&a)
	case "resume":
		ok = mode_resume(&a)
	case "bench":
		ok = mode_bench(&a)
	case "session":
		ok = mode_session(&a)
	case "relay":
		ok = mode_relay(&a)
	case "client":
		ok = mode_client(&a)
	case "eos-relay":
		ok = mode_eos_relay(&a)
	case "eos-client":
		ok = mode_eos_client(&a)
	case:
		usage()
	}
	os.exit(ok ? 0 : 1)
}

seed_opt :: proc(a: ^Args) -> u32 {
	return u32(opt_int(a, "seed", 1, lo = 0, hi = int(max(u32))))
}

players_opt :: proc(a: ^Args) -> int {
	return opt_int(a, "players", 4, lo = 1, hi = game.MAX_PLAYERS)
}

mode_sim :: proc(a: ^Args) -> bool {
	check_known(a, "ticks", "seed", "players", "trace", "log")
	ticks := u32(opt_int(a, "ticks", required = true, hi = 10_000_000))
	seed := seed_opt(a)
	players := players_opt(a)
	res, ok := sim.run_sim(ticks, seed, players, opt_str(a, "trace"), opt_str(a, "log"))
	fmt.printfln(
		`{{"mode":"sim","ticks":%d,"seed":%d,"players":%d,"final_checksum":"%016x",%s,"ok":%v}}`,
		res.final_tick,
		seed,
		players,
		res.final_checksum,
		res.summary,
		ok,
	)
	return ok
}

mode_synctest :: proc(a: ^Args) -> bool {
	check_known(a, "ticks", "window", "seed", "players")
	ticks := u32(opt_int(a, "ticks", required = true, hi = 10_000_000))
	window := u32(opt_int(a, "window", required = true, lo = 1, hi = sim.RING - 1))
	seed := seed_opt(a)
	players := players_opt(a)
	mm, resim, final := sim.run_synctest(ticks, window, seed, players)
	fmt.printfln(
		`{{"mode":"synctest","ticks":%d,"window":%d,"seed":%d,"players":%d,"mismatches":%d,"resimulated_ticks":%d,"final_checksum":"%016x"}}`,
		ticks,
		window,
		seed,
		players,
		mm,
		resim,
		final,
	)
	return mm == 0
}

mode_replay :: proc(a: ^Args) -> bool {
	check_known(a, "log", "trace")
	res, ok := sim.run_replay(opt_str(a, "log", required = true), opt_str(a, "trace"))
	fmt.printfln(
		`{{"mode":"replay","ticks":%d,"final_checksum":"%016x","ok":%v}}`,
		res.final_tick,
		res.final_checksum,
		ok,
	)
	return ok
}

mode_snapshot :: proc(a: ^Args) -> bool {
	check_known(a, "ticks", "out", "seed", "players")
	ticks := u32(opt_int(a, "ticks", required = true, hi = 10_000_000))
	n, checksum, ok := sim.run_snapshot(ticks, seed_opt(a), players_opt(a), opt_str(a, "out", required = true))
	fmt.printfln(`{{"mode":"snapshot","tick":%d,"bytes":%d,"checksum":"%016x","ok":%v}}`, ticks, n, checksum, ok)
	return ok
}

mode_resume :: proc(a: ^Args) -> bool {
	check_known(a, "in", "ticks", "trace")
	ticks := u32(opt_int(a, "ticks", required = true, hi = 10_000_000))
	res, ok := sim.run_resume(opt_str(a, "in", required = true), ticks, opt_str(a, "trace"))
	fmt.printfln(
		`{{"mode":"resume","final_tick":%d,"final_checksum":"%016x","ok":%v}}`,
		res.final_tick,
		res.final_checksum,
		ok,
	)
	return ok
}

mode_bench :: proc(a: ^Args) -> bool {
	check_known(a, "enemies", "window", "ticks", "seed", "players")
	enemies := opt_int(a, "enemies", 1000, lo = 0, hi = game.MAX_ENEMIES)
	window := u32(opt_int(a, "window", 8, lo = 1, hi = sim.RING - 1))
	ticks := u32(opt_int(a, "ticks", 600, lo = 1, hi = 1_000_000))
	br := sim.run_bench(enemies, window, ticks, seed_opt(a), players_opt(a))
	st :: proc(s: sim.Stat) -> string {
		return fmt.tprintf(`{{"mean":%.2f,"p99":%.2f}}`, s.mean, s.p99)
	}
	fmt.printfln(
		`{{"mode":"bench","enemies":%d,"window":%d,"ticks":%d,"step_us":%s,"save_us":%s,"restore_us":%s,"resim_us":%s,"snapshot_bytes":%d,"block_bytes":%d,"enemies_mean":%.1f,"mismatches":%d}}`,
		enemies,
		window,
		ticks,
		st(br.step),
		st(br.save),
		st(br.restore),
		st(br.resim),
		br.snapshot_bytes,
		br.block_bytes,
		br.enemies_mean,
		br.mismatches,
	)
	return br.mismatches == 0
}
