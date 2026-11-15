package cli

import "core:encoding/json"
import "core:net"
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

// The suite's tool scripts never reach the lobby service, also where .env names the EOS SDK: without the SDK library
// online play fails at once, as on CI (the walk's bad-code join would wait seconds for EOS). `uni coop` is online.
SUITE_OFFLINE_ENV :: []string{"UNIFIED_EOS_SDK=", "UNIFIED_EOS_LIB_DIR="}

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
			if has_session_step(game) {
				start := time.tick_now()
				ticks := state.long ? SESSION_TICKS_LONG : SESSION_TICKS
				ok = pass(game, "session", session_vs_offline(game, ticks, 1), seconds_since(start)) && ok
			} else {
				skip(game, "session", "no extension or no headless binary")
			}
		}
		if want(only, "bake") {
			start := time.tick_now()
			baked := bake_view_index(game, check = true)
			if os.is_directory(join(game.dir, "game", "levels")) {
				baked = bake(game, check = true).ok && baked
			}
			ok = pass(game, "bake", baked, seconds_since(start)) && ok
		}
		Script_Step :: struct {
			step, script: string,
			args:         []string,
			timeout:      f64,
		}
		for script_step in ([]Script_Step{{"validate", "validate", nil, 60}, {"walk", "ui_walk", nil, 90}, {"tour", "tour", {"--quick"}, 60}}) {
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
	// The `session` step's offline binaries share .out/release/ and its box3d library: a child writing it while
	// another's binary holds the library loaded fails on Windows.
	headless: Headless_Builds
	for game in games {
		if has_session_step(game) && (len(only) == 0 || slice.contains(only, "session")) {
			more := start_headless(.release, only = game.name)
			append(&headless.running, ..more.running[:])
		}
	}
	finish_headless(&headless)
	exe := self_exe()
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
			tprint("%d", ticks),
			"--seed",
			tprint("%d", seed),
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
				tprint("%d", ticks),
				"--players",
				"1",
				"--seed",
				tprint("%d", seed),
				"--game",
				game.name,
			),
			capture = true,
			quiet   = true,
			timeout = 120 * time.Second,
		})
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
	result := run_tool({
		dir     = selected.dir,
		script  = script,
		args    = split < len(args) ? args[split + 1:] : nil,
		window  = opts.window,
		shots   = opts.shots ? name : "",
		place   = {opts.mute, opts.screen, true},
		timeout = 1800,
	})
	return {
		ok      = result.ok,
		summary = tprint("%s %s: %s in %.1fs", selected.name, name, result.ok ? "ok" : "FAILED", result.seconds),
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
		crash:  bool `usage:"the joiner's process dies mid-match (no goodbye) and the same player joins again (with --lan, in a new seat): timed"`,
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
		// a free port: two runs at once (parallel agents) never meet in each other's lobby
		append(&extra, "--lan", tprint("--lan-port=%d", free_udp_port()))
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
		return coop_crash(
			selected,
			script,
			&joiner,
			host_args[:],
			opts.lan,
			opts.window,
			{opts.mute, opts.screen, true},
		)
	}
	host := run_tool({
			dir     = selected.dir,
			script  = script,
			args    = host_args[:],
			window  = opts.window,
			shots   = opts.window ? "coop" : "",
			place   = {opts.mute, opts.screen, true},
			timeout = 180,
		})
	joiner_result := wait(&joiner)
	log("uni: the joiner:")
	join := judge_tool(joiner_result, true)
	ok := host.ok && join.ok
	return {
		ok      = ok,
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
		game:  string `args:"pos=0" usage:"a game (default: every game)"`,
		check: bool `usage:"write nothing; fail when the view index or a .level file is stale"`,
	}
	opts: Opts
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
	return {
		ok      = ok,
		summary = tprint("bake%s: %d game(s) %s", opts.check ? " --check" : "", count, ok ? "ok" : "FAILED"),
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
			append(&found, Found{kind, tprint("res://%s", rel_path)})
		}
	}
	slice.sort_by(found[:], proc(a, b: Found) -> bool {return a.kind < b.kind})
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "[gd_resource type=\"Resource\" format=3]\n\n[resource]\nmetadata/views = {\n")
	for item, i in found {
		strings.write_string(&builder, tprint("%q: %q%s\n", item.kind, item.path, i + 1 < len(found) ? "," : ""))
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

// The .tscn files Godot sees in the project at `dir`, sorted: not under a hidden directory, nor one with a .gdignore
// (a game repo's unified/ submodule has one).
godot_scenes :: proc(dir: string) -> []string {
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
		if info.type == .Regular && strings.has_suffix(info.name, ".tscn") {
			append(&out, strings.clone(info.fullpath))
		}
	}
	sort_strings(out[:])
	return out[:]
}

// Runs unified's level exporter (src/level/godot/level_export.gd, copied into <game>/.out/tools/) on the game's
// level scenes (src/level/SPEC.md).
bake :: proc(game: Game, check: bool) -> Tool_Result {
	if has_extension(game) {
		ensure_extension(game, .dev) // the game's scripts name its library's classes
	}
	ensure_imported(game.dir)
	copy_file(
		join(game.dir, ".out", "tools", "level_export.gd"),
		join(state.project.unified, "src", "level", "godot", "level_export.gd"),
	)
	result := run_tool({
			dir     = game.dir,
			script  = "res://.out/tools/level_export.gd",
			args    = check ? strs("--check") : nil,
			timeout = 60,
			quiet   = true,
		})
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

COOP_DEFAULT_TICKS :: 600

// A game without a coop tool script: a host (`--host-port`, 127.0.0.1 only) and a joiner (`--join`), both headless
// with scripted input, for COOP_DEFAULT_TICKS ticks; ok when both finish with the same checksums.
@(private)
coop_default :: proc(game: Game) -> Result {
	ensure_extension(game, .dev)
	ensure_imported(game.dir)
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
		tprint("%d", port),
		"--local-net",
	)
	append(&host_cmd, ..common)
	append(&host_cmd, "--ticks", tprint("%d", COOP_DEFAULT_TICKS))
	append(&join_cmd, godot(), "--headless", "--path", game.dir, "--", "--join", tprint("127.0.0.1:%d", port))
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
		summary = tprint(
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
		summary = tprint(
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
