// A game's headless binary: the CLI of src/headless/SPEC.md (CLI), generic over the game. The game's
// `main` builds a Headless descriptor and calls headless.run. Every mode prints one JSON object as
// its last stdout line; a non-zero exit code means failure.
package headless

import "core:fmt"
import "core:os"

import "unified:sim"

// Used only inside parametric procs: -vet would flag them in a package that imports unified:headless
// without instantiating those (a suite that never calls headless.run).
_ :: fmt
_ :: os
_ :: sim

run :: proc(h: ^Headless($S, $I, $W, $P)) {
	platform_init()
	a := parse_args()
	if name, has := a.opts["game"]; has {
		delete_key(&a.opts, "game")
		found := h.game.name == name
		for g in h.variants {
			if !found && g.name == name {
				h.game = g
				found = true
			}
		}
		if !found {
			die("unknown --game %q", name)
		}
	}
	if path, has := a.opts["level"]; has {
		delete_key(&a.opts, "level")
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			die("cannot read --level %s", path)
		}
		h.content = data
	}
	ok := true
	switch a.mode {
	case "sim":
		ok = mode_sim(h, &a)
	case "synctest":
		ok = mode_synctest(h, &a)
	case "replay":
		ok = mode_replay(h, &a)
	case "snapshot":
		ok = mode_snapshot(h, &a)
	case "resume":
		ok = mode_resume(h, &a)
	case "bench":
		ok = mode_bench(h, &a)
	case "session":
		ok = mode_session(h, &a)
	case "relay":
		ok = mode_relay(h, &a)
	case "client":
		ok = mode_client(h, &a)
	case:
		o := h.online
		switch {
		case o != nil && a.mode == fmt.tprintf("%s-host", o.name):
			ok = mode_online_host(h, o, &a)
		case o != nil && a.mode == fmt.tprintf("%s-client", o.name):
			ok = mode_online_client(h, o, &a)
		case:
			usage()
		}
	}
	os.exit(ok ? 0 : 1)
}

seed_opt :: proc(a: ^Args) -> u64 {
	return u64(opt_int(a, "seed", 1, lo = 0, hi = int(max(u32))))
}

players_opt :: proc(a: ^Args, slots: int) -> int {
	return opt_int(a, "players", slots, lo = 1, hi = slots)
}

mode_sim :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "ticks", "seed", "players", "trace", "log")
	ticks := u32(opt_int(a, "ticks", required = true, hi = 10_000_000))
	seed := seed_opt(a)
	players := players_opt(a, P)
	trace_path, log_path := opt_str(a, "trace"), opt_str(a, "log")
	tr: Trace
	defer trace_destroy(&tr)
	lg: sim.Input_Log(I, P)
	defer sim.log_destroy(&lg)
	res := run_sim(h, ticks, seed, players, &tr, &lg if log_path != "" else nil)
	ok := trace_path == "" || trace_write(&tr, trace_path)
	ok &&= log_path == "" || sim.log_write(log_path, &lg)
	fmt.printfln(
		`{{"mode":"sim","ticks":%d,"seed":%d,"players":%d,"final_checksum":"%016x",%s"ok":%v}}`,
		res.final_tick,
		seed,
		players,
		res.final_checksum,
		res.summary != "" ? fmt.tprintf("%s,", res.summary) : "",
		ok,
	)
	return ok
}

mode_synctest :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "ticks", "window", "seed", "players")
	ticks := u32(opt_int(a, "ticks", required = true, hi = 10_000_000))
	window := u32(opt_int(a, "window", required = true, lo = 1, hi = sim.RING - 1))
	seed := seed_opt(a)
	players := players_opt(a, P)
	res := run_synctest(h, ticks, window, seed, players)
	if res.mismatches > 0 {
		fmt.eprintfln("synctest: tick %d re-simulated differently at %d", res.first_tick, res.first_at)
	}
	fmt.printfln(
		`{{"mode":"synctest","ticks":%d,"window":%d,"seed":%d,"players":%d,"mismatches":%d,"first_mismatch":%d,"resimulated_ticks":%d,"final_checksum":"%016x"}}`,
		ticks,
		window,
		seed,
		players,
		res.mismatches,
		res.first_tick,
		res.resimulated,
		res.final_checksum,
	)
	return res.mismatches == 0
}

mode_replay :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "log", "trace")
	log_path := opt_str(a, "log", required = true)
	lg, lok := sim.log_read(log_path, I, P)
	if !lok {
		die("replay: cannot read input log %s (or it is for another game build)", log_path)
	}
	defer sim.log_destroy(&lg)
	tr: Trace
	defer trace_destroy(&tr)
	res, ok := run_replay(h, &lg, &tr)
	if path := opt_str(a, "trace"); ok && path != "" {
		ok = trace_write(&tr, path)
	}
	fmt.printfln(
		`{{"mode":"replay","ticks":%d,"final_checksum":"%016x","ok":%v}}`,
		res.final_tick,
		res.final_checksum,
		ok,
	)
	return ok
}

mode_snapshot :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "ticks", "out", "seed", "players")
	ticks := u32(opt_int(a, "ticks", required = true, hi = 10_000_000))
	out := opt_str(a, "out", required = true)
	data, checksum := run_snapshot(h, ticks, seed_opt(a), players_opt(a, P))
	defer delete(data)
	ok := os.write_entire_file(out, data) == nil
	fmt.printfln(
		`{{"mode":"snapshot","tick":%d,"bytes":%d,"checksum":"%016x","ok":%v}}`,
		ticks,
		len(data),
		checksum,
		ok,
	)
	return ok
}

mode_resume :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "in", "ticks", "trace", "players")
	ticks := u32(opt_int(a, "ticks", required = true, hi = 10_000_000))
	in_path := opt_str(a, "in", required = true)
	data, err := os.read_entire_file(in_path, context.allocator)
	if err != nil {
		die("resume: cannot read %s", in_path)
	}
	defer delete(data)
	tr: Trace
	defer trace_destroy(&tr)
	res, ok := run_resume(h, data, ticks, players_opt(a, P), &tr)
	if path := opt_str(a, "trace"); ok && path != "" {
		ok = trace_write(&tr, path)
	}
	fmt.printfln(
		`{{"mode":"resume","final_tick":%d,"final_checksum":"%016x","ok":%v}}`,
		res.final_tick,
		res.final_checksum,
		ok,
	)
	return ok
}

mode_bench :: proc(h: ^Headless($S, $I, $W, $P), a: ^Args) -> bool {
	check_known(a, "enemies", "window", "ticks", "seed", "players")
	enemies := opt_int(a, "enemies", 1000, lo = 0, hi = 1 << 20)
	window := u32(opt_int(a, "window", 8, lo = 1, hi = sim.RING - 1))
	ticks := u32(opt_int(a, "ticks", 600, lo = 1, hi = 1_000_000))
	br := run_bench(h, enemies, window, ticks, seed_opt(a), players_opt(a, P))
	st :: proc(s: Stat) -> string {
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
