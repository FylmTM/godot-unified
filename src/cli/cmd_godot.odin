package cli

import "core:encoding/json"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The godot suite and the commands that run a game in Godot: run, editor, tool, coop, bake.

// The godot suite's steps, in order; each runs when the game has what it needs.
GODOT_STEPS :: []string{"import", "editor", "session", "bake", "validate", "walk"}

// The `session` step's length: 1 s of a 64 Hz game (`test --long`: 4 s).
SESSION_TICKS :: 64
SESSION_TICKS_LONG :: 256

// The suite's tool scripts never reach the lobby service, also where .env names the EOS SDK: without the SDK library
// online play fails at once, as on CI (the walk's bad-code join would wait seconds for EOS). `uni coop` is online.
SUITE_OFFLINE_ENV :: []string{"UNIFIED_EOS_SDK=", "UNIFIED_EOS_LIB_DIR="}

// The godot suite's steps that run in a lane of their own, beside the others (a child `uni test <game> --suite godot
// --only ...`), chosen so the two lanes take about as long. Each tool run passes --no-settings, so the lanes share
// nothing they write but Godot's import cache, current before either starts.
GODOT_LANE_APART :: []string{"editor", "bake"}

// The lanes pay off only with cores to spare: every game already runs in parallel, so two lanes each double the Godot
// processes (no gain measured on CI's 4-core runners; a quarter of the suite's time on 28 threads).
GODOT_LANE_MIN_CORES :: 16

// Each game under headless Godot (SPEC.md, Test suites); several games run in parallel, and on a machine with
// GODOT_LANE_MIN_CORES a game's steps in two lanes (GODOT_LANE_APART beside the rest), once its extension is current
// and its project imported. A step that
// passes or is skipped says so only with --verbose; a failing one always does.
suite_godot :: proc(games: []Game, opts: Test_Options) -> bool {
	only := opts.only
	for step_name in only {
		if !slice.contains(GODOT_STEPS, step_name) {
			usage("no godot step %q (%s)", step_name, strings.join(GODOT_STEPS, ", "))
		}
	}
	if len(games) > 1 {
		return godot_in_parallel(games, opts)
	}
	want :: proc(only: []string, step: string) -> bool {
		return len(only) == 0 || slice.contains(only, step)
	}
	ok := true
	for game in games {
		skip :: proc(game: Game, step, why: string) {
			if state.verbose do log("uni: %s %s: skipped: %s", game.name, step, why)
		}
		pass :: proc(game: Game, step: string, passed: bool, secs: f64) -> bool {
			if !passed || state.verbose do log("uni: %s %s: %s (%.1fs)", game.name, step, passed ? "ok" : "FAILED", secs)
			return passed
		}
		// whatever steps run: each starts Godot on the project, which needs a current class cache
		import_start := time.tick_now()
		ensure_game(game)
		if want(only, "import") {
			pass(game, "import", true, seconds_since(import_start))
		}
		// The lane apart, when this run has steps in both lanes: its steps are skipped here.
		apart, rest: [dynamic]string
		steps := GODOT_STEPS
		for step in steps[1:] {
			if want(only, step) {
				append(slice.contains(GODOT_LANE_APART, step) ? &apart : &rest, step)
			}
		}
		lane: Maybe(Proc)
		if len(apart) > 0 && len(rest) > 0 && os.get_processor_core_count() >= GODOT_LANE_MIN_CORES {
			cmd: [dynamic]string
			append(
				&cmd,
				self_exe(),
				"test",
				game.name,
				"--suite",
				"godot",
				"--json",
				"--only",
				strings.join(apart[:], ","),
			)
			if opts.long {
				append(&cmd, "--long")
			}
			if state.verbose do log("uni: %s: %s beside the other steps", game.name, strings.join(apart[:], ", "))
			lane = start(
				{cmd = cmd[:], dir = state.project.root, capture = true, quiet = true, timeout = 900 * time.Second},
			)
			only = rest[:]
		}
		if want(only, "editor") {
			if has_extension(game) {
				start := time.tick_now()
				ok = pass(game, "editor", editor_check(game), seconds_since(start)) && ok
			} else {
				skip(game, "editor", "no extension")
			}
		}
		if want(only, "session") {
			if has_session_step(game) {
				start := time.tick_now()
				ticks := opts.long ? SESSION_TICKS_LONG : SESSION_TICKS
				ok = pass(game, "session", session_vs_offline(game, ticks, 1), seconds_since(start)) && ok
			} else {
				skip(game, "session", "no extension or no headless binary")
			}
		}
		if want(only, "bake") {
			start := time.tick_now()
			baked := bake_view_index(game, check = true, quiet = !state.verbose)
			if os.is_directory(join(game.dir, "game", "levels")) {
				baked = bake(game, check = true, quiet = !state.verbose).ok && baked
			}
			ok = pass(game, "bake", baked, seconds_since(start)) && ok
		}
		Script_Step :: struct {
			step, script: string,
			args:         []string,
			timeout:      f64,
		}
		for script_step in ([]Script_Step{{"validate", "validate", nil, 60}, {"walk", "ui_walk", nil, 90}}) {
			if !want(only, script_step.step) {
				continue
			}
			script := tool_script(game, script_step.script)
			if script == "" {
				skip(game, script_step.step, aprintf("no %s tool script", script_step.script))
				continue
			}
			result := run_tool({
				dir     = game.dir,
				script  = script,
				args    = script_step.args,
				timeout = script_step.timeout,
				quiet   = true,
				env     = env_with(..SUITE_OFFLINE_ENV),
			})
			ok = pass(game, script_step.step, result.ok, result.seconds) && ok
		}
		if running, apart_lane := lane.?; apart_lane {
			ran := wait(&running)
			child_log(ran.stderr, ran.ok)
			if report, found := last_json_object(ran.stdout); found {
				adopt_cold(report)
			}
			ok = ran.ok && ok
		}
	}
	return ok
}

// The godot suite's `prepare` (run beside other suites) and the first part of godot_in_parallel: what every game's
// run shares, made current before any starts, so they never race on it: Godot, the bindings, Box3D, and the
// `session` step's offline binaries in .out/release/ (a child writing them while another's binary holds the box3d
// library loaded fails on Windows).
godot_prepare :: proc() {
	godot_shared(state.project.games, nil)
}

@(private)
godot_shared :: proc(games: []Game, only: []string) {
	godot()
	ensure_bindings()
	for game in games {
		if game_uses_box3d(game) {
			ensure_box3d()
			break
		}
	}
	headless: Headless_Builds
	for game in games {
		if has_session_step(game) && (len(only) == 0 || slice.contains(only, "session")) {
			more := start_headless(.release, only = game.name)
			append(&headless.running, ..more.running[:])
		}
	}
	finish_headless(&headless)
}

// Every game at once, each in a child `uni test <game> --suite godot` (its log printed when it ends, in game
// order; what it built or fetched makes this run cold too). What the games share is made current here first, so
// the children never race on it.
@(private)
godot_in_parallel :: proc(games: []Game, opts: Test_Options) -> bool {
	only := opts.only
	godot_shared(games, only)
	exe := self_exe()
	runs := make([]Run, len(games))
	for game, i in games {
		cmd: [dynamic]string
		append(&cmd, exe, "test", game.name, "--suite", "godot", "--json")
		if len(only) > 0 {
			append(&cmd, "--only", strings.join(only, ","))
		}
		if opts.long {
			append(&cmd, "--long")
		}
		runs[i] = {
			cmd     = cmd[:],
			dir     = state.project.root,
			capture = true,
			quiet   = true,
			timeout = 900 * time.Second,
		}
	}
	if state.verbose do log("uni: godot: %d games in parallel", len(games))
	ok := true
	for result, i in run_all(runs) {
		child_log(result.stderr, result.ok)
		if report, found := last_json_object(result.stdout); found {
			adopt_cold(report)
		}
		if !result.ok {
			log("uni: %s: the godot suite FAILED%s", games[i].name, result.timed_out ? " (timed out)" : "")
			ok = false
		}
	}
	return ok
}

// Makes the game ready for a Godot run: its extension current (dev) and its project imported. Every command that
// runs the game in Godot starts here (the editor imports by itself: `play`).
ensure_game :: proc(game: Game) {
	if has_extension(game) {
		ensure_extension(game, .dev)
	}
	ensure_imported(game.dir)
}

// Whether the game runs the `session` step: it has an extension and a headless binary to compare with.
@(private)
has_session_step :: proc(game: Game) -> bool {
	return has_extension(game) && os.is_directory(join(game.dir, "simulation", "headless"))
}

// The headless editor loads the game's extension, with no error lines.
@(private)
editor_check :: proc(game: Game) -> bool {
	write_extension_list(game)
	result := run_godot({"--headless", "--editor", "--path", game.dir, "--quit-after", "60"}, 120)
	out := strings.concatenate({result.stdout, result.stderr})
	errs := godot_errors(out)
	loaded := strings.contains(out, "unified: extension initialized (editor)")
	for line in errs {
		log("uni: %s editor: %s", game.name, line)
	}
	if !loaded {
		log("uni: %s editor: the extension did not load", game.name)
	}
	return result.ok && len(errs) == 0 && loaded
}

// A headless Godot session (one player, scripted input) for `ticks`: it must end cleanly, and its checksums must equal
// the offline headless binary's for the same seed and inputs.
@(private)
session_vs_offline :: proc(game: Game, ticks, seed: int) -> bool {
	ensure_imported(game.dir)
	result := run_godot({
			"--headless",
			"--path",
			game.dir,
			"--",
			"--autostart",
			"--scripted",
			"--quit-at-end",
			"--ticks",
			aprintf("%d", ticks),
			"--seed",
			aprintf("%d", seed),
		}, f64(ticks) / 64 + 30)
	errs := godot_errors(strings.concatenate({result.stdout, result.stderr}))
	report := last_json_after(result.stdout, "unified: result ")
	obj, has := report.(json.Object)
	if !has {
		log("%s", tail(strings.concatenate({result.stdout, result.stderr}), 4000))
		log("uni: %s session: no result line", game.name)
		return false
	}
	ok := result.ok && len(errs) == 0 && json_int(obj["final_tick"]) == ticks
	for line in errs {
		log("uni: %s session: %s", game.name, line)
	}
	mine := checksums(obj["checksums"])
	ref := offline_checksums(game, ticks, seed)
	compared := 0
	for tick, expected in ref {
		if actual, found := mine[tick]; found {
			compared += 1
			if actual != expected {
				log(
					"uni: %s session: checksum at tick %d is %s, the offline binary's %s",
					game.name,
					tick,
					actual,
					expected,
				)
				ok = false
			}
		}
	}
	if compared == 0 {
		log("uni: %s session: no checksum to compare with the offline binary", game.name)
		ok = false
	}
	return ok
}

// The checksums the offline headless binary reports for one scripted player (`sim --game <name>`: the variant the
// game itself runs), as {tick: checksum}.
@(private)
offline_checksums :: proc(game: Game, ticks, seed: int) -> map[int]string {
	binary := ensure_headless(
		Headless{game.name, join(game.dir, "simulation", "headless"), game_uses_box3d(game)},
		.release,
	)
	result := run_proc({
			cmd     = strs(
				binary,
				"sim",
				"--ticks",
				aprintf("%d", ticks),
				"--players",
				"1",
				"--seed",
				aprintf("%d", seed),
				"--game",
				game.name,
			),
			capture = true,
			quiet   = true,
			timeout = 120 * time.Second,
		})
	if report, found := last_json_object(result.stdout); found {
		if found_sums := checksums(report["checksums"]); len(found_sums) > 0 {
			return found_sums
		}
		if final_sum, has := report["final_checksum"]; has {
			out := make(map[int]string)
			out[ticks] = json_string(final_sum)
			return out
		}
	}
	log(
		"uni: the offline binary printed no checksums:\n%s",
		tail(strings.concatenate({result.stdout, result.stderr}), 2000),
	)
	return nil
}

// [[tick, checksum], ...] -> {tick: checksum}
checksums :: proc(value: json.Value) -> map[int]string {
	out := make(map[int]string)
	if array, ok := value.(json.Array); ok {
		for entry in array {
			if pair, isp := entry.(json.Array); isp && len(pair) == 2 {
				out[json_int(pair[0])] = json_string(pair[1])
			}
		}
	}
	return out
}

// A JSON number as an int (a float truncated), or -1 when it is missing or not a number: reads the reports Godot
// scripts and headless binaries print.
json_int :: proc(value: json.Value) -> int {
	#partial switch number in value {
	case json.Integer:
		return int(number)
	case json.Float:
		return int(number)
	}
	return -1
}

// A JSON value as a string: a string as is, a number formatted, anything else "". Reads report fields (a
// checksum, a name) that may come as either.
json_string :: proc(value: json.Value) -> string {
	#partial switch inner in value {
	case json.String:
		return inner
	case json.Integer:
		return aprintf("%d", inner)
	case json.Float:
		return aprintf("%v", inner)
	}
	return ""
}

// The JSON after the last line starting with `prefix`.
last_json_after :: proc(text, prefix: string) -> json.Value {
	lines := strings.split_lines(text)
	#reverse for line in lines {
		if strings.has_prefix(line, prefix) {
			value, err := json.parse_string(strings.trim_space(line[len(prefix):]))
			return err == nil ? value : nil
		}
	}
	return nil
}

// --- run, editor ------------------------------------------------------------------------------------------------

@(private)
Run_Opts :: struct {
	game:       string `args:"pos=0" usage:"the game (default: the only one)"`,
	mute:       bool `usage:"no sound (Godot's dummy audio driver)"`,
	screen:     string `hint:"n|left|right|primary" usage:"the screen the window opens on: Godot's index, left, right or primary"`,
	background: bool `usage:"the window never takes focus (a window an agent opens; macOS: uni hands it straight back when Godot takes it)"`,
	overflow:   [dynamic]string `hint:"[-- args]" usage:"after --: the game's own arguments"`,
}

@(private)
cmd_run :: proc(args: []string) -> Result {
	opts: Run_Opts
	parse(&opts, args)
	return play(game(opts.game), false, opts.overflow[:], {opts.mute, opts.screen, opts.background})
}

@(private)
Editor_Opts :: struct {
	game:   string `args:"pos=0" usage:"the game (default: the only one)"`,
	mute:   bool `usage:"no sound (Godot's dummy audio driver)"`,
	screen: string `hint:"n|left|right|primary" usage:"the screen the window opens on: Godot's index, left, right or primary"`,
}

// The editor takes focus: Godot applies no project override to it, so `--background` has no hook there.
cmd_editor :: proc(args: []string) -> Result {
	opts: Editor_Opts
	parse(&opts, args)
	return play(game(opts.game), true, nil, {opts.mute, opts.screen, false})
}

@(private)
play :: proc(game: Game, editor: bool, extra: []string, place: Window_Opts) -> Result {
	if has_extension(game) {
		ensure_extension(game, .dev)
	}
	if editor {
		write_extension_list(game) // the editor imports by itself
	} else {
		ensure_imported(game.dir)
	}
	cleanup := with_window(game.dir, place)
	defer cleanup(game.dir)
	cmd: [dynamic]string
	append(&cmd, godot())
	append(&cmd, ..window_args(place))
	append(&cmd, "--path", game.dir)
	if editor {
		append(&cmd, "--editor")
	}
	if len(extra) > 0 {
		append(&cmd, "--")
		append(&cmd, ..extra)
	}
	result := run_proc({cmd = cmd[:], interactive = true})
	return {
		ok      = result.ok,
		summary = aprintf("%s exited with %d", editor ? "the editor" : game.name, result.exit_code),
	}
}

// --- tool -------------------------------------------------------------------------------------------------------

// How long `uni tool` lets a script run before it kills it: a backstop for a script that waits forever (the
// longest, play_check, runs minutes). A script error doesn't wait for it (tool_details).
TOOL_TIMEOUT :: 1800

// `tool -h`'s details: what fails a run, and how a script error ends it.
@(private)
tool_details :: proc() -> string {
	return aprintf(
		"A run passes with an ok UNIFIED_RESULT line and exit 0, no ERROR line, no leak at exit and no GDScript\n" +
		"warning. Headless runs have Godot's debugger on (-d, which prints the warnings): a script error stops at\n" +
		"its prompt, which quits at once (the run's stdin holds `quit`), so the run ends within seconds with the\n" +
		"error printed. A run still going after %d minutes is killed.",
		TOOL_TIMEOUT / 60,
	)
}

@(private)
Tool_Opts :: struct {
	window:   bool `usage:"in a window: muted, on the leftmost screen, never taking focus (default: headless)"`,
	shots:    bool `usage:"save screenshots to <game>/.out/shots/<script>/ (needs --window)"`,
	cold:     bool `usage:"clear the shader caches first, like a player's first launch"`,
	overflow: [dynamic]string `hint:"[game] <script> [-- args]" usage:"the game (default: the only one) and the script, then after --: the script's arguments"`,
}

@(private)
cmd_tool :: proc(args: []string) -> Result {
	opts: Tool_Opts
	// [game] <script> [-- args]: positionals before --, the script's arguments after it.
	split := len(args)
	for arg, i in args {
		if arg == "--" {
			split = i
			break
		}
	}
	parse(&opts, args[:split])
	pos := opts.overflow[:]
	selected: Game
	name: string
	switch len(pos) {
	case 1:
		selected, name = game(""), pos[0]
	case 2:
		selected, name = game(pos[0]), pos[1]
	case:
		usage("name the script: uni tool [game] <script>")
	}
	script := tool_script(selected, name)
	if script == "" {
		usage("%s has no tool script %s (game/tools/ or games/shared/tools/)", selected.name, name)
	}
	if opts.shots && !opts.window {
		usage("--shots needs --window")
	}
	ensure_game(selected)
	if opts.cold {
		clear_shader_cache(selected)
	}
	result := run_tool({
		dir     = selected.dir,
		script  = script,
		args    = split < len(args) ? args[split + 1:] : nil,
		window  = opts.window,
		shots   = opts.shots ? name : "",
		place   = AGENT_WINDOW,
		timeout = TOOL_TIMEOUT,
	})
	return {
		ok      = result.ok,
		summary = aprintf("%s %s: %s in %.1fs", selected.name, name, result.ok ? "ok" : "FAILED", result.seconds),
		data    = box(result.result),
	}
}

// Deletes the project's compiled-shader caches, so the next run compiles like a player's first launch: the editor's
// in .godot/ and the one in its Godot user directory (runs read both).
@(private)
clear_shader_cache :: proc(game: Game) {
	remove_tree(join(game.dir, ".godot", "shader_cache"))
	config, _ := config_load(join(game.dir, "project.godot"))
	name, ok := config_get(config, "application", "config/name")
	if ok {
		dir := join(godot_user_dir(), "app_userdata", name, "shader_cache")
		remove_tree(dir)
		log("uni: cleared the shader caches of %s", game.name)
	}
}

// Godot's user data directory on this OS.
godot_user_dir :: proc() -> string {
	when ODIN_OS == .Darwin {
		return join(os.get_env("HOME", context.allocator), "Library", "Application Support", "Godot")
	} else when ODIN_OS == .Windows {
		return join(os.get_env("APPDATA", context.allocator), "Godot")
	} else {
		xdg := os.get_env("XDG_DATA_HOME", context.allocator)
		return xdg != "" ? join(xdg, "godot") : join(os.get_env("HOME", context.allocator), ".local", "share", "godot")
	}
}

// --- coop -------------------------------------------------------------------------------------------------------

@(private)
Coop_Opts :: struct {
	game:   string `args:"pos=0" usage:"the game (default: the only one)"`,
	window: bool `usage:"the host in a window (muted, on the leftmost screen, never taking focus), with screenshots"`,
	rejoin: bool `usage:"the joiner leaves mid-match and joins again"`,
	crash:  bool `usage:"the joiner's process dies mid-match (no goodbye) and the same player joins again (by its EOS account, or its LAN token with --lan): timed"`,
	lan:    bool `usage:"direct UDP on 127.0.0.1 instead of EOS"`,
}

// A host (windowed with --window, else headless) and a headless joiner with a fresh EOS device id, as two Godot
// processes running the coop tool script; the host hands the lobby code over through a file. The joiner is always
// reaped, also when the host fails: an orphan would stay connected to EOS.
@(private)
cmd_coop :: proc(args: []string) -> Result {
	opts: Coop_Opts
	parse(&opts, args)
	if opts.crash && opts.rejoin {
		usage("--crash and --rejoin are two different tests")
	}
	selected := game(opts.game)
	if !has_extension(selected) {
		usage("%s has no extension", selected.name)
	}
	script := tool_script(selected, "coop")
	if script == "" {
		// no coop tool script (no menus to drive): unified's default, a host and a joiner over direct UDP
		if !opts.lan || opts.rejoin || opts.crash || opts.window {
			usage(
				"%s has no coop tool script: its default runs with --lan only (a host and a joiner, headless)",
				selected.name,
			)
		}
		return coop_default(selected)
	}
	ensure_game(selected)
	extra: [dynamic]string
	if opts.rejoin {
		append(&extra, "--rejoin")
	}
	if opts.crash {
		append(&extra, "--crash")
	}
	if opts.lan {
		// a free port: two runs at once (parallel agents) never meet in each other's lobby
		append(&extra, "--lan", aprintf("--lan-port=%d", free_udp_port()))
	}
	code := join(selected.dir, ".out", "coop_code.txt")
	os.remove(code)
	join_args: [dynamic]string
	append(&join_args, "--role=join", "--code-file=res://.out/coop_code.txt")
	append(&join_args, ..extra[:])
	joiner_run := Tool_Run {
		dir     = selected.dir,
		script  = script,
		args    = join_args[:],
		timeout = 210,
		env     = env_with("USER=Friend", "USERNAME=Friend", "UNIFIED_EOS_FRESH_DEVICE=1"),
	}
	joiner := start({
		cmd     = tool_cmd(joiner_run),
		capture = true,
		timeout = 210 * time.Second,
		env     = joiner_run.env,
		log_to  = join(selected.dir, ".out", "coop_join"),
	})
	host_args: [dynamic]string
	append(&host_args, "--role=host", "--code-file=res://.out/coop_code.txt")
	append(&host_args, ..extra[:])
	if opts.crash {
		return coop_crash(selected, script, &joiner, host_args[:], opts.lan, opts.window, AGENT_WINDOW)
	}
	host := run_tool({
		dir     = selected.dir,
		script  = script,
		args    = host_args[:],
		window  = opts.window,
		shots   = opts.window ? "coop" : "",
		place   = AGENT_WINDOW,
		timeout = 180,
	})
	joiner_result := wait(&joiner)
	log("uni: the joiner:")
	join := judge_tool(joiner_result, true)
	ok := host.ok && join.ok
	return {
		ok      = ok,
		summary = aprintf(
			"coop %s: host %s, joiner %s",
			selected.name,
			host.ok ? "ok" : "FAILED",
			join.ok ? "ok" : "FAILED",
		),
	}
}

// --- bake -------------------------------------------------------------------------------------------------------

@(private)
Bake_Opts :: struct {
	game:  string `args:"pos=0" usage:"a game (default: every game, then the project's own level scenes)"`,
	check: bool `usage:"write nothing; fail when the view index or a .level file is stale"`,
}

@(private)
cmd_bake :: proc(args: []string) -> Result {
	opts: Bake_Opts
	parse(&opts, args)
	ok := true
	count := 0
	for game in games_or_all(opts.game) {
		ok = bake_view_index(game, opts.check) && ok
		if os.is_directory(join(game.dir, "game", "levels")) {
			ok = bake(game, opts.check).ok && ok
		}
		count += 1
	}
	if opts.game == "" {
		for target in state.config.bake {
			ok = bake_project(join(state.project.root, target.dir), target.scenes, opts.check).ok && ok
		}
	}
	return {
		ok      = ok,
		summary = aprintf(
			"bake%s: %d game(s)%s %s",
			opts.check ? " --check" : "",
			count,
			opts.game == "" && len(state.config.bake) > 0 ? " and the project's own levels" : "",
			ok ? "ok" : "FAILED",
		),
	}
}

VIEW_INDEX :: "unified_index.tres"

// The view index (src/godot/SPEC.md): every scene of the game whose root has a UnifiedView marker as a direct child,
// by the marker's kind, written to <game>/unified_index.tres (committed; `check`: fail when it is stale instead). A
// scene's text is read directly: `[node ... type="UnifiedView" parent="."]` and its `kind = "..."` line. `quiet`:
// say nothing when it is current.
bake_view_index :: proc(game: Game, check: bool, quiet := false) -> bool {
	Found :: struct {
		kind, path: string,
	}
	found: [dynamic]Found
	ok := true
	for file in godot_scenes(game.dir) {
		rel_path := strings.trim_prefix(file[len(game.dir):], "/")
		rel_path, _ = strings.replace_all(strings.trim_prefix(rel_path, "\\"), "\\", "/")
		if strings.has_prefix(rel_path, "addons/") do continue
		text, read := read_text(file)
		if !read do continue
		in_marker := false
		for raw_line in strings.split_lines(text) {
			line := strings.trim_space(raw_line)
			if strings.has_prefix(line, "[") {
				in_marker = strings.has_prefix(line, "[node ") && strings.contains(line, `type="UnifiedView"`)
				if in_marker && !strings.contains(line, `parent="."`) {
					log("uni: %s: a UnifiedView must be a direct child of the scene's root", rel_path)
					ok = false
					in_marker = false
				}
				continue
			}
			if !in_marker || !strings.has_prefix(line, "kind = ") do continue
			kind := strings.trim_prefix(strings.trim_prefix(line, "kind = "), "&")
			kind = strings.trim_suffix(strings.trim_prefix(kind, `"`), `"`)
			if kind == "" {
				log("uni: %s: its UnifiedView has no kind", rel_path)
				ok = false
				continue
			}
			for earlier in found {
				if earlier.kind == kind {
					log("uni: view kind %q is in two scenes: %s and %s", kind, earlier.path, rel_path)
					ok = false
				}
			}
			append(&found, Found{kind, aprintf("res://%s", rel_path)})
		}
	}
	slice.sort_by(found[:], proc(a, b: Found) -> bool {return a.kind < b.kind})
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "[gd_resource type=\"Resource\" format=3]\n\n[resource]\nmetadata/views = {\n")
	for item, i in found {
		strings.write_string(&builder, aprintf("%q: %q%s\n", item.kind, item.path, i + 1 < len(found) ? "," : ""))
	}
	strings.write_string(&builder, "}\n")
	want := strings.to_string(builder)
	path := join(game.dir, VIEW_INDEX)
	have, exists := read_text(path)
	if len(found) == 0 && !exists do return ok
	if exists && have == want {
		if !quiet do log("uni: %s view index: %d kind(s), current", game.name, len(found))
		return ok
	}
	if check {
		log("uni: %s: %s is stale: run `uni bake %s`", game.name, VIEW_INDEX, game.name)
		return false
	}
	write_text(path, want)
	log("uni: %s view index: %d kind(s) -> %s", game.name, len(found), VIEW_INDEX)
	return ok
}

// The .tscn files Godot sees in the project at `dir`, sorted (godot_files).
godot_scenes :: proc(dir: string) -> []string {
	return godot_files(dir, ".tscn")
}

// The files ending in `suffix` that Godot sees in the project at `dir`, sorted: not under a hidden directory, nor one
// with a .gdignore (a game repo's unified/ submodule has one).
godot_files :: proc(dir, suffix: string) -> []string {
	out: [dynamic]string
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type == .Directory {
			if strings.has_prefix(info.name, ".") || os.is_file(join(info.fullpath, ".gdignore")) {
				os.walker_skip_dir(&walker)
			}
			continue
		}
		if info.type == .Regular && strings.has_suffix(info.name, suffix) {
			append(&out, strings.clone(info.fullpath))
		}
	}
	slice.sort(out[:])
	return out[:]
}

// Runs unified's level exporter (src/godot/tools/level_export.gd, mirrored as res://addons/unified/) on the game's
// level scenes (src/level/SPEC.md). `quiet`: name only the levels that changed.
bake :: proc(game: Game, check: bool, quiet := false) -> Tool_Result {
	ensure_game(game) // the game's scripts name its library's classes, and the exporter reads its view_scale
	return bake_project(game.dir, nil, check, quiet)
}

// Runs the level exporter on a Godot project (imported first): `scenes` (res:// paths), or every
// res://game/levels/*.tscn.
bake_project :: proc(dir: string, scenes: []string, check: bool, quiet := false) -> Tool_Result {
	ensure_imported(dir)
	args: [dynamic]string
	if check do append(&args, "--check")
	for scene in scenes do append(&args, aprintf("--scene=%s", scene))
	result := run_tool({
		dir     = dir,
		script  = aprintf("res://%s/level_export.gd", TOOLS_DIR),
		args    = args[:],
		timeout = 60,
		quiet   = true,
	})
	if obj, ok := result.result.(json.Object); ok {
		if levels, isa := obj["levels"].(json.Array); isa {
			for level_value in levels {
				if level, iso := level_value.(json.Object); iso {
					changed, _ := level["changed"].(json.Boolean)
					if quiet && !changed do continue
					log(
						"uni: %s -> %s (%d bytes%s)",
						json_string(level["scene"]),
						json_string(level["level"]),
						json_int(level["bytes"]),
						changed ? ", changed" : "",
					)
				}
			}
		}
	}
	return result
}

COOP_DEFAULT_TICKS :: 600

// A game without a coop tool script: a host (`--host-port`, 127.0.0.1 only) and a joiner (`--join`), both headless
// with scripted input, for COOP_DEFAULT_TICKS ticks; ok when both finish with the same checksums.
@(private)
coop_default :: proc(game: Game) -> Result {
	ensure_game(game)
	port := free_udp_port()
	common := []string{"--scripted", "--quit-at-end", "--no-settings"}
	host_cmd, join_cmd: [dynamic]string
	append(
		&host_cmd,
		godot(),
		"--headless",
		"--path",
		game.dir,
		"--",
		"--host-port",
		aprintf("%d", port),
		"--local-net",
	)
	append(&host_cmd, ..common)
	append(&host_cmd, "--ticks", aprintf("%d", COOP_DEFAULT_TICKS))
	append(&join_cmd, godot(), "--headless", "--path", game.dir, "--", "--join", aprintf("127.0.0.1:%d", port))
	append(&join_cmd, ..common)
	timeout := time.Duration(COOP_DEFAULT_TICKS / 64 + 60) * time.Second
	host := start({
		cmd     = host_cmd[:],
		capture = true,
		timeout = timeout,
		log_to  = join(game.dir, ".out", "coop_host"),
	})
	time.sleep(500 * time.Millisecond) // the host listens before the joiner says hello
	joiner := start({
		cmd     = join_cmd[:],
		capture = true,
		timeout = timeout,
		log_to  = join(game.dir, ".out", "coop_join"),
	})
	host_ran, join_ran := wait(&host), wait(&joiner)
	ok := true
	results: [2]map[int]string
	for ran, i in ([]Ran{host_ran, join_ran}) {
		role := i == 0 ? "host" : "joiner"
		out := strings.concatenate({ran.stdout, ran.stderr})
		for line in godot_errors(out) {
			log("uni: coop %s %s: %s", game.name, role, line)
			ok = false
		}
		report, has := last_json_after(ran.stdout, "unified: result ").(json.Object)
		if !has {
			log("%s", tail(out, 2000))
			log("uni: coop %s %s: no result line", game.name, role)
			ok = false
			continue
		}
		results[i] = checksums(report["checksums"])
		log(
			"uni: coop %s %s: %d checksums, final tick %d",
			game.name,
			role,
			len(results[i]),
			json_int(report["final_tick"]),
		)
	}
	compared := 0
	for tick, host_sum in results[0] {
		if join_sum, found := results[1][tick]; found {
			compared += 1
			if join_sum != host_sum {
				log("uni: coop %s: checksum at tick %d: host %s, joiner %s", game.name, tick, host_sum, join_sum)
				ok = false
			}
		}
	}
	if compared == 0 {
		log("uni: coop %s: no checksum both sides report", game.name)
		ok = false
	}
	return {
		ok      = ok,
		summary = aprintf(
			"coop %s (default, port %d): %d checksums compared, %s",
			game.name,
			port,
			compared,
			ok ? "ok" : "FAILED",
		),
	}
}

// `coop --crash`: the host runs alongside; the first joiner kills itself mid-match; then a second joiner with the
// same EOS identity (no fresh device: the first one's) enters the same code. Both coop.gd sides report the times.
@(private)
coop_crash :: proc(
	game: Game,
	script: string,
	joiner: ^Proc,
	host_args: []string,
	lan: bool,
	window: bool,
	place: Window_Opts,
) -> Result {
	host_run := Tool_Run {
		dir    = game.dir,
		script = script,
		args   = host_args,
		window = window,
		shots  = window ? "coop" : "",
		place  = place,
	}
	cleanup := window ? with_window(game.dir, place) : no_cleanup
	defer cleanup(game.dir)
	host := start({
		cmd     = tool_cmd(host_run),
		capture = true,
		timeout = 300 * time.Second,
		log_to  = join(game.dir, ".out", "coop_host"),
	})
	first := wait(joiner)
	log("uni: the first joiner (it kills itself mid-match):")
	out := strings.concatenate({first.stdout, first.stderr})
	for line in strings.split_lines(out) do if strings.contains(line, " ok ") || strings.contains(line, "FAIL") do log("%s", line)
	crashed := strings.contains(out, "crashing (the process kills itself")
	second_args: [dynamic]string
	append(&second_args, "--role=join", "--code-file=res://.out/coop_code.txt", "--after-crash")
	if lan {
		append(&second_args, "--lan") // it enters the address, as the first joiner did
	}
	second_run := Tool_Run {
		dir    = game.dir,
		script = script,
		args   = second_args[:],
		env    = env_with("USER=Friend", "USERNAME=Friend"), // the first joiner's device ID: the same player
	}
	second := start({
		cmd     = tool_cmd(second_run),
		capture = true,
		timeout = 240 * time.Second,
		env     = second_run.env,
		log_to  = join(game.dir, ".out", "coop_rejoin"),
	})
	log("uni: the host:")
	host_result := judge_tool(wait(&host), true)
	log("uni: the same player again:")
	rejoin_result := judge_tool(wait(&second), true)
	ok := crashed && host_result.ok && rejoin_result.ok
	return {
		ok      = ok,
		summary = aprintf(
			"coop %s --crash: host %s, first joiner %s, the same player again %s",
			game.name,
			host_result.ok ? "ok" : "FAILED",
			crashed ? "crashed as planned" : "DID NOT CRASH",
			rejoin_result.ok ? "ok" : "FAILED",
		),
	}
}

// A UDP port free on 127.0.0.1 right now (the OS picks it).
free_udp_port :: proc() -> int {
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if err != nil {
		fatal("cannot bind a UDP socket: %v", err)
	}
	defer net.close(sock)
	endpoint, endpoint_err := net.bound_endpoint(sock)
	if endpoint_err != nil {
		fatal("cannot read the UDP socket's port: %v", endpoint_err)
	}
	return endpoint.port
}
