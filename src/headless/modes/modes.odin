// A game's headless binary (src/headless/README.md, The binary), generic over the game, on top of the in-memory runs
// of unified:headless. The game's `main` calls modes.run(&GAME, ...). Every mode prints one JSON object as its last
// stdout line; a non-zero exit code means failure. `help` lists the modes and their options.
package modes

// Used only inside generic procs (see netmodes.odin).
@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:slice"
@(require) import "core:strings"

// Imported as `uheadless`: `headless` reads as a run's name in the modes.
import uheadless "unified:headless"
import "unified:netcode"
@(require) import "unified:sim" // only in generic procs

// A mode of the binary: the library's, a lobby service's, or a game's own (run's `own_modes`, the one way a game's
// repo adds a mode). `run` parses its options into an `options` struct (parse), which `help` shows (usage).
Mode :: struct($G: typeid) {
	name:    string,
	options: typeid, // its options struct: core:flags fields, `args:"required"` and `hint:"N"` tags
	help:    string, // what it is for, one line
	run:     proc(game: ^G, args: ^Args) -> bool,
	lobby:   ^netcode.Lobby, // a lobby mode's service (Args.lobby)
}

// Runs the mode named on the command line on `game` (its scripted player plays the runs, on its levels). `bench`:
// the game's standard benchmark, what `bench` runs without options (`uni bench`); none (zero): `bench` without
// options runs nothing, and `uni bench` has no row for the game. `variants`: other variants of the game (e.g. other
// tunings), picked with `--game NAME` (sim.Game.name) on any mode; `--level NAME=FILE` on any mode plays a copy of the
// game with that level replaced. `lobbies`: lobby services (eos.lobby) for the
// <name>-host and <name>-client modes; a game opts in, and links the service's SDK. `own_modes`: the game's own modes
// (Mode: an options struct its `run` parses).
run :: proc(
	game: ^$G,
	bench := uheadless.Bench{},
	variants: []^G = nil,
	lobbies: []^netcode.Lobby = nil,
	own_modes: []Mode(G) = nil,
) {
	game := game
	platform_init()
	table := make([dynamic]Mode(G), context.temp_allocator)
	append(&table, Mode(G) {
		name    = "sim",
		options = Sim_Options,
		help    = "an offline run with scripted inputs; writes its per-tick trace and its input log",
		run     = mode_sim,
	}, Mode(G) {
		name    = "synctest",
		options = Synctest_Options,
		help    = "an offline run that re-simulates the last W ticks every tick; fails on any tick that comes out differently",
		run     = mode_synctest,
	}, Mode(G) {
		name    = "replay",
		options = Replay_Options,
		help    = "replays an input log (from a snapshot's tick with --snapshot, as in an F3 note) against its checkpoints: the last agreeing and the first divergent; another build's only with --any-build",
		run     = mode_replay,
	}, Mode(G) {
		name    = "predict-stats",
		options = Predict_Stats_Options,
		help    = "scores sim.Game.predict_input on an input log (an F3 note's inputs.unil is real play): the rollbacks a client N ticks deep (default: a 100 ms round trip's) would have had, guessing the others' inputs by repeating the last one and by the game's hook",
		run     = mode_predict_stats,
	}, Mode(G) {
		name    = "session",
		options = Session_Options,
		help    = "a relay and scripted clients in this process on a virtual clock behind a network profile: rollbacks, stalls, step times, each client step's time (p99, worst), bytes per second; --late-join P@T: slot P connects at tick T and joins as a player does (its join, snapshot transfer and catch-up); --script churn: every slot's input changes every tick (rollbacks on most ticks)",
		run     = mode_session,
	}, Mode(G) {
		name    = "relay",
		options = Relay_Options,
		help    = "a relay alone on a local UDP port until its session ends (uni test --suite net, with `client` processes)",
		run     = mode_relay,
	}, Mode(G) {
		name    = "client",
		options = Client_Options,
		help    = "one scripted client of a `relay` process over UDP, behind a network profile",
		run     = mode_client,
	}, Mode(G) {
		name    = "bench",
		options = Bench_Options,
		help    = "times step, save, checksum, restore and a re-sim at the prediction cap every tick (the game's standard run without options)",
		run     = mode_bench,
	})
	for lobby in lobbies {
		append(&table, Mode(G) {
			name    = fmt.tprintf("%s-host", lobby.name),
			options = Lobby_Host_Options,
			help    = fmt.tprintf("hosts a scripted session in a %s lobby and prints its code", lobby.name),
			run     = mode_lobby_host,
			lobby   = lobby,
		}, Mode(G) {
			name    = fmt.tprintf("%s-client", lobby.name),
			options = Lobby_Client_Options,
			help    = fmt.tprintf("joins a %s-host lobby by code and plays a scripted remote player", lobby.name),
			run     = mode_lobby_client,
			lobby   = lobby,
		})
	}
	append(&table, ..own_modes)
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
		fmt.printfln("%s %s\n  %s\n%s", mode.name, usage(mode.options), mode.help, ANY_MODE)
		os.exit(0)
	}
	any_mode := take_any_mode(argv[1:])
	args := Args {
		mode  = mode.name,
		argv  = any_mode.rest,
		lobby = mode.lobby,
		bench = bench,
	}
	if name := any_mode.game; name != "" {
		found := game.name == name
		for variant in variants {
			if !found && variant.name == name {
				game = variant
				found = true
			}
		}
		if !found {
			die("unknown --game %q", name)
		}
	}
	if pair := any_mode.level; pair != "" {
		name, _, path := strings.partition(pair, "=")
		index := -1
		for file, i in game.levels do if file.name == name do index = i
		if path == "" || index < 0 {
			known := make([dynamic]string, context.temp_allocator)
			for file in game.levels do append(&known, file.name)
			die("--level %q: NAME=FILE, NAME one of the game's levels (%s)", pair, strings.join(known[:], ", "))
		}
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			die("cannot read --level %s", path)
		}
		// A copy of the game with that level replaced (it lives until the process exits).
		on_level := new_clone(game^)
		on_level.levels = slice.clone(game.levels)
		on_level.levels[index].bytes = data
		game = on_level
	}
	if text := any_mode.setup; text != "" {
		setup, problem := sim.struct_from_text(game.setup, text)
		if problem == "" do problem = sim.setup_violation(game, &setup)
		if problem != "" {
			die("--setup %s: %s", text, problem)
		}
		// A copy of the game with that Setup, as --level makes one with that content: every mode plays it.
		with_setup := new_clone(game^)
		with_setup.setup = setup
		game = with_setup
	}
	if text := any_mode.player_profile; text != "" {
		game = with_player_profile(game, text)
	}
	os.exit(mode.run(game, &args) ? 0 : 1)
}

// A copy of the game whose scripted players join with `text`'s assignments (`key=value,...`, sim.struct_from_text)
// over the Profile its script gives them (Game.scripted_profile; none: the zero Profile): the --player-profile of
// every mode. Exits through die on assignments the Profile does not take.
@(private)
with_player_profile :: proc(game: ^$G, text: string) -> ^G {
	Profile :: sim.part(G, sim.GAME_PROFILE)
	// What the copy's scripted_profile reads: one game per process, set once before any mode runs.
	@(static) chosen: struct {
		script: proc(seed: u64, slot: int) -> Profile,
		text:   string,
	}
	if _, problem := sim.struct_from_text(Profile{}, text); problem != "" {
		die("--player-profile %s: %s", text, problem)
	}
	chosen.script, chosen.text = game.scripted_profile, text
	with := new_clone(game^)
	with.scripted_profile = proc(seed: u64, slot: int) -> Profile {
		start: Profile
		if chosen.script != nil do start = chosen.script(seed, slot)
		profile, _ := sim.struct_from_text(start, chosen.text)
		return profile
	}
	return with
}

@(private)
ANY_MODE :: "  any mode: [--game NAME] a variant of the game (e.g. its play tuning); [--level NAME=FILE] play the level NAME from FILE (default: the levels the game embeds); [--setup key=value,...] the session's Setup (default: the game's, Game.setup); [--player-profile key=value,...] over every scripted player's Profile (default: Game.scripted_profile's)"

@(private)
print_usage :: proc(table: []Mode($G), to: ^os.File) {
	fmt.fprintfln(
		to,
		"usage: %s <mode> [options]   (<mode> --help: one mode)",
		len(os.args) > 0 ? os.args[0] : "headless",
	)
	for mode in table {
		fmt.fprintfln(to, "  %s %s\n      %s", mode.name, usage(mode.options), mode.help)
	}
	fmt.fprintln(to, ANY_MODE)
}

// `--seed`: at most u32 max (each mode's default 1).
@(private)
check_seed :: proc(args: ^Args, seed: int) -> u64 {
	in_range(args, "seed", seed, 0, int(max(u32)))
	return u64(seed)
}

// `--window`: a rollback window, 1 to the longest the game's ring allows (headless.max_window).
@(private)
check_window :: proc(game: ^$G, args: ^Args, window: int) -> u32 {
	in_range(args, "window", window, 1, uheadless.max_window(game))
	return u32(window)
}

@(private)
Sim_Options :: struct {
	ticks:   int `args:"required"`,
	seed:    int `hint:"S"`,
	players: int `hint:"P"`,
	trace:   string `hint:"F"`,
	log:     string `hint:"F"`,
}

// The `sim` mode: an offline run with scripted inputs, writing the per-tick trace and the input log when asked.
@(private)
mode_sim :: proc(game: ^$G, args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	options := Sim_Options {
		seed    = 1,
		players = PLAYERS,
	}
	parse(args, &options)
	in_range(args, "ticks", options.ticks, 0, 10_000_000)
	in_range(args, "players", options.players, 1, PLAYERS)
	ticks, seed, players := u32(options.ticks), check_seed(args, options.seed), options.players
	trace_path, log_path := options.trace, options.log
	trace: uheadless.Trace
	defer uheadless.trace_destroy(&trace)
	input_log: sim.Input_Log(G)
	defer sim.log_destroy(&input_log)
	result := uheadless.run_sim(game, ticks, seed, players, &trace, &input_log if log_path != "" else nil)
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

@(private)
Synctest_Options :: struct {
	ticks:   int `args:"required"`,
	window:  int `args:"required" hint:"W"`,
	seed:    int `hint:"S"`,
	players: int `hint:"P"`,
}

// The `synctest` mode: an offline run that re-simulates the last `--window` ticks every tick and fails on any
// tick that comes out differently.
@(private)
mode_synctest :: proc(game: ^$G, args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	options := Synctest_Options {
		seed    = 1,
		players = PLAYERS,
	}
	parse(args, &options)
	in_range(args, "ticks", options.ticks, 0, 10_000_000)
	in_range(args, "players", options.players, 1, PLAYERS)
	ticks, window := u32(options.ticks), check_window(game, args, options.window)
	seed, players := check_seed(args, options.seed), options.players
	result := uheadless.run_synctest(game, ticks, window, seed, players)
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

@(private)
Replay_Options :: struct {
	log:       string `args:"required" hint:"F"`,
	snapshot:  string `hint:"F"`,
	trace:     string `hint:"F"`,
	any_build: bool,
}

// The `replay` mode: replays an input log file (from tick 0, or from a portable snapshot: an F3 note's recording),
// writing the trace when asked; fails on a log of another build.
@(private)
mode_replay :: proc(game: ^$G, args: ^Args) -> bool {
	options: Replay_Options
	parse(args, &options)
	log_path := options.log
	input_log, log_ok := uheadless.log_read(log_path, G)
	if !log_ok {
		die("replay: cannot read input log %s (or it is for another game build)", log_path)
	}
	defer sim.log_destroy(&input_log)
	trace: uheadless.Trace
	defer uheadless.trace_destroy(&trace)
	snapshot: []u8
	defer delete(snapshot)
	if path := options.snapshot; path != "" {
		read_err: os.Error
		snapshot, read_err = os.read_entire_file(path, context.allocator)
		if read_err != nil do die("replay: cannot read snapshot %s", path)
	}
	result, ok := uheadless.run_replay(game, &input_log, &trace, snapshot, options.any_build)
	if path := options.trace; result.final_tick != 0 && path != "" {
		ok = uheadless.trace_write(&trace, path) && ok
	}
	fmt.printfln(
		`{{"mode":"replay","ticks":%d,"final_checksum":"%016x","checkpoints":%d,"agreed_tick":%d,"diverged_tick":%d,"ok":%v}}`,
		result.final_tick,
		result.final_checksum,
		result.checkpoints,
		result.agreed_tick,
		result.diverged_tick,
		ok,
	)
	return ok
}

@(private)
Predict_Stats_Options :: struct {
	log:   string `args:"required" hint:"F"`,
	depth: int,
}

// The `predict-stats` mode: headless.prediction_stats on a log.
@(private)
mode_predict_stats :: proc(game: ^$G, args: ^Args) -> bool {
	timing := netcode.timing_of(game.tick_hz)
	options := Predict_Stats_Options {
		depth = int(netcode.ceil_ticks(100_000 + netcode.DELAY_MARGIN_US, timing.tick_us)),
	}
	parse(args, &options)
	in_range(args, "depth", options.depth, 1, int(timing.prediction_cap))
	log_path := options.log
	input_log, log_ok := uheadless.log_read(log_path, G)
	if !log_ok {
		die("predict-stats: cannot read input log %s (or it is for another game build)", log_path)
	}
	defer sim.log_destroy(&input_log)
	stats := uheadless.prediction_stats(game, &input_log, u32(options.depth))
	fmt.printfln(
		`{{"mode":"predict-stats","ticks":%d,"depth":%d,"hook":%v,"rollbacks_repeat_last":%d,"rollbacks_predict_input":%d,"ok":true}}`,
		stats.ticks,
		stats.depth,
		game.predict_input != nil,
		stats.repeat_last,
		stats.predict_input,
	)
	return true
}

@(private)
Bench_Options :: struct {
	entities: int `hint:"E"`,
	window:   int `hint:"W"`,
	ticks:    int,
	seed:     int `hint:"S"`,
	players:  int `hint:"P"`,
}

// The `bench` mode: times step, save, restore and re-sim with `--entities` held (the game's standard benchmark
// without options); `uni bench` reads its JSON.
@(private)
mode_bench :: proc(game: ^$G, args: ^Args) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	standard := args.bench
	if standard.ticks == 0 && len(args.argv) == 0 {
		fmt.println(`{"mode":"bench","skipped":true}`) // no standard benchmark: `uni bench` leaves the game out
		return true
	}
	if standard.ticks == 0 {
		standard = {
			what     = game.name,
			entities = 1000,
			ticks    = 600,
		}
	}
	if standard.window == 0 {
		standard.window = uheadless.prediction_window(game)
	}
	assert(
		standard.window >= 1 && standard.window <= uheadless.max_window(game),
		"the default rollback window is outside the game's ring",
	)
	options := Bench_Options {
		entities = standard.entities,
		window   = int(standard.window),
		ticks    = int(standard.ticks),
		seed     = 1,
		players  = PLAYERS,
	}
	parse(args, &options)
	in_range(args, "entities", options.entities, 0, 1 << 20)
	in_range(args, "ticks", options.ticks, 1, 1_000_000)
	in_range(args, "players", options.players, 1, PLAYERS)
	entities, window, ticks := options.entities, check_window(game, args, options.window), u32(options.ticks)
	result := run_bench(game, entities, window, ticks, check_seed(args, options.seed), options.players)
	// What ran, from the run's actual parameters (the game names only its own part).
	what := fmt.tprintf(
		"%s; a %d-tick rollback every tick, %d ticks (the first %d untimed)",
		standard.what,
		window,
		ticks,
		result.warmup,
	)
	fmt.printfln(
		`{{"mode":"bench","what":"%s","entities":%d,"window":%d,"ticks":%d,"warmup":%d,"step_us":%s,"save_us":%s,"restore_us":%s,"resim_us":%s,"resim_final_us":%s,"checksum_us":%s,"checksum_deep_us":%s,"snapshot_encode_us":%s,"snapshot_keep_us":%s,"snapshot_bytes":%d,"save_bytes":%d,"mismatches":%d,"zones":%s}}`,
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
		zones_json(result.zones),
	)
	return result.mismatches == 0
}
