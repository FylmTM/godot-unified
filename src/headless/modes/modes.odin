// A game's headless binary: the CLI of src/headless/SPEC.md (CLI), generic over the game, on top of the
// in-memory runs of unified:headless. The game's `main` builds a headless.Headless and calls modes.run.
// Every mode prints one JSON object as its last stdout line; a non-zero exit code means failure.
package modes

// Used only inside generic procs (see netmodes.odin).
@(require) import "core:fmt"
@(require) import "core:os"

// Imported as `uheadless`: the modes name their Headless parameter `headless`.
import uheadless "unified:headless"
import "unified:sim"

// Runs the mode named on the command line. `variants`: other variants of the game (e.g. other
// tunings), picked with `--game NAME` (sim.Game.name) on any mode. `online`: a lobby transport for the
// <name>-host and <name>-client modes (optional).
run :: proc(
	headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS),
	variants: []^sim.Game(State, Input, World, PLAYERS) = nil,
	online: ^Online = nil,
) {
	platform_init()
	args := parse_args()
	if name, has := args.opts["game"]; has {
		delete_key(&args.opts, "game")
		found := headless.game.name == name
		for variant in variants {
			if !found && variant.name == name {
				headless.game = variant
				found = true
			}
		}
		if !found {
			die("unknown --game %q", name)
		}
	}
	if path, has := args.opts["level"]; has {
		delete_key(&args.opts, "level")
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			die("cannot read --level %s", path)
		}
		headless.content = data
	}
	ok := true
	switch args.mode {
	case "sim":
		ok = mode_sim(headless, &args)
	case "synctest":
		ok = mode_synctest(headless, &args)
	case "replay":
		ok = mode_replay(headless, &args)
	case "snapshot":
		ok = mode_snapshot(headless, &args)
	case "resume":
		ok = mode_resume(headless, &args)
	case "bench":
		ok = mode_bench(headless, &args)
	case "net-bench":
		ok = mode_net_bench(headless, &args)
	case "table-bench":
		ok = mode_table_bench(&args)
	case "session":
		ok = mode_session(headless, &args)
	case "relay":
		ok = mode_relay(headless, &args)
	case "client":
		ok = mode_client(headless, &args)
	case:
		switch {
		case online != nil && args.mode == fmt.tprintf("%s-host", online.name):
			ok = mode_online_host(headless, online, &args)
		case online != nil && args.mode == fmt.tprintf("%s-client", online.name):
			ok = mode_online_client(headless, online, &args)
		case:
			usage()
		}
	}
	os.exit(ok ? 0 : 1)
}

// The `--seed` option (default 1, at most u32 max), shared by every mode that takes one.
seed_opt :: proc(args: ^Args) -> u64 {
	return u64(opt_int(args, "seed", 1, low = 0, high = int(max(u32))))
}

// The `--players` option, 1 to the game's PLAYERS (its default).
players_opt :: proc(args: ^Args, max_players: int) -> int {
	return opt_int(args, "players", max_players, low = 1, high = max_players)
}

// `--window`: a rollback window, 1 to the longest the game's ring allows (headless.max_window).
window_opt :: proc(
	headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS),
	args: ^Args,
	fallback := 0,
	required := false,
) -> u32 {
	longest := uheadless.max_window(headless.game)
	window := opt_int(args, "window", fallback, required, low = 1, high = longest)
	if window < 1 || window > longest {
		die("%s: the window must be in [1, %d] (the game's ring), got %d", args.mode, longest, window)
	}
	return u32(window)
}

// The `sim` mode: an offline run with scripted inputs, writing the per-tick trace and the input log when asked.
mode_sim :: proc(headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS), args: ^Args) -> bool {
	check_known(args, "ticks", "seed", "players", "trace", "log")
	ticks := u32(opt_int(args, "ticks", required = true, high = 10_000_000))
	seed := seed_opt(args)
	players := players_opt(args, PLAYERS)
	trace_path, log_path := opt_str(args, "trace"), opt_str(args, "log")
	trace: uheadless.Trace
	defer uheadless.trace_destroy(&trace)
	input_log: sim.Input_Log(Input, PLAYERS)
	defer sim.log_destroy(&input_log)
	result := uheadless.run_sim(headless, ticks, seed, players, &trace, &input_log if log_path != "" else nil)
	ok := trace_path == "" || uheadless.trace_write(&trace, trace_path)
	ok &&= log_path == "" || sim.log_write(log_path, &input_log)
	fmt.printfln(
		`{{"mode":"sim","ticks":%d,"seed":%d,"players":%d,"final_checksum":"%016x",%s"ok":%v}}`,
		result.final_tick,
		seed,
		players,
		result.final_checksum,
		result.summary != "" ? fmt.tprintf("%s,", result.summary) : "",
		ok,
	)
	return ok
}

// The `synctest` mode: an offline run that re-simulates the last `--window` ticks every tick and fails on any
// tick that comes out differently.
mode_synctest :: proc(headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS), args: ^Args) -> bool {
	check_known(args, "ticks", "window", "seed", "players")
	ticks := u32(opt_int(args, "ticks", required = true, high = 10_000_000))
	window := window_opt(headless, args, required = true)
	seed := seed_opt(args)
	players := players_opt(args, PLAYERS)
	result := uheadless.run_synctest(headless, ticks, window, seed, players)
	if result.mismatches > 0 {
		fmt.eprintfln("synctest: tick %d re-simulated differently at %d", result.first_tick, result.first_at)
	}
	fmt.printfln(
		`{{"mode":"synctest","ticks":%d,"window":%d,"seed":%d,"players":%d,"mismatches":%d,"first_mismatch":%d,"resimulated_ticks":%d,"final_checksum":"%016x"}}`,
		ticks,
		window,
		seed,
		players,
		result.mismatches,
		result.first_tick,
		result.resimulated,
		result.final_checksum,
	)
	return result.mismatches == 0
}

// The `replay` mode: replays an input log file, writing the trace when asked; fails on a log of another build.
mode_replay :: proc(headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS), args: ^Args) -> bool {
	check_known(args, "log", "trace")
	log_path := opt_str(args, "log", required = true)
	input_log, log_ok := sim.log_read(log_path, Input, PLAYERS)
	if !log_ok {
		die("replay: cannot read input log %s (or it is for another game build)", log_path)
	}
	defer sim.log_destroy(&input_log)
	trace: uheadless.Trace
	defer uheadless.trace_destroy(&trace)
	result, ok := uheadless.run_replay(headless, &input_log, &trace)
	if path := opt_str(args, "trace"); ok && path != "" {
		ok = uheadless.trace_write(&trace, path)
	}
	fmt.printfln(
		`{{"mode":"replay","ticks":%d,"final_checksum":"%016x","ok":%v}}`,
		result.final_tick,
		result.final_checksum,
		ok,
	)
	return ok
}

// The `snapshot` mode: runs offline to `--ticks` and writes a portable snapshot of that tick to `--out`.
mode_snapshot :: proc(headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS), args: ^Args) -> bool {
	check_known(args, "ticks", "out", "seed", "players")
	ticks := u32(opt_int(args, "ticks", required = true, high = 10_000_000))
	out := opt_str(args, "out", required = true)
	data, checksum := uheadless.run_snapshot(headless, ticks, seed_opt(args), players_opt(args, PLAYERS))
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

// The `resume` mode: restores a snapshot file and runs `--ticks` more, tracing them, so a test can compare
// with the uninterrupted run.
mode_resume :: proc(headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS), args: ^Args) -> bool {
	check_known(args, "in", "ticks", "trace", "players")
	ticks := u32(opt_int(args, "ticks", required = true, high = 10_000_000))
	in_path := opt_str(args, "in", required = true)
	data, err := os.read_entire_file(in_path, context.allocator)
	if err != nil {
		die("resume: cannot read %s", in_path)
	}
	defer delete(data)
	trace: uheadless.Trace
	defer uheadless.trace_destroy(&trace)
	result, ok := uheadless.run_resume(headless, data, ticks, players_opt(args, PLAYERS), &trace)
	if path := opt_str(args, "trace"); ok && path != "" {
		ok = uheadless.trace_write(&trace, path)
	}
	fmt.printfln(
		`{{"mode":"resume","final_tick":%d,"final_checksum":"%016x","ok":%v}}`,
		result.final_tick,
		result.final_checksum,
		ok,
	)
	return ok
}

// The `bench` mode: times step, save, restore and re-sim with `--entities` held (the game's standard benchmark
// without options); `uni bench` reads its JSON.
mode_bench :: proc(headless: ^uheadless.Headless($State, $Input, $World, $PLAYERS), args: ^Args) -> bool {
	check_known(args, "entities", "window", "ticks", "seed", "players")
	standard := headless.bench
	if standard.ticks == 0 {
		standard = {
			what     = "the default benchmark",
			entities = 1000,
			ticks    = 600,
		}
	}
	if standard.window == 0 {
		standard.window = uheadless.prediction_window(headless.game)
	}
	entities := opt_int(args, "entities", standard.entities, low = 0, high = 1 << 20)
	window := window_opt(headless, args, standard.window)
	ticks := u32(opt_int(args, "ticks", standard.ticks, low = 1, high = 1_000_000))
	result := run_bench(headless, entities, window, ticks, seed_opt(args), players_opt(args, PLAYERS))
	stat_json :: proc(stat: Stat) -> string {
		return fmt.tprintf(`{{"mean":%.2f,"p99":%.2f}}`, stat.mean, stat.p99)
	}
	fmt.printfln(
		`{{"mode":"bench","what":"%s","entities":%d,"window":%d,"ticks":%d,"step_us":%s,"save_us":%s,"restore_us":%s,"resim_us":%s,"resim_final_us":%s,"snapshot_bytes":%d,"block_bytes":%d,"entities_mean":%.1f,"mismatches":%d}}`,
		standard.what,
		entities,
		window,
		ticks,
		stat_json(result.step),
		stat_json(result.save),
		stat_json(result.restore),
		stat_json(result.resim),
		stat_json(result.resim_final),
		result.snapshot_bytes,
		result.block_bytes,
		result.entities_mean,
		result.mismatches,
	)
	return result.mismatches == 0
}
