// A game's headless binary: the CLI of src/headless/SPEC.md, generic over the game, on top of the in-memory runs of
// unified:headless. The game's `main` calls modes.run(&GAME, ...). Every mode prints one JSON object as its last
// stdout line; a non-zero exit code means failure. `help` lists the modes and their options.
package modes

// Used only inside generic procs (see netmodes.odin).
@(require) import "core:fmt"
@(require) import "core:os"

// Imported as `uheadless`: the modes name their Headless parameter `headless`.
import uheadless "unified:headless"
import "unified:netcode"
@(require) import "unified:sim" // only in generic procs

// A mode of the binary: the library's, a lobby service's, or a game's own (run's `extra`).
Mode :: struct($G: typeid) {
	name:    string,
	options: string, // its options as `help` shows them: every --name in it is an option it takes, the others fail
	help:    string, // what it is for, one line
	run:     proc(headless: ^uheadless.Headless(G), args: ^Args) -> bool,
	lobby:   ^netcode.Lobby, // a lobby mode's service (Args.lobby)
}

// Runs the mode named on the command line on `game` (its scripted player plays the runs). `options`: the binary's
// content and benchmark (its `game` is `game`). `variants`: other variants of the game (e.g. other tunings), picked
// with `--game NAME` (sim.Game.name) on any mode. `lobbies`: lobby services (eos.lobby) for the <name>-host and
// <name>-client modes; a game opts in, and links the service's SDK. `extra`: the game's own modes.
run :: proc(
	game: ^$G,
	options: uheadless.Headless(G),
	variants: []^G = nil,
	lobbies: []^netcode.Lobby = nil,
	extra: []Mode(G) = nil,
) {
	options := options
	options.game = game
	headless := &options
	platform_init()
	table := make([dynamic]Mode(G), context.temp_allocator)
	append(&table, Mode(G) {
		name    = "sim",
		options = "--ticks N [--seed S] [--players P] [--trace F] [--log F]",
		help    = "an offline run with scripted inputs; writes its per-tick trace and its input log",
		run     = mode_sim,
	}, Mode(G) {
		name    = "synctest",
		options = "--ticks N --window W [--seed S] [--players P]",
		help    = "an offline run that re-simulates the last W ticks every tick; fails on any tick that comes out differently",
		run     = mode_synctest,
	}, Mode(G) {
		name    = "replay",
		options = "--log F [--snapshot F] [--trace F]",
		help    = "replays an input log (from a snapshot's tick with --snapshot, as in an F3 note); fails on another build's",
		run     = mode_replay,
	}, Mode(G) {
		name    = "session",
		options = "[--clients N] [--ticks T] [--profile ideal|wan|bad] [--latency MS [--jitter MS] [--loss PERMILLE]] [--late-join P@T] [--script steady|churn] [--log F] [--seed S]",
		help    = "a relay and scripted clients in this process on a virtual clock behind a network profile: rollbacks, stalls, step times, each client step's time (p99, worst), bytes per second; --late-join P@T: slot P connects at tick T and joins as a player does (its join, snapshot transfer and catch-up); --script churn: every slot's input changes every tick (rollbacks on most ticks)",
		run     = mode_session,
	}, Mode(G) {
		name    = "relay",
		options = "--port P --players N --ticks T [--log F]",
		help    = "a relay alone on a local UDP port until its session ends (uni test --suite net, with `client` processes)",
		run     = mode_relay,
	}, Mode(G) {
		name    = "client",
		options = "--connect HOST:PORT --slot I --ticks T [--profile ideal|wan|bad]",
		help    = "one scripted client of a `relay` process over UDP, behind a network profile",
		run     = mode_client,
	}, Mode(G) {
		name    = "bench",
		options = "[--entities E] [--window W] [--ticks N] [--seed S] [--players P]",
		help    = "times step, save, checksum, restore and a re-sim at the prediction cap every tick (the game's standard run without options)",
		run     = mode_bench,
	})
	for lobby in lobbies {
		append(&table, Mode(G) {
			name    = fmt.tprintf("%s-host", lobby.name),
			options = "--ticks T [--wait-s N] [--players N] [--bucket B] [--code-file F] [--log F]",
			help    = fmt.tprintf("hosts a scripted session in a %s lobby and prints its code", lobby.name),
			run     = mode_lobby_host,
			lobby   = lobby,
		}, Mode(G) {
			name    = fmt.tprintf("%s-client", lobby.name),
			options = "--code CODE --ticks T [--bucket B]",
			help    = fmt.tprintf("joins a %s-host lobby by code and plays a scripted remote player", lobby.name),
			run     = mode_lobby_client,
			lobby   = lobby,
		})
	}
	append(&table, ..extra)
	argv := os.args[1:]
	if len(argv) == 0 || argv[0] == "help" || argv[0] == "--help" {
		print_usage(table[:], len(argv) == 0 ? os.stderr : os.stdout)
		os.exit(len(argv) == 0 ? 2 : 0)
	}
	mode: ^Mode(G)
	for &entry in table {
		if entry.name == argv[0] {
			mode = &entry
		}
	}
	if mode == nil {
		fmt.eprintfln("unknown mode %q", argv[0])
		print_usage(table[:], os.stderr)
		os.exit(2)
	}
	if len(argv) == 2 && argv[1] == "--help" {
		fmt.printfln("%s %s\n  %s\n%s", mode.name, mode.options, mode.help, ANY_MODE)
		os.exit(0)
	}
	args := parse_options(mode.name, argv[1:])
	args.lobby = mode.lobby
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
	check_known(&args, mode.options)
	os.exit(mode.run(headless, &args) ? 0 : 1)
}

@(private)
ANY_MODE :: "  any mode: [--game NAME] a variant of the game (e.g. its play tuning); [--level FILE] the level file (default: the one the game embeds)"

@(private)
print_usage :: proc(table: []Mode($G), to: ^os.File) {
	fmt.fprintfln(
		to,
		"usage: %s <mode> [options]   (<mode> --help: one mode)",
		len(os.args) > 0 ? os.args[0] : "headless",
	)
	for mode in table {
		fmt.fprintfln(to, "  %s %s\n      %s", mode.name, mode.options, mode.help)
	}
	fmt.fprintln(to, ANY_MODE)
}

// The `--seed` option (default 1, at most u32 max), shared by every mode that takes one.
@(private)
seed_opt :: proc(args: ^Args) -> u64 {
	return u64(opt_int(args, "seed", 1, low = 0, high = int(max(u32))))
}

// The `--players` option, 1 to the game's PLAYERS (its default).
@(private)
players_opt :: proc(args: ^Args, max_players: int) -> int {
	return opt_int(args, "players", max_players, low = 1, high = max_players)
}

// `--window`: a rollback window, 1 to the longest the game's ring allows (headless.max_window); `fallback` (a game's
// standard benchmark) must be in that range too.
@(private)
window_opt :: proc(headless: ^uheadless.Headless($G), args: ^Args, fallback := 0, required := false) -> u32 {
	longest := uheadless.max_window(headless.game)
	assert(
		required || (fallback >= 1 && fallback <= longest),
		"the default rollback window is outside the game's ring",
	)
	return u32(opt_int(args, "window", fallback, required, low = 1, high = longest))
}

// The `sim` mode: an offline run with scripted inputs, writing the per-tick trace and the input log when asked.
@(private)
mode_sim :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	ticks := u32(opt_int(args, "ticks", required = true, high = 10_000_000))
	seed := seed_opt(args)
	players := players_opt(args, PLAYERS)
	trace_path, log_path := opt_str(args, "trace"), opt_str(args, "log")
	trace: uheadless.Trace
	defer uheadless.trace_destroy(&trace)
	input_log: sim.Input_Log(G)
	defer sim.log_destroy(&input_log)
	result := uheadless.run_sim(headless, ticks, seed, players, &trace, &input_log if log_path != "" else nil)
	ok := trace_path == "" || uheadless.trace_write(&trace, trace_path)
	ok &&= log_path == "" || uheadless.log_write(log_path, &input_log)
	fmt.printfln(
		`{{"mode":"sim","ticks":%d,"seed":%d,"players":%d,"final_checksum":"%016x","ok":%v}}`,
		result.final_tick,
		seed,
		players,
		result.final_checksum,
		ok,
	)
	return ok
}

// The `synctest` mode: an offline run that re-simulates the last `--window` ticks every tick and fails on any
// tick that comes out differently.
@(private)
mode_synctest :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	ticks := u32(opt_int(args, "ticks", required = true, high = 10_000_000))
	window := window_opt(headless, args, required = true)
	seed := seed_opt(args)
	players := players_opt(args, PLAYERS)
	result := uheadless.run_synctest(headless, ticks, window, seed, players)
	if result.mismatches > 0 {
		fmt.eprintfln("synctest: tick %d re-simulated differently at %d", result.first_tick, result.first_at)
	}
	if result.check != "" {
		fmt.eprintfln("synctest: after restoring tick %d: %s", result.check_tick, result.check)
	}
	if result.problem != "" {
		fmt.eprintfln("synctest: %s", result.problem)
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
	return result.mismatches == 0 && result.check == "" && result.problem == ""
}

// The `replay` mode: replays an input log file (from tick 0, or from a portable snapshot: an F3 note's recording),
// writing the trace when asked; fails on a log of another build.
@(private)
mode_replay :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	log_path := opt_str(args, "log", required = true)
	input_log, log_ok := uheadless.log_read(log_path, G)
	if !log_ok {
		die("replay: cannot read input log %s (or it is for another game build)", log_path)
	}
	defer sim.log_destroy(&input_log)
	trace: uheadless.Trace
	defer uheadless.trace_destroy(&trace)
	snapshot: []u8
	defer delete(snapshot)
	if path := opt_str(args, "snapshot"); path != "" {
		read_err: os.Error
		snapshot, read_err = os.read_entire_file(path, context.allocator)
		if read_err != nil do die("replay: cannot read snapshot %s", path)
	}
	result, ok := uheadless.run_replay(headless, &input_log, &trace, snapshot)
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

// The `bench` mode: times step, save, restore and re-sim with `--entities` held (the game's standard benchmark
// without options); `uni bench` reads its JSON.
@(private)
mode_bench :: proc(headless: ^uheadless.Headless($G), args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	standard := headless.bench
	if standard.ticks == 0 {
		standard = {
			what     = headless.game.name,
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
	// What ran, from the run's actual parameters (the game names only its own part).
	what := fmt.tprintf(
		"%s; a %d-tick rollback every tick, %d ticks (the first %d untimed)",
		standard.what,
		window,
		ticks,
		result.warmup,
	)
	fmt.printfln(
		`{{"mode":"bench","what":"%s","entities":%d,"window":%d,"ticks":%d,"warmup":%d,"step_us":%s,"save_us":%s,"restore_us":%s,"resim_us":%s,"resim_final_us":%s,"checksum_us":%s,"checksum_deep_us":%s,"snapshot_encode_us":%s,"snapshot_keep_us":%s,"snapshot_bytes":%d,"save_bytes":%d,"mismatches":%d}}`,
		what,
		entities,
		window,
		ticks,
		result.warmup,
		stat_json(result.step),
		stat_json(result.save),
		stat_json(result.restore),
		stat_json(result.resim),
		stat_json(result.resim_final),
		stat_json(result.checksum),
		stat_json(result.checksum_deep),
		stat_json(result.snapshot_encode),
		stat_json(result.snapshot_keep),
		result.snapshot_bytes,
		result.save_bytes,
		result.mismatches,
	)
	return result.mismatches == 0
}
