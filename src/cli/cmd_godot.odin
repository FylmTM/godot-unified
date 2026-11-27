// The godot suite and the commands that run a game in Godot: run, editor, tool, coop, bake.
package cli

import "core:encoding/json"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The godot suite's steps, in order; each runs when the game has what it needs (GODOT_STEP_CHECKS says what).
GODOT_STEPS :: []string{"import", "editor", "session", "bake", "validate", "walk", "drive", "render"}

// What each of GODOT_STEPS checks, for `uni test -h`.
GODOT_STEP_CHECKS :: []string {
	"the project imports (stale imports only)",
	"the headless editor loads the extension, with no error line",
	"a short headless session (scripted input) computes the offline headless binary's checksums",
	"every .level file is current and every view marker sound (uni bake --check)",
	"every script compiles with warnings as errors and every scene loads; game/tools/validate.gd adds the game's own checks",
	"game/tools/ui_walk.gd, when the game has one: a walk through its menus and flows with real input events, then its play smoke (a game without menus has none: skipped)",
	"the game headless under uni drive, as an agent drives it: status, pause, exact steps, a timed press, state, input, held input values, events, ui, find, eval, a note saved and read back by feedback --instance, a script error named by file:line; then, with a display, in a window: a screenshot and a note with one (games with an extension)",
	"uni render of the game's first replay regression in a window, cut around an event the headless binary lists (--at): PNG frames on its tick, as many as its ticks at the frame rate, a GIF of them that decodes, and P1's view twice side by side whose halves are the single render's frames, within a tolerance (GPU particles) and not a frame out of sync (games with one; skipped with no display, as on CI's Linux)",
}

// The `session` step's length: 1 s of a 64 Hz game (`test --long`: 4 s).
SESSION_TICKS :: 64
SESSION_TICKS_LONG :: 256

// The suite's tool scripts never reach the lobby service, also where .env names the EOS SDK: without the SDK library
// online play fails at once, as on CI (the walk's bad-code join would wait seconds for EOS). `uni coop` is online.
SUITE_OFFLINE_ENV :: []string{"UNIFIED_EOS_SDK=", "UNIFIED_EOS_LIB_DIR="}

// The godot suite's steps that write the project's import cache (.godot/) while they run: they run before the lanes
// split, with nothing else on the project. The headless editor replaces the class cache and the UID cache on every
// start (missing for an instant on Windows): a Godot starting on the project then finds none of its classes, and a
// script whose base class is the game's own stops at `Could not find base class`.
GODOT_STEPS_ALONE :: []string{"import", "editor"}

// The godot suite's steps that run in a lane of their own, beside the others (a child `uni test <game> --suite godot
// --only ...`), chosen so the two lanes take about as long. Each tool run passes --no-settings, so the lanes share
// nothing they write; they only read the import cache, current before either starts (GODOT_STEPS_ALONE).
GODOT_LANE_APART :: []string{"walk"}

// The lanes pay off only with cores to spare: every game already runs in parallel, so two lanes each double the Godot
// processes (no gain measured on CI's 4-core runners; a quarter of the suite's time on 28 threads).
GODOT_LANE_MIN_CORES :: 16

// How a godot suite run of a game runs its steps (godot_plan): `alone` first, one after another, then `apart` in a
// lane of its own beside `rest` (`apart` is empty when the run has no lanes: every step after `alone` is in `rest`).
// Each in GODOT_STEPS order.
Godot_Plan :: struct {
	alone, apart, rest: []string,
}

// The plan of a godot suite run of a game for its `only` steps (empty: all) on a machine with `cores`: the steps of
// GODOT_STEPS_ALONE alone, and lanes when both have steps and there are GODOT_LANE_MIN_CORES. The import is always
// in `alone` (every step starts Godot on the project, which needs it), as it always runs.
godot_plan :: proc(only: []string, cores: int) -> Godot_Plan {
	alone, apart, rest: [dynamic]string
	for step in GODOT_STEPS {
		if step != "import" && len(only) > 0 && !slice.contains(only, step) {
			continue
		}
		if slice.contains(GODOT_STEPS_ALONE, step) {
			append(&alone, step)
		} else if slice.contains(GODOT_LANE_APART, step) {
			append(&apart, step)
		} else {
			append(&rest, step)
		}
	}
	if len(apart) == 0 || len(rest) == 0 || cores < GODOT_LANE_MIN_CORES {
		all: [dynamic]string
		for step in GODOT_STEPS {
			if slice.contains(apart[:], step) || slice.contains(rest[:], step) {
				append(&all, step)
			}
		}
		return {alone[:], nil, all[:]}
	}
	return {alone[:], apart[:], rest[:]}
}

// Each game under headless Godot (README.md, Test suites); several games run in parallel, and on a machine with
// GODOT_LANE_MIN_CORES a game's steps in two lanes (GODOT_LANE_APART beside the rest), once its extension is current
// and the steps that write its import cache have run (godot_plan). A step that passes or is skipped says so only with
// --verbose; a failing one always does, and stops the steps after it in its lane.
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
		// After a failing step the rest stop: they would fail after it (an extension that did not install fails
		// every one, behind errors that follow from it), and take their timeouts doing so.
		halted :: proc(game: Game, ok: bool, step: string) -> bool {
			if !ok do log("uni: %s %s: skipped (a step before it failed)", game.name, step)
			return !ok
		}
		// a whole run starts from no user data: a drive or tool run's save never reaches its session step (user_env)
		if len(only) == 0 do remove_tree(user_base(game.dir))
		// whatever steps run: each starts Godot on the project, which needs a current class cache
		import_start := time.tick_now()
		ensure_game(game)
		if want(only, "import") {
			pass(game, "import", true, seconds_since(import_start))
		}
		plan := godot_plan(only, os.get_processor_core_count())
		// alone: nothing else runs on the project while the editor rewrites its import cache (GODOT_STEPS_ALONE)
		if slice.contains(plan.alone, "editor") {
			if has_extension(game) {
				start := time.tick_now()
				ok = pass(game, "editor", editor_check(game), seconds_since(start)) && ok
			} else {
				skip(game, "editor", "no extension")
			}
		}
		// The lane apart, when this run has one: its steps are skipped here.
		lane: Maybe(Proc)
		if len(plan.apart) > 0 && !halted(game, ok, strings.join(plan.apart, ", ")) {
			cmd: [dynamic]string
			append(&cmd, self_exe(), "test", game.name, "--suite", "godot", "--only", strings.join(plan.apart, ","))
			if opts.long {
				append(&cmd, "--long")
			}
			if state.verbose do log("uni: %s: %s beside the other steps", game.name, strings.join(plan.apart, ", "))
			lane = start({
				cmd     = cmd[:],
				dir     = state.project.root,
				capture = true,
				quiet   = true,
				timeout = 900 * time.Second,
			})
		}
		if slice.contains(plan.rest, "session") && !halted(game, ok, "session") {
			if has_session_step(game) {
				start := time.tick_now()
				ticks := opts.long ? SESSION_TICKS_LONG : SESSION_TICKS
				ok = pass(game, "session", session_vs_offline(game, ticks, 1), seconds_since(start)) && ok
			} else {
				skip(game, "session", "no extension or no headless binary")
			}
		}
		if slice.contains(plan.rest, "bake") && !halted(game, ok, "bake") {
			start := time.tick_now()
			_, baked := view_index(game.dir)
			baked = bake(game, check = true, quiet = !state.verbose).ok && baked
			ok = pass(game, "bake", baked, seconds_since(start)) && ok
		}
		Script_Step :: struct {
			step, script: string,
			args:         []string,
			timeout:      f64,
		}
		for script_step in ([]Script_Step{{"validate", "validate", nil, 60}, {"walk", "ui_walk", nil, 90}}) {
			if !slice.contains(plan.rest, script_step.step) || halted(game, ok, script_step.step) {
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
				env     = user_env(game.dir, ..SUITE_OFFLINE_ENV),
			})
			ok = pass(game, script_step.step, result.ok, result.seconds) && ok
		}
		if slice.contains(plan.rest, "drive") && !halted(game, ok, "drive") {
			if has_extension(game) {
				start := time.tick_now()
				ok = pass(game, "drive", drive_check(game), seconds_since(start)) && ok
			} else {
				skip(game, "drive", "no extension")
			}
		}
		if slice.contains(plan.rest, "render") && !halted(game, ok, "render") {
			start := time.tick_now()
			passed, skipped := render_check(game)
			if skipped != "" {
				skip(game, "render", skipped)
			} else {
				ok = pass(game, "render", passed, seconds_since(start)) && ok
			}
		}
		if running, apart_lane := lane.?; apart_lane {
			ran := wait(&running)
			child_log(ran.stderr, ran.ok)
			ok = ran.ok && ok
		}
	}
	return ok
}

// The godot suite's `prepare` (run beside other suites) and the first part of godot_in_parallel: what every game's
// run shares, made current before any starts, so they never race on it: Godot, the bindings, Box3D, and the
// `session` step's offline binaries in .out/release/ (a child writing them while another's binary holds the box3d
// library loaded fails on Windows).
godot_prepare :: proc(games: []Game, opts: Test_Options) {
	godot_shared(games, opts.only)
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
// order). What the games share is made current here first, so the children never race on it.
@(private)
godot_in_parallel :: proc(games: []Game, opts: Test_Options) -> bool {
	only := opts.only
	godot_shared(games, only)
	exe := self_exe()
	runs := make([]Run, len(games))
	for game, i in games {
		cmd: [dynamic]string
		append(&cmd, exe, "test", game.name, "--suite", "godot")
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

// The headless editor loads the game's extension, with no error lines (with the project's own editor settings:
// editor_env).
@(private)
editor_check :: proc(game: Game) -> bool {
	write_extension_list(game)
	result := run_godot(
		{"--headless", "--editor", "--path", game.dir, "--quit-after", "60"},
		120,
		editor_env(game.dir),
	)
	out := strings.concatenate({result.stdout, result.stderr})
	errs := godot_problems(out)
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
		}, f64(ticks) / 64 + 30, user_env(game.dir))
	errs := godot_problems(strings.concatenate({result.stdout, result.stderr}))
	if not_installed(errs) {
		for line in errs do log("uni: %s session: %s", game.name, line)
		return false
	}
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
	overflow:   [dynamic]string `hint:"[-- args]" after:"--" usage:"after --: the game's own arguments"`,
}

@(private)
cmd_run :: proc(args: []string) -> Result {
	opts: Run_Opts
	parse(&opts, args)
	return play(
		game(opts.game),
		false,
		opts.overflow[:],
		{mute = opts.mute, screen = opts.screen, background = opts.background},
	)
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
	return play(game(opts.game), true, nil, {mute = opts.mute, screen = opts.screen})
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
// longest, tour, runs minutes). A script error doesn't wait for it (tool_details).
TOOL_TIMEOUT :: 1800

// `tool -h`'s details: what fails a run, and how a script error ends it.
@(private)
tool_details :: proc() -> string {
	return aprintf(
		"A run passes with an ok UNIFIED_RESULT line and exit 0, no ERROR line, no leak at exit and no GDScript\n" +
		"warning. Headless runs have Godot's debugger on (-d, which prints the warnings): a script error stops at\n" +
		"its prompt, which quits at once (the run's stdin holds `quit`), so the run ends within seconds with the\n" +
		"error printed, named first among the problems as file:line (a parse error in the script itself crashes\n" +
		"Godot there: its backtrace is left out). A run still going after %d minutes is killed.\n\n" +
		"The result line on stdout ends with what the script added to its result (UnifiedTool.result) as JSON:\n" +
		"`%s`. With --json, the whole UNIFIED_RESULT object\n" +
		"(steps, errors and the script's own keys) is the result's `data`. To read a value out of Godot, a script\n" +
		"puts it in `result`.\n\n" +
		"`-- --frames` logs every frame's time (UnifiedFrameLog, tools_godot/frame_log.gd) and prints its p50, p99\n" +
		"and max; over the drawn frames (a --window run's) the scene process (the main loop's process start to\n" +
		"RenderingServer's frame_pre_draw: scripts, nodes, the view sync) and the render draw (frame_pre_draw to\n" +
		"frame_post_draw); each hitch over 25 ms with its split and tags; and the worst frame after each first\n" +
		"use: `frames: 600, p50 16.7 ms, ..., 1 over 25 ms; drawn 600: process p50 2.1 ms, ..., draw p50 1.3 ms,\n" +
		"...`. Godot's TIME_PROCESS counts the draw as process: the split tells a script's cost from the renderer's.\n\n" +
		"<script> is a name (game/tools/<name>.gd, else unified's) or a .gd file by path, anywhere: a throwaway\n" +
		"script an agent writes to make or change the project's files through Godot's own API (a level scene\n" +
		"saved with ResourceSaver, input actions with ProjectSettings.save()), run without joining the project.\n" +
		"It must extend UnifiedTool (or SceneTree or MainLoop): any other is refused before Godot starts, since\n" +
		"Godot would run the main scene instead.",
		TOOL_TIMEOUT / 60,
		`survivor validate: ok in 0.8s: {"contract":"ok",...}`,
	)
}

@(private)
Tool_Opts :: struct {
	window:   bool `usage:"in a window: muted, in the top-left corner of the leftmost screen, never taking focus (default: headless)"`,
	size:     string `hint:"<WxH>" usage:"--window: its size (default: the project's); bigger than the leftmost screen, it moves just left of every screen (macOS: stays on the leftmost)"`,
	offline:  bool `usage:"no online play, also where .env names the EOS SDK (as the godot suite's runs): a look pass that must not reach EOS"`,
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
	is_path := strings.has_suffix(name, ".gd")
	if is_path && !os.is_file(name) {
		usage("no such file: %s", name)
	}
	script := tool_script(selected, name)
	if script == "" {
		usage(
			"%s has no tool script %s (game/tools/ or unified's tools_godot/, or a .gd file by path)",
			selected.name,
			name,
		)
	}
	library := join(state.project.unified, TOOLS_SOURCE)
	file := script
	if strings.has_prefix(script, "res://" + TOOLS_DIR + "/") {
		file = join(library, script[len("res://" + TOOLS_DIR + "/"):])
	} else if strings.has_prefix(script, "res://") {
		file = join(selected.dir, script[len("res://"):])
	}
	if runs, extends := tool_script_runs(file, selected.dir, library); !runs {
		usage(
			"%s extends %s: a tool script extends UnifiedTool (or SceneTree or MainLoop), else Godot runs the main scene instead",
			name,
			extends == "" ? "nothing" : extends,
		)
	}
	if is_path {
		name = strings.trim_suffix(os.base(name), ".gd") // the result line's and --shots' name
	}
	if opts.shots && !opts.window {
		usage("--shots needs --window")
	}
	if opts.size != "" {
		if !opts.window do usage("--size needs --window")
		size := parse_window_size(opts.size)
		opts.size = aprintf("%dx%d", size.x, size.y)
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
		size    = opts.size,
		place   = AGENT_WINDOW,
		timeout = TOOL_TIMEOUT,
		env     = opts.offline ? user_env(selected.dir, ..SUITE_OFFLINE_ENV) : nil,
	})
	summary := aprintf("%s %s: %s in %.1fs", selected.name, name, result.ok ? "ok" : "FAILED", result.seconds)
	if own := tool_own_result(result.result); own != "" {
		// one line: a long result is cut at a character's start; the whole of it is --json's
		if len(own) > TOOL_RESULT_SHOWN {
			cut := TOOL_RESULT_SHOWN
			for cut > 0 && own[cut] & 0xC0 == 0x80 do cut -= 1
			own = aprintf("%s… (--json for all)", own[:cut])
		}
		summary = aprintf("%s: %s", summary, own)
	} else if !result.ok && len(result.problems) > 0 {
		summary = aprintf("%s: %s", summary, result.problems[0]) // a script error, when there is one, comes first
	}
	return {ok = result.ok, summary = summary, data = box(result.result)}
}

// How much of a script's own result `tool`'s result line shows (bytes of JSON); --json carries all of it.
TOOL_RESULT_SHOWN :: 300

// What the script added to its result (UnifiedTool.result: every key but the base's ok, ms, steps, failed and
// errors) as one line of JSON, keys sorted; "" when it added nothing.
@(private)
tool_own_result :: proc(result: json.Value) -> string {
	BASE :: []string{"ok", "ms", "steps", "failed", "errors"}
	object, is_object := result.(json.Object)
	if !is_object do return ""
	own := make(json.Object, context.temp_allocator)
	for key, value in object {
		if !slice.contains(BASE, key) do own[key] = value
	}
	if len(own) == 0 do return ""
	text, err := json.marshal(own, {sort_maps_by_key = true}, context.temp_allocator)
	return err == nil ? string(text) : ""
}

// Deletes the project's compiled-shader caches, so the next run compiles like a player's first launch: the editor's
// in .godot/ and the one in its Godot user directory (runs read both).
@(private)
clear_shader_cache :: proc(game: Game) {
	remove_tree(join(game.dir, ".godot", "shader_cache"))
	remove_tree(join(game_user_dir(game.dir), "shader_cache"))
	// a check's own (user_env), and each drive instance's (drive_user_base: a directory of .out/user/)
	remove_tree(join(game_user_dir(game.dir, user_base(game.dir)), "shader_cache"))
	entries, _ := os.read_all_directory_by_path(user_base(game.dir), context.allocator)
	for entry in entries {
		if entry.type == .Directory {
			remove_tree(join(game_user_dir(game.dir, drive_user_base(game.dir, entry.name)), "shader_cache"))
		}
	}
	log("uni: cleared the shader caches of %s", game.name)
}

// Godot's user data directory on this OS (where its export templates and every project's app_userdata are): the
// developer's, or under `base` (a run with user_env's: `user_base`).
godot_user_dir :: proc(base := "") -> string {
	return join(os_data_dir(base), ODIN_OS == .Windows || ODIN_OS == .Darwin ? "Godot" : "godot")
}

// The OS's per-user data directory as Godot reads it (OS::get_data_path), or `base` (godot_user_dir's).
os_data_dir :: proc(base := "") -> string {
	if base != "" do return base
	when ODIN_OS == .Darwin {
		return join(os.get_env("HOME", context.allocator), "Library", "Application Support")
	} else when ODIN_OS == .Windows {
		return os.get_env("APPDATA", context.allocator)
	} else {
		xdg := os.get_env("XDG_DATA_HOME", context.allocator)
		return xdg != "" ? xdg : join(os.get_env("HOME", context.allocator), ".local", "share")
	}
}

// --- coop -------------------------------------------------------------------------------------------------------

// `coop`'s options.
Coop_Opts :: struct {
	game:         string `args:"pos=0" usage:"the game (default: the only one)"`,
	window:       bool `usage:"the host in a window (muted, in the top-left corner of the leftmost screen, never taking focus), with screenshots"`,
	rejoin:       bool `usage:"the joiner leaves mid-match and joins again"`,
	crash:        bool `usage:"the joiner's process dies mid-match (no goodbye) and the same player joins again (by its EOS account, or its LAN token with --lan): timed"`,
	lan:          bool `usage:"direct UDP on 127.0.0.1 instead of EOS"`,
	menus:        bool `usage:"no session flags: each side starts through the game's coop script (_start_host, _start_join: its own menus)"`,
	host_profile: string `hint:"<k=v,..>" usage:"the host's Profile (--profile's syntax: role=Runner), over one after --"`,
	join_profile: string `hint:"<k=v,..>" usage:"the joiner's Profile likewise: two players arriving with different choices"`,
	record:       string `hint:"<replay>" usage:"once both sides pass, the host's recording becomes the game's replay regression simulation/tests/replays/<replay>/ (a name: letters, digits, _ and -; these options kept in its coop.args), checked by the game's tests with --bless narrowed to that folder (any other pin that moved refuses it); refused, failed or killed, the folder is put back as it was"`,
	rerecord:     string `hint:"<replay>" usage:"--record <replay> again, with the options in its coop.args (with [game] and --window only; no game: the one whose replay it is)"`,
	overflow:     [dynamic]string `hint:"[-- args]" after:"--" usage:"after --: game arguments for both processes (dev flags such as --lag, --verified-players)"`,
}

// A host (windowed with --window, else headless) and a headless joiner, as two Godot processes running the coop tool
// script (the game's game/tools/coop.gd, else unified's): each side's session starts from its session flags, the
// joiner's once the host has written its lobby code (or address) to a file. Online, the joiner has a fresh EOS
// device id (a second player); --crash starts a second joiner with the first one's. Every joiner is reaped, also
// when the host fails: an orphan would stay connected to EOS.
@(private)
cmd_coop :: proc(args: []string) -> Result {
	opts: Coop_Opts
	parse(&opts, args)
	if opts.rerecord != "" {
		opts = coop_rerecord(opts)
	}
	if opts.crash && opts.rejoin {
		usage("--crash and --rejoin are two different tests")
	}
	if opts.record != "" && !replay_name_ok(opts.record) {
		usage("--record %q: a replay folder's name (letters, digits, _ and -)", opts.record)
	}
	selected := game(opts.game)
	for folder in replay_restore_killed(join(selected.dir, ".out", REPLAY_BACKUPS)) {
		log("uni: put back %s, which a killed coop --record left changed", folder)
	}
	if !has_extension(selected) {
		usage("%s has no extension", selected.name)
	}
	ensure_game(selected)
	script := tool_script(selected, "coop")
	code_path := join(selected.dir, ".out", "coop_code.txt")
	os.remove(code_path)
	os.remove(aprintf("%s.played", code_path))
	common: [dynamic]string
	append(&common, "--code-file=res://.out/coop_code.txt")
	if opts.rejoin do append(&common, "--rejoin")
	if opts.crash do append(&common, "--crash")
	if opts.menus do append(&common, "--menus")
	append(&common, ..opts.overflow[:])
	// --lan: a free port, so two runs at once (parallel agents) never meet in each other's lobby
	port := opts.lan ? free_udp_port() : 0
	host_args: [dynamic]string
	append(&host_args, "--role=host")
	append(&host_args, ..common[:])
	// after the common arguments: a session reads the last --profile, so a role's own wins over one after --
	if opts.host_profile != "" do append(&host_args, "--profile", opts.host_profile)
	if opts.record != "" do append(&host_args, "--record") // its result names its session's recording
	if opts.menus {
		if opts.lan do append(&host_args, "--menu-port", aprintf("%d", port)) // online: the script hosts online
	} else if opts.lan {
		append(&host_args, "--host-port", aprintf("%d", port))
	} else {
		append(&host_args, "--host-online")
	}
	host_run := Tool_Run {
		dir    = selected.dir,
		script = script,
		args   = host_args[:],
		window = opts.window,
		shots  = opts.window ? "coop" : "",
		place  = AGENT_WINDOW,
		env    = user_env(selected.dir), // the joiners share it: each running copy claims its own LAN token
	}
	cleanup := opts.window ? with_window(selected.dir, AGENT_WINDOW) : no_cleanup
	defer cleanup(selected.dir)
	host := start({
		cmd     = tool_cmd(host_run),
		capture = true,
		timeout = 300 * time.Second,
		env     = host_run.env,
		log_to  = join(selected.dir, ".out", "coop_host"),
	})
	code := ""
	for code == "" && !done(&host) && !past_timeout(&host) {
		time.sleep(100 * time.Millisecond)
		code, _ = read_text(code_path)
		code = strings.trim_space(code)
	}
	if code == "" {
		log("uni: the host wrote no lobby code:")
		judge_tool(wait(&host), true)
		return {ok = false, summary = aprintf("coop %s: the host never hosted", selected.name)}
	}
	joiner_args: [dynamic]string
	append(&joiner_args, "--role=join")
	append(&joiner_args, ..common[:])
	if opts.join_profile != "" do append(&joiner_args, "--profile", opts.join_profile)
	if opts.menus {
		append(&joiner_args, "--menu-code", code) // the code, or the LAN address
	} else if opts.lan {
		append(&joiner_args, "--join", code)
	} else {
		append(&joiner_args, "--join-code", code)
	}
	friend := user_env(selected.dir)
	fresh := opts.lan ? friend : user_env(selected.dir, "UNIFIED_EOS_FRESH_DEVICE=1")
	joiner := start_joiner(selected, script, joiner_args[:], fresh, "coop_join")
	if !opts.crash {
		join_ran := wait(&joiner)
		log("uni: the host:")
		host_result := judge_tool(wait(&host), true)
		log("uni: the joiner:")
		join_result := judge_tool(join_ran, true)
		ok := host_result.ok && join_result.ok
		summary := aprintf(
			"coop %s: host %s, joiner %s",
			selected.name,
			host_result.ok ? "ok" : "FAILED",
			join_result.ok ? "ok" : "FAILED",
		)
		return coop_keep(selected, opts, host_result, {ok = ok, summary = summary})
	}
	// --crash: the first joiner kills itself mid-match; then a second one with the same identity (online: no fresh
	// device, the first one's) joins with the same code. Both coop scripts report the times.
	first := wait(&joiner)
	log("uni: the first joiner (it kills itself mid-match):")
	out := strings.concatenate({first.stdout, first.stderr})
	for line in strings.split_lines(out) do if strings.contains(line, " ok ") || strings.contains(line, "FAIL") do log("%s", line)
	crashed := strings.contains(out, "crashing (the process kills itself")
	append(&joiner_args, "--after-crash")
	second := start_joiner(selected, script, joiner_args[:], friend, "coop_rejoin")
	log("uni: the host:")
	host_result := judge_tool(wait(&host), true)
	log("uni: the same player again:")
	rejoin_result := judge_tool(wait(&second), true)
	ok := crashed && host_result.ok && rejoin_result.ok
	summary := aprintf(
		"coop %s --crash: host %s, first joiner %s, the same player again %s",
		selected.name,
		host_result.ok ? "ok" : "FAILED",
		crashed ? "crashed as planned" : "DID NOT CRASH",
		rejoin_result.ok ? "ok" : "FAILED",
	)
	return coop_keep(selected, opts, host_result, {ok = ok, summary = summary})
}

// --rerecord <replay>: the options its folder's coop.args kept (replay_args, coop_saved_opts), with this run's game
// (unnamed: the one whose replay it is, rerecord_game), --window and --record <replay>. Any other option is refused:
// the replay is recorded again the way it was.
@(private)
coop_rerecord :: proc(opts: Coop_Opts) -> Coop_Opts {
	if opts.record != "" ||
	   opts.rejoin ||
	   opts.crash ||
	   opts.lan ||
	   opts.menus ||
	   opts.host_profile != "" ||
	   opts.join_profile != "" ||
	   len(opts.overflow) > 0 {
		usage(
			"--rerecord takes its options from the replay's %s: only [game] and --window beside it",
			REPLAY_ARGS_FILE,
		)
	}
	if !replay_name_ok(opts.rerecord) {
		usage("--rerecord %q: a replay folder's name (letters, digits, _ and -)", opts.rerecord)
	}
	game_name := opts.game
	if game_name == "" do game_name = rerecord_game(state.project.games, opts.rerecord)
	folder := replay_folder(game(game_name).dir, opts.rerecord)
	saved, found := replay_args(folder)
	if !found {
		usage("%s has no %s: record it with --record <replay> and its options first", folder, REPLAY_ARGS_FILE)
	}
	again, problem := coop_saved_opts(saved)
	if problem != "" do usage("%s: %s", join(folder, REPLAY_ARGS_FILE), problem)
	log("uni: coop --rerecord %s: %s", opts.rerecord, strings.join(saved, " "))
	again.game, again.window, again.record = game_name, opts.window, opts.rerecord
	return again
}

// The game `coop --rerecord <replay>` names none of: the only one, or else the only one whose replay folder `replay`
// holds a REPLAY_ARGS_FILE (a failing replay's hint names no game: its test binary holds every game's suite); "" when
// none or several do (`game` then asks for a name).
rerecord_game :: proc(games: []Game, replay: string) -> string {
	if len(games) == 1 do return games[0].name
	found := ""
	for candidate in games {
		if !os.is_file(join(replay_folder(candidate.dir, replay), REPLAY_ARGS_FILE)) do continue
		if found != "" do return ""
		found = candidate.name
	}
	return found
}

// The coop options a replay's coop.args holds (`saved`, as coop_record_args wrote them), or why they aren't a
// recording's: a game, --window, --record or --rerecord among them. A malformed one stops the command (parse), so
// `coop` must be the command running.
coop_saved_opts :: proc(saved: []string) -> (opts: Coop_Opts, problem: string) {
	parse(&opts, saved)
	if opts.record != "" || opts.rerecord != "" || opts.window || opts.game != "" {
		return {}, "a recording's options, without a game, --window, --record or --rerecord"
	}
	return opts, ""
}

// The options of a --record run that recorded what it did, as coop.args keeps them (a line each): what --rerecord
// passes again (coop_saved_opts). Not the game, --window or --record: where and how it was watched, not what was
// played.
coop_record_args :: proc(opts: Coop_Opts) -> []string {
	args: [dynamic]string
	if opts.lan do append(&args, "--lan")
	if opts.menus do append(&args, "--menus")
	if opts.rejoin do append(&args, "--rejoin")
	if opts.crash do append(&args, "--crash")
	if opts.host_profile != "" do append(&args, "--host-profile", opts.host_profile)
	if opts.join_profile != "" do append(&args, "--join-profile", opts.join_profile)
	if len(opts.overflow) > 0 {
		append(&args, "--")
		append(&args, ..opts.overflow[:])
	}
	return args[:]
}

// --record <replay>, once both sides passed (`ran`): the host's session recording (its result's `recording`, which
// UnifiedCoop reports from UnifiedSession.recording) is recorded as the replay folder's and checked by coop_bless
// (replay_record: refused, failed or killed, the folder is put back).
@(private)
coop_keep :: proc(game: Game, opts: Coop_Opts, host: Tool_Result, ran: Result) -> Result {
	if opts.record == "" || !ran.ok do return ran
	recording := ""
	if result, is_object := host.result.(json.Object); is_object {
		recording, _ = result["recording"].(json.String)
	}
	if recording == "" {
		return {
			ok      = false,
			summary = aprintf(
				"coop %s --record: the host reported no recording (UnifiedCoop._host saves it)",
				game.name,
			),
		}
	}
	folder := slashed(replay_folder(game.dir, opts.record))
	backups := join(game.dir, ".out", REPLAY_BACKUPS, opts.record)
	// a fatal in the check (a build that can't start) unwinds: put the folder back (a no-op once replay_record returned)
	on_failure(proc(data: rawptr) {replay_restore((^Replay_Backup)(data)^)}, new_clone(Replay_Backup{folder, backups}))
	recorded := replay_record(game.name, folder, recording, coop_record_args(opts), backups, coop_bless)
	return {
		ok      = recorded.ok,
		summary = aprintf("%s; --record %s: %s", ran.summary, opts.record, recorded.summary),
	}
}

// coop --record's check of a new recording: `test <game> --bless`, narrowed to its folder (BLESS_ONLY_ENV): every
// test runs, the bless writes that folder's expectation alone, and any other pin that moved fails the run.
@(private)
coop_bless :: proc(game, folder: string) -> Result {
	_ = os.set_env(BLESS_ONLY_ENV, folder)
	defer _ = os.unset_env(BLESS_ONLY_ENV)
	log("uni: coop --record: the game's tests check %s (--bless writes that folder alone)", folder)
	test := find_command("test")
	self := state.command
	state.command = test
	checked := test.run({game, "--bless"})
	state.command = self
	return checked
}

// A headless joiner of `uni coop`, its output kept in <game>/.out/<log_name>.
@(private)
start_joiner :: proc(game: Game, script: string, args: []string, env: []string, log_name: string) -> Proc {
	joiner_run := Tool_Run {
		dir    = game.dir,
		script = script,
		args   = args,
		env    = env,
	}
	return start({
		cmd     = tool_cmd(joiner_run),
		capture = true,
		timeout = 240 * time.Second,
		env     = env,
		log_to  = join(game.dir, ".out", log_name),
	})
}

// --- bake -------------------------------------------------------------------------------------------------------

@(private)
Bake_Opts :: struct {
	game:   string `args:"pos=0" usage:"a game (default: every game, then the project's own level scenes)"`,
	check:  bool `usage:"write nothing; fail when a .level file is stale (or a view scene's marker is wrong)"`,
	nav:    bool `usage:"first bake each level's NavigationRegion3D that opts in (metadata unified_nav_bake) with its own settings and save the scene (the editor's Bake NavigationMesh), then export"`,
	report: bool `usage:"then report each exported level's navigation mesh (--check: the committed files): its islands, where each marker is on them, what the export changed (src/navreport/README.md)"`,
}

// `bake -h`'s details: --report's output.
@(private)
bake_details :: proc() -> string {
	return(
		"--report prints each level's navigation report (what it shows and how to read it: src/navreport/README.md)\n" +
		"and never fails the bake. With --json, the result's `data` is {levels: [...]}, a report per level the bake\n" +
		"exported." \
	)
}

@(private)
cmd_bake :: proc(args: []string) -> Result {
	opts: Bake_Opts
	parse(&opts, args)
	if opts.nav && opts.check do fatal("uni bake: --nav writes the scenes, --check writes nothing: one at a time")
	ok := true
	count := 0
	reports: [dynamic]json.Value
	for game in games_or_all(opts.game) {
		_, markers_ok := view_index(game.dir) // built into the extension: only its markers are checked here
		ok = markers_ok && ok
		if opts.nav && len(level_scenes(game.dir)) > 0 {
			ensure_game(game)
			ok = bake_nav(game.dir, level_scenes(game.dir)) && ok
		}
		baked := bake(game, opts.check)
		ok = baked.ok && ok
		if opts.report do ok = report_nav(game.dir, baked, &reports) && ok
		count += 1
	}
	if opts.game == "" {
		for target in state.config.bake {
			dir := join(state.project.root, target.dir)
			if target.extension != "" {
				ensure_project_extension(dir, join(state.project.root, target.extension), target.library)
			}
			if opts.nav do ok = bake_nav(dir, target.scenes) && ok
			baked := bake_project(dir, target.scenes, opts.check)
			ok = baked.ok && ok
			if opts.report do ok = report_nav(dir, baked, &reports) && ok
		}
	}
	Report_Data :: struct {
		levels: []json.Value,
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
		data    = opts.report ? box(Report_Data{reports[:]}) : nil,
	}
}

// `bake --report`: runs the navigation report (src/navreport, built from the unified checkout) on the levels a bake of
// the project at `dir` exported (`baked`, the exporter's result), with what the export changed in each one's bake;
// logs its text and appends each level's report (JSON) to `reports`. False: the report could not run.
@(private)
report_nav :: proc(dir: string, baked: Tool_Result, reports: ^[dynamic]json.Value) -> bool {
	result, is_object := baked.result.(json.Object)
	if !is_object do return true // nothing exported (no level scenes), or the exporter failed: it said why
	exported, _ := result["levels"].(json.Array)
	if len(exported) == 0 do return true
	build := headless_build(Headless{"navreport", join(state.project.unified, "src", "navreport"), false}, .dev)
	if stale(build) do odin_build(build, "building the navigation report (src/navreport)")
	cmd: [dynamic]string
	append(&cmd, build.out)
	for value in exported {
		level, _ := value.(json.Object)
		if changes, has_changes := level["nav"].(json.Object); has_changes {
			max_lowered: f64
			#partial switch number in changes["max_lowered"] {
			case json.Float:
				max_lowered = f64(number)
			case json.Integer:
				max_lowered = f64(number)
			}
			append(&cmd, aprintf("--export=%.4f,%d", max_lowered, json_int(changes["inside_solids"])))
		}
		file := rel(join(dir, strings.trim_prefix(json_string(level["level"]), "res://")))
		file = slashed(file)
		append(&cmd, file)
	}
	ran := run_proc({cmd = cmd[:], dir = state.project.root, capture = true, quiet = true, timeout = 60 * time.Second})
	line, found := last_json_line(ran.stdout)
	parsed, _ := json.parse_string(line, parse_integers = true)
	output, _ := parsed.(json.Object)
	levels, _ := output["levels"].(json.Array)
	if !ran.ok || !found {
		log(
			"uni: the navigation report failed (exit %d):\n%s",
			ran.exit_code,
			tail(strings.concatenate({ran.stdout, ran.stderr}), 2000),
		)
		return false
	}
	text := strings.trim_right_space(ran.stdout[:strings.last_index(ran.stdout, line)])
	if text != "" do log("%s\n", text)
	append(reports, ..levels[:])
	return true
}

// The -define the extension build passes the view index in (src/godot/README.md, The view index): `kind=res://path`
// entries joined by `;`, sorted by kind.
VIEW_INDEX_DEFINE :: "UNIFIED_VIEW_INDEX"

// The view index of the project at `dir` (src/godot/README.md, The view index): every scene whose root has a
// UnifiedView marker as a direct child, by the marker's kind, as VIEW_INDEX_DEFINE's value ("" when there is none). A
// scene's text is read directly: `[node ... type="UnifiedView" parent="."]` and its `kind = "..."` line. ok is false,
// each problem logged, when a marker is not a direct child of its root, has no kind, shares its kind with another
// scene, or a kind or path holds a `;` or `=`.
view_index :: proc(dir: string) -> (index: string, ok: bool) {
	Found :: struct {
		kind, path: string,
	}
	found: [dynamic]Found
	ok = true
	for file in godot_scenes(dir) {
		rel_path := strings.trim_prefix(file[len(dir):], "/")
		rel_path = slashed(strings.trim_prefix(rel_path, "\\"))
		if strings.has_prefix(rel_path, "addons/") || strings.has_prefix(rel_path, "unified/") do continue
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
			if strings.contains_any(kind, ";=") || strings.contains_any(rel_path, ";=") {
				log("uni: %s: a view scene's path and kind hold no ';' or '=' (the view index's separators)", rel_path)
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
	entries := make([]string, len(found))
	for item, i in found do entries[i] = aprintf("%s=%s", item.kind, item.path)
	return strings.join(entries, ";"), ok
}

// The extension build's flags that pass it the view index of the project at `dir` (view_index): its -define, or none
// when the project has no view scenes (Odin rejects an empty value; src/godot's default is the empty index). A bad
// marker stops the command, naming it.
view_index_defines :: proc(dir: string) -> []string {
	index, ok := view_index(dir)
	if !ok do fatal("%s: its view scenes' markers are wrong (above)", rel(dir))
	if index == "" do return nil
	return strs(aprintf("-define:%s=%s", VIEW_INDEX_DEFINE, index))
}

// The .tscn files Godot sees in the project at `dir`, sorted (godot_files).
godot_scenes :: proc(dir: string) -> []string {
	return godot_files(dir, ".tscn")
}

// The files ending in `suffix` that Godot sees in the project at `dir`, sorted: not under a hidden directory, nor one
// with a .gdignore (a game repo's unified/ submodule has one). Each path is `dir` as given joined with the file's path
// in the project, so callers cut `dir` off to get it: a directory walker may return resolved paths (macOS: /var is
// /private/var), which don't start with it.
godot_files :: proc(dir, suffix: string) -> []string {
	walk :: proc(out: ^[dynamic]string, dir, suffix: string) {
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for entry in entries {
			path := join(dir, entry.name)
			if entry.type == .Directory {
				if !strings.has_prefix(entry.name, ".") && !os.is_file(join(path, ".gdignore")) do walk(out, path, suffix)
			} else if entry.type == .Regular && strings.has_suffix(entry.name, suffix) {
				append(out, path)
			}
		}
	}
	out: [dynamic]string
	walk(&out, dir, suffix)
	slice.sort(out[:])
	return out[:]
}

// Runs unified's level exporter (tools_godot/level_export.gd, at res://unified/tools_godot/) on the game's
// level scenes (level_scenes; none: nothing to do). `quiet`: name only the levels that changed.
bake :: proc(game: Game, check: bool, quiet := false) -> Tool_Result {
	scenes := level_scenes(game.dir)
	if len(scenes) == 0 do return {ok = true}
	if !check do level_placeholders(game.dir, scenes)
	ensure_game(game) // the game's scripts name its library's classes, and the exporter reads its view_scale
	return bake_project(game.dir, scenes, check, quiet)
}

// The `.level` format version empty_level writes: level.VERSION (tests/cli loads empty_level with unified:level, so
// a bump there fails until this follows).
LEVEL_FORMAT_VERSION :: 1

// A valid level with nothing in it (no bodies, markers or navigation; 3D): what a level scene's `.level` holds before
// its first bake (level_placeholders).
empty_level :: proc() -> []u8 {
	out: [dynamic]u8
	u16_le :: proc(out: ^[dynamic]u8, value: u16) {append(out, u8(value), u8(value >> 8))}
	u32_le :: proc(out: ^[dynamic]u8, value: u32) {for i in uint(0) ..< 4 do append(out, u8(value >> (8 * i)))}
	append(&out, "UNLV")
	u16_le(&out, LEVEL_FORMAT_VERSION)
	u32_le(&out, 0) // px_per_m 0.0: a 3D level
	u32_le(&out, 1) // the strings: "" alone
	u16_le(&out, 0)
	u32_le(&out, 0) // the scene: ""
	u32_le(&out, 0) // no bodies
	u32_le(&out, 0) // no markers
	for _ in 0 ..< 3 do u32_le(&out, 0) // the navigation agent: radius, height, max climb 0.0
	u32_le(&out, 0) // no navigation vertices
	u32_le(&out, 0) // nor polygons
	return out[:]
}

// Writes an empty `.level` (empty_level) beside each level scene (res:// paths) that has none yet: a game's sim
// embeds its levels (`#load`), so its extension, which the exporter needs, builds only once they exist; the bake
// then replaces them.
level_placeholders :: proc(dir: string, scenes: []string) {
	for scene in scenes {
		path := join(dir, aprintf("%s.level", strings.trim_suffix(strings.trim_prefix(scene, "res://"), ".tscn")))
		if os.exists(path) do continue
		if !write_file(path, empty_level()) do fatal("cannot write %s", path)
		log("uni: %s has no .level yet: an empty one, so the extension builds (the bake replaces it)", scene)
	}
}

// A game's level scenes (src/level/README.md), as res:// paths: every scene in game/levels/ (where a new level goes),
// and any other scene with its baked .level beside it (committed with it), wherever the game keeps it.
level_scenes :: proc(dir: string) -> []string {
	out: [dynamic]string
	for file in godot_scenes(dir) {
		rel_path := strings.trim_prefix(file[len(dir):], "/")
		rel_path = slashed(strings.trim_prefix(rel_path, "\\"))
		if strings.has_prefix(rel_path, "addons/") || strings.has_prefix(rel_path, "unified/") do continue
		in_levels := strings.has_prefix(rel_path, "game/levels/") && strings.count(rel_path, "/") == 2
		if in_levels || os.is_file(aprintf("%s.level", strings.trim_suffix(file, ".tscn"))) {
			append(&out, aprintf("res://%s", rel_path))
		}
	}
	return out[:]
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

// Runs unified's navigation baker (tools_godot/nav_bake.gd) on a project's level scenes (res:// paths): each one
// whose NavigationRegion3D opts in is baked with the region's own settings and saved, as the editor's Bake
// NavigationMesh button does.
bake_nav :: proc(dir: string, scenes: []string) -> bool {
	ensure_imported(dir)
	args: [dynamic]string
	for scene in scenes do append(&args, aprintf("--scene=%s", scene))
	result := run_tool({
		dir     = dir,
		script  = aprintf("res://%s/nav_bake.gd", TOOLS_DIR),
		args    = args[:],
		timeout = 120,
		quiet   = true,
	})
	if obj, is_object := result.result.(json.Object); is_object {
		if baked, is_array := obj["scenes"].(json.Array); is_array {
			for value in baked {
				scene, is_scene := value.(json.Object)
				if !is_scene do continue
				log(
					"uni: %s: navigation baked (%d polygons, %d vertices)",
					json_string(scene["scene"]),
					json_int(scene["polygons"]),
					json_int(scene["vertices"]),
				)
			}
		}
	}
	return result.ok
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
