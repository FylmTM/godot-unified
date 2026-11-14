package cli

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The godot suite and the commands that run a game in Godot: run, editor, tool, coop, bake.

// The godot suite's steps, in order; each runs when the game has what it needs.
GODOT_STEPS :: []string{"import", "editor", "session", "bake", "validate", "walk", "tour"}

// The `session` step's length: 1 s of a 64 Hz game (`test --long`: 4 s).
SESSION_TICKS :: 64
SESSION_TICKS_LONG :: 256

// Each game under headless Godot (SPEC.md, Test suites); several games run in parallel.
suite_godot :: proc(games: []Game, only: []string) -> bool {
	for step_name in only {
		if !slice.contains(GODOT_STEPS, step_name) {
			usage("no godot step %q (%s)", step_name, strings.join(GODOT_STEPS, ", "))
		}
	}
	if len(games) > 1 {
		return godot_in_parallel(games, only)
	}
	want :: proc(only: []string, step: string) -> bool {
		return len(only) == 0 || slice.contains(only, step)
	}
	ok := true
	for game in games {
		skip :: proc(game: Game, step, why: string) {
			log("uni: %s %s: skipped: %s", game.name, step, why)
		}
		pass :: proc(game: Game, step: string, passed: bool, secs: f64) -> bool {
			log("uni: %s %s: %s (%.1fs)", game.name, step, passed ? "ok" : "FAILED", secs)
			return passed
		}
		if has_extension(game) {
			ensure_extension(game, .dev)
		}
		// whatever steps run: each starts Godot on the project, which needs a current class cache
		import_start := time.tick_now()
		ensure_imported(game.dir)
		if want(only, "import") {
			pass(game, "import", true, seconds_since(import_start))
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
			if has_extension(game) && os.is_directory(join(game.dir, "simulation", "headless")) {
				start := time.tick_now()
				ticks := state.long ? SESSION_TICKS_LONG : SESSION_TICKS
				ok = pass(game, "session", session_vs_offline(game, ticks, 1), seconds_since(start)) && ok
			} else {
				skip(game, "session", "no extension or no headless binary")
			}
		}
		if want(only, "bake") {
			if os.is_directory(join(game.dir, "game", "levels")) {
				result := bake(game, check = true)
				ok = pass(game, "bake", result.ok, result.seconds) && ok
			} else {
				skip(game, "bake", "no game/levels")
			}
		}
		Script_Step :: struct {
			step, script: string,
			args:         []string,
			timeout:      f64,
		}
		for script_step in ([]Script_Step{{"validate", "validate", nil, 60}, {"walk", "ui_walk", {"--mock"}, 90}, {"tour", "tour", {"--quick"}, 60}}) {
			if !want(only, script_step.step) {
				continue
			}
			script := tool_script(game, script_step.script)
			if script == "" {
				skip(game, script_step.step, tprint("no %s tool script", script_step.script))
				continue
			}
			if script_step.step == "tour" && !has_extension(game) {
				skip(game, script_step.step, "the tour needs the game's extension")
				continue
			}
			result := run_tool(
				{
					dir = game.dir,
					script = script,
					args = script_step.args,
					timeout = script_step.timeout,
					quiet = true,
				},
			)
			ok = pass(game, script_step.step, result.ok, result.seconds) && ok
		}
	}
	return ok
}

// Every game at once, each in a child `uni test <game> --suite godot` (its log printed when it ends, in game
// order; what it built or fetched makes this run cold too). What the games share is made current here first, so
// the children never race on it.
@(private)
godot_in_parallel :: proc(games: []Game, only: []string) -> bool {
	godot()
	ensure_bindings()
	for game in games {
		if game_uses_box3d(game) {
			ensure_box3d()
			break
		}
	}
	exe, _ := os.get_executable_path(context.allocator)
	env := env_with(tprint("%s=1", CHILD_ENV))
	runs := make([]Run, len(games))
	for game, i in games {
		cmd: [dynamic]string
		append(&cmd, exe, "test", game.name, "--suite", "godot", "--json")
		if len(only) > 0 {
			append(&cmd, "--only", strings.join(only, ","))
		}
		if state.long {
			append(&cmd, "--long")
		}
		runs[i] = {
			cmd     = cmd[:],
			dir     = state.project.root,
			capture = true,
			quiet   = true,
			env     = env,
			timeout = 900 * time.Second,
		}
	}
	log("uni: godot: %d games in parallel", len(games))
	ok := true
	for result, i in run_all(runs) {
		if text := strings.trim_right_space(result.stderr); text != "" {
			log("%s", text)
		}
		if report, found := last_json_object(result.stdout); found {
			if list, is_list := report["cold"].(json.Array); is_list {
				for item in list {
					if what, is_str := item.(json.String); is_str {
						cold(string(what))
					}
				}
			}
		}
		if !result.ok {
			log("uni: %s: the godot suite FAILED%s", games[i].name, result.timed_out ? " (timed out)" : "")
			ok = false
		}
	}
	return ok
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
	result := run_godot(
		{
			"--headless",
			"--path",
			game.dir,
			"--",
			"--autostart",
			"--scripted",
			"--quit-at-end",
			"--ticks",
			tprint("%d", ticks),
			"--seed",
			tprint("%d", seed),
		},
		f64(ticks) / 64 + 30,
	)
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
	result := run_proc(
		{
			cmd = strs(
				binary,
				"sim",
				"--ticks",
				tprint("%d", ticks),
				"--players",
				"1",
				"--seed",
				tprint("%d", seed),
				"--game",
				game.name,
			),
			capture = true,
			quiet = true,
			timeout = 120 * time.Second,
		},
	)
	lines := strings.split_lines(result.stdout)
	#reverse for line in lines {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "{") {
			continue
		}
		value, err := json.parse_string(trimmed)
		if err != nil {
			continue
		}
		if obj, ok := value.(json.Object); ok {
			if found_sums := checksums(obj["checksums"]); len(found_sums) > 0 {
				return found_sums
			}
			if final_sum, has := obj["final_checksum"]; has {
				out := make(map[int]string)
				out[ticks] = json_string(final_sum)
				return out
			}
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

json_int :: proc(value: json.Value) -> int {
	#partial switch number in value {
	case json.Integer:
		return int(number)
	case json.Float:
		return int(number)
	}
	return -1
}

json_string :: proc(value: json.Value) -> string {
	#partial switch inner in value {
	case json.String:
		return inner
	case json.Integer:
		return tprint("%d", inner)
	case json.Float:
		return tprint("%v", inner)
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
cmd_run :: proc(args: []string) -> Result {
	Opts :: struct {
		game:       string `args:"pos=0" usage:"the game (default: the only one)"`,
		mute:       bool `usage:"no sound (Godot's dummy audio driver)"`,
		screen:     string `usage:"the screen the window opens on: Godot's index, left, right or primary"`,
		background: bool `usage:"the window never takes focus (a window an agent opens)"`,
		overflow:   [dynamic]string `usage:"after --: the game's own arguments"`,
	}
	opts: Opts
	parse(&opts, args)
	return play(game(opts.game), false, opts.overflow[:], {opts.mute, opts.screen, opts.background})
}

@(private)
// The editor takes focus: Godot applies no project override to it, so `--background` has no hook there.
cmd_editor :: proc(args: []string) -> Result {
	Opts :: struct {
		game:   string `args:"pos=0" usage:"the game (default: the only one)"`,
		mute:   bool `usage:"no sound (Godot's dummy audio driver)"`,
		screen: string `usage:"the screen the window opens on: Godot's index, left, right or primary"`,
	}
	opts: Opts
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
	return {ok = result.ok, summary = tprint("%s exited with %d", editor ? "the editor" : game.name, result.exit_code)}
}

// --- tool -------------------------------------------------------------------------------------------------------

@(private)
cmd_tool :: proc(args: []string) -> Result {
	Opts :: struct {
		window:   bool `usage:"in a window (default: headless)"`,
		mute:     bool `usage:"with --window: no sound (Godot's dummy audio driver)"`,
		screen:   string `usage:"with --window: the screen it opens on: Godot's index, left, right or primary"`,
		shots:    bool `usage:"save screenshots to <game>/.out/shots/<script>/ (needs --window)"`,
		cold:     bool `usage:"clear the shader caches first, like a player's first launch"`,
		overflow: [dynamic]string `usage:"[game] <script>, then after --: the script's arguments"`,
	}
	opts: Opts
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
	if (opts.mute || opts.screen != "") && !opts.window {
		usage("--mute and --screen need --window")
	}
	if has_extension(selected) {
		ensure_extension(selected, .dev)
	}
	ensure_imported(selected.dir)
	if opts.cold {
		clear_shader_cache(selected)
	}
	result := run_tool(
		{
			dir = selected.dir,
			script = script,
			args = split < len(args) ? args[split + 1:] : nil,
			window = opts.window,
			shots = opts.shots ? name : "",
			place = {opts.mute, opts.screen, true},
			timeout = 1800,
		},
	)
	return {
		ok = result.ok,
		summary = tprint("%s %s: %s in %.1fs", selected.name, name, result.ok ? "ok" : "FAILED", result.seconds),
		data = box(result.result),
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

// A host (windowed with --window, else headless) and a headless joiner with a fresh EOS device id, as two Godot
// processes running the coop tool script; the host hands the lobby code over through a file. The joiner is always
// reaped, also when the host fails: an orphan would stay connected to EOS.
@(private)
cmd_coop :: proc(args: []string) -> Result {
	Opts :: struct {
		game:   string `args:"pos=0" usage:"the game (default: the only one)"`,
		window: bool `usage:"the host in a window, with screenshots"`,
		mute:   bool `usage:"with --window: no sound (Godot's dummy audio driver)"`,
		screen: string `usage:"with --window: the screen it opens on: Godot's index, left, right or primary"`,
		rejoin: bool `usage:"the joiner leaves mid-match and joins again"`,
		crash:  bool `usage:"the joiner's process dies mid-match (no goodbye) and the same player joins again: timed"`,
		lan:    bool `usage:"direct UDP on 127.0.0.1 instead of EOS"`,
	}
	opts: Opts
	parse(&opts, args)
	if opts.crash && opts.rejoin {
		usage("--crash and --rejoin are two different tests")
	}
	if (opts.mute || opts.screen != "") && !opts.window {
		usage("--mute and --screen need --window")
	}
	selected := game(opts.game)
	script := tool_script(selected, "coop")
	if script == "" {
		usage("%s has no coop tool script", selected.name)
	}
	if !has_extension(selected) {
		usage("%s has no extension", selected.name)
	}
	ensure_extension(selected, .dev)
	ensure_imported(selected.dir)
	extra: [dynamic]string
	if opts.rejoin {
		append(&extra, "--rejoin")
	}
	if opts.crash {
		append(&extra, "--crash")
	}
	if opts.lan {
		append(&extra, "--lan")
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
	joiner := start(
		{
			cmd = tool_cmd(joiner_run),
			capture = true,
			timeout = 210 * time.Second,
			env = joiner_run.env,
			log_to = join(selected.dir, ".out", "coop_join"),
		},
	)
	host_args: [dynamic]string
	append(&host_args, "--role=host", "--code-file=res://.out/coop_code.txt")
	append(&host_args, ..extra[:])
	if opts.crash {
		return coop_crash(selected, script, &joiner, host_args[:], opts.window, {opts.mute, opts.screen, true})
	}
	host := run_tool(
		{
			dir = selected.dir,
			script = script,
			args = host_args[:],
			window = opts.window,
			shots = opts.window ? "coop" : "",
			place = {opts.mute, opts.screen, true},
			timeout = 180,
		},
	)
	joiner_result := wait(&joiner)
	log("uni: the joiner:")
	join := judge_tool(joiner_result, true)
	ok := host.ok && join.ok
	return {
		ok = ok,
		summary = tprint(
			"coop %s: host %s, joiner %s",
			selected.name,
			host.ok ? "ok" : "FAILED",
			join.ok ? "ok" : "FAILED",
		),
	}
}

// --- bake -------------------------------------------------------------------------------------------------------

@(private)
cmd_bake :: proc(args: []string) -> Result {
	Opts :: struct {
		game:  string `args:"pos=0" usage:"a game (default: every game with game/levels)"`,
		check: bool `usage:"write nothing; fail when a .level file is stale"`,
	}
	opts: Opts
	parse(&opts, args)
	ok := true
	count := 0
	for game in games_or_all(opts.game) {
		if !os.is_directory(join(game.dir, "game", "levels")) {
			if opts.game != "" {
				usage("%s has no game/levels", game.name)
			}
			continue
		}
		result := bake(game, opts.check)
		ok = ok && result.ok
		count += 1
	}
	return {
		ok = ok,
		summary = tprint("bake%s: %d game(s) %s", opts.check ? " --check" : "", count, ok ? "ok" : "FAILED"),
	}
}

// Runs unified's level exporter (src/level/godot/level_export.gd, copied into <game>/.out/tools/) on the game's
// level scenes (src/level/SPEC.md).
bake :: proc(game: Game, check: bool) -> Tool_Result {
	ensure_imported(game.dir)
	copy_file(
		join(game.dir, ".out", "tools", "level_export.gd"),
		join(state.project.unified, "src", "level", "godot", "level_export.gd"),
	)
	result := run_tool(
		{
			dir = game.dir,
			script = "res://.out/tools/level_export.gd",
			args = check ? strs("--check") : nil,
			timeout = 60,
			quiet = true,
		},
	)
	if obj, ok := result.result.(json.Object); ok {
		if levels, isa := obj["levels"].(json.Array); isa {
			for level_value in levels {
				if level, iso := level_value.(json.Object); iso {
					changed, _ := level["changed"].(json.Boolean)
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

// `coop --crash`: the host runs alongside; the first joiner kills itself mid-match; then a second joiner with the
// same EOS identity (no fresh device: the first one's) enters the same code. Both coop.gd sides report the times.
@(private)
coop_crash :: proc(
	game: Game,
	script: string,
	joiner: ^Proc,
	host_args: []string,
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
	host := start(
		{
			cmd = tool_cmd(host_run),
			capture = true,
			timeout = 300 * time.Second,
			log_to = join(game.dir, ".out", "coop_host"),
		},
	)
	first := wait(joiner)
	log("uni: the first joiner (it kills itself mid-match):")
	out := strings.concatenate({first.stdout, first.stderr})
	for line in strings.split_lines(out) do if strings.contains(line, " ok ") || strings.contains(line, "FAIL") do log("%s", line)
	crashed := strings.contains(out, "crashing (the process kills itself")
	second_run := Tool_Run {
		dir    = game.dir,
		script = script,
		args   = {"--role=join", "--code-file=res://.out/coop_code.txt", "--after-crash"},
		env    = env_with("USER=Friend", "USERNAME=Friend"), // the first joiner's device ID: the same player
	}
	second := start(
		{
			cmd = tool_cmd(second_run),
			capture = true,
			timeout = 240 * time.Second,
			env = second_run.env,
			log_to = join(game.dir, ".out", "coop_rejoin"),
		},
	)
	log("uni: the host:")
	host_result := judge_tool(wait(&host), true)
	log("uni: the same player again:")
	rejoin_result := judge_tool(wait(&second), true)
	ok := crashed && host_result.ok && rejoin_result.ok
	return {
		ok = ok,
		summary = tprint(
			"coop %s --crash: host %s, first joiner %s, the same player again %s",
			game.name,
			host_result.ok ? "ok" : "FAILED",
			crashed ? "crashed as planned" : "DID NOT CRASH",
			rejoin_result.ok ? "ok" : "FAILED",
		),
	}
}
