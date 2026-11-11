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
	for o in only {
		if !slice.contains(GODOT_STEPS, o) {
			usage("no godot step %q (%s)", o, strings.join(GODOT_STEPS, ", "))
		}
	}
	if len(games) > 1 {
		return godot_in_parallel(games, only)
	}
	want :: proc(only: []string, step: string) -> bool {
		return len(only) == 0 || slice.contains(only, step)
	}
	ok := true
	for g in games {
		skip :: proc(g: Game, step, why: string) {
			log("uni: %s %s: skipped: %s", g.name, step, why)
		}
		pass :: proc(g: Game, step: string, passed: bool, secs: f64) -> bool {
			log("uni: %s %s: %s (%.1fs)", g.name, step, passed ? "ok" : "FAILED", secs)
			return passed
		}
		if has_extension(g) {
			ensure_extension(g, .dev)
		}
		if want(only, "import") {
			start := time.tick_now()
			ensure_imported(g.dir)
			pass(g, "import", true, seconds_since(start))
		}
		if want(only, "editor") {
			if has_extension(g) {
				start := time.tick_now()
				ok = pass(g, "editor", editor_check(g), seconds_since(start)) && ok
			} else {
				skip(g, "editor", "no extension")
			}
		}
		if want(only, "session") {
			if has_extension(g) && os.is_directory(join(g.dir, "simulation", "headless")) {
				start := time.tick_now()
				ticks := state.long ? SESSION_TICKS_LONG : SESSION_TICKS
				ok = pass(g, "session", session_vs_offline(g, ticks, 1), seconds_since(start)) && ok
			} else {
				skip(g, "session", "no extension or no headless binary")
			}
		}
		if want(only, "bake") {
			if os.is_directory(join(g.dir, "game", "levels")) {
				r := bake(g, check = true)
				ok = pass(g, "bake", r.ok, r.seconds) && ok
			} else {
				skip(g, "bake", "no game/levels")
			}
		}
		Script_Step :: struct {
			step, script: string,
			args:         []string,
			timeout:      f64,
		}
		for s in ([]Script_Step{{"validate", "validate", nil, 60}, {"walk", "ui_walk", {"--mock"}, 90}, {"tour", "tour", {"--quick"}, 60}}) {
			if !want(only, s.step) {
				continue
			}
			script := tool_script(g, s.script)
			if script == "" {
				skip(g, s.step, tprint("no game/tools/%s.gd", s.script))
				continue
			}
			if s.step == "tour" && !has_extension(g) {
				skip(g, s.step, "the tour needs the game's extension")
				continue
			}
			r := run_tool({dir = g.dir, script = script, args = s.args, timeout = s.timeout, quiet = true})
			ok = pass(g, s.step, r.ok, r.seconds) && ok
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
	for g in games {
		if game_uses_box3d(g) {
			ensure_box3d()
			break
		}
	}
	exe, _ := os.get_executable_path(context.allocator)
	env := env_with(tprint("%s=1", CHILD_ENV))
	runs := make([]Run, len(games))
	for g, i in games {
		cmd: [dynamic]string
		append(&cmd, exe, "test", g.name, "--suite", "godot", "--json")
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
	for r, i in run_all(runs) {
		if text := strings.trim_right_space(r.stderr); text != "" {
			log("%s", text)
		}
		if res, found := last_json_object(r.stdout); found {
			if list, is_list := res["cold"].(json.Array); is_list {
				for c in list {
					if what, is_str := c.(json.String); is_str {
						cold(string(what))
					}
				}
			}
		}
		if !r.ok {
			log("uni: %s: the godot suite FAILED%s", games[i].name, r.timed_out ? " (timed out)" : "")
			ok = false
		}
	}
	return ok
}

// The headless editor loads the game's extension, with no error lines.
@(private)
editor_check :: proc(g: Game) -> bool {
	write_extension_list(g)
	r := run_godot({"--headless", "--editor", "--path", g.dir, "--quit-after", "60"}, 120)
	out := strings.concatenate({r.stdout, r.stderr})
	errs := godot_errors(out)
	loaded := strings.contains(out, "unified: extension initialized (editor)")
	for e in errs {
		log("uni: %s editor: %s", g.name, e)
	}
	if !loaded {
		log("uni: %s editor: the extension did not load", g.name)
	}
	return r.ok && len(errs) == 0 && loaded
}

// A headless Godot session (one player, scripted input) for `ticks`: it must end cleanly, and its checksums must equal
// the offline headless binary's for the same seed and inputs.
@(private)
session_vs_offline :: proc(g: Game, ticks, seed: int) -> bool {
	ensure_imported(g.dir)
	r := run_godot(
		{
			"--headless",
			"--path",
			g.dir,
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
	errs := godot_errors(strings.concatenate({r.stdout, r.stderr}))
	res := last_json_after(r.stdout, "unified: result ")
	obj, has := res.(json.Object)
	if !has {
		log("%s", tail(strings.concatenate({r.stdout, r.stderr}), 4000))
		log("uni: %s session: no result line", g.name)
		return false
	}
	ok := r.ok && len(errs) == 0 && json_int(obj["final_tick"]) == ticks
	for e in errs {
		log("uni: %s session: %s", g.name, e)
	}
	mine := checksums(obj["checksums"])
	ref := offline_checksums(g, ticks, seed)
	compared := 0
	for t, c in ref {
		if m, found := mine[t]; found {
			compared += 1
			if m != c {
				log("uni: %s session: checksum at tick %d is %s, the offline binary's %s", g.name, t, m, c)
				ok = false
			}
		}
	}
	if compared == 0 {
		log("uni: %s session: no checksum to compare with the offline binary", g.name)
		ok = false
	}
	return ok
}

// The checksums the offline headless binary reports for one scripted player (`sim --game <name>`: the variant the
// game itself runs), as {tick: checksum}.
@(private)
offline_checksums :: proc(g: Game, ticks, seed: int) -> map[int]string {
	h := Headless{g.name, join(g.dir, "simulation", "headless"), game_uses_box3d(g)}
	b := headless_build(h, .release)
	if h.box3d {
		ensure_box3d()
		stage_box3d(os.dir(b.out))
	}
	if stale(b) {
		odin_build(b, tprint("building %s's headless binary", g.name))
	}
	r := run_proc(
		{
			cmd = strs(
				b.out,
				"sim",
				"--ticks",
				tprint("%d", ticks),
				"--players",
				"1",
				"--seed",
				tprint("%d", seed),
				"--game",
				g.name,
			),
			capture = true,
			quiet = true,
			timeout = 120 * time.Second,
		},
	)
	lines := strings.split_lines(r.stdout)
	#reverse for line in lines {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "{") {
			continue
		}
		v, err := json.parse_string(l)
		if err != nil {
			continue
		}
		if obj, ok := v.(json.Object); ok {
			if cs := checksums(obj["checksums"]); len(cs) > 0 {
				return cs
			}
			if fc, has := obj["final_checksum"]; has {
				out := make(map[int]string)
				out[ticks] = json_string(fc)
				return out
			}
		}
	}
	log("uni: the offline binary printed no checksums:\n%s", tail(strings.concatenate({r.stdout, r.stderr}), 2000))
	return nil
}

// [[tick, checksum], ...] -> {tick: checksum}
checksums :: proc(v: json.Value) -> map[int]string {
	out := make(map[int]string)
	if arr, ok := v.(json.Array); ok {
		for e in arr {
			if pair, isp := e.(json.Array); isp && len(pair) == 2 {
				out[json_int(pair[0])] = json_string(pair[1])
			}
		}
	}
	return out
}

json_int :: proc(v: json.Value) -> int {
	#partial switch x in v {
	case json.Integer:
		return int(x)
	case json.Float:
		return int(x)
	}
	return -1
}

json_string :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String:
		return x
	case json.Integer:
		return tprint("%d", x)
	case json.Float:
		return tprint("%v", x)
	}
	return ""
}

// The JSON after the last line starting with `prefix`.
last_json_after :: proc(text, prefix: string) -> json.Value {
	lines := strings.split_lines(text)
	#reverse for line in lines {
		if strings.has_prefix(line, prefix) {
			v, err := json.parse_string(strings.trim_space(line[len(prefix):]))
			return err == nil ? v : nil
		}
	}
	return nil
}

// --- run, editor ------------------------------------------------------------------------------------------------

@(private)
cmd_run :: proc(args: []string) -> Result {
	Opts :: struct {
		game:     string `args:"pos=0" usage:"the game (default: the only one)"`,
		mute:     bool `usage:"no sound (Godot's dummy audio driver)"`,
		screen:   string `usage:"the screen the window opens on: Godot's index, left, right or primary"`,
		overflow: [dynamic]string `usage:"after --: the game's own arguments"`,
	}
	opts: Opts
	parse(&opts, args)
	return play(game(opts.game), false, opts.overflow[:], {opts.mute, opts.screen})
}

@(private)
cmd_editor :: proc(args: []string) -> Result {
	Opts :: struct {
		game:   string `args:"pos=0" usage:"the game (default: the only one)"`,
		mute:   bool `usage:"no sound (Godot's dummy audio driver)"`,
		screen: string `usage:"the screen the window opens on: Godot's index, left, right or primary"`,
	}
	opts: Opts
	parse(&opts, args)
	return play(game(opts.game), true, nil, {opts.mute, opts.screen})
}

@(private)
play :: proc(g: Game, editor: bool, extra: []string, place: Window_Opts) -> Result {
	if has_extension(g) {
		ensure_extension(g, .dev)
	}
	write_extension_list(g)
	cmd: [dynamic]string
	append(&cmd, godot())
	append(&cmd, ..window_args(place))
	append(&cmd, "--path", g.dir)
	if editor {
		append(&cmd, "--editor")
	}
	if len(extra) > 0 {
		append(&cmd, "--")
		append(&cmd, ..extra)
	}
	r := run_proc({cmd = cmd[:], interactive = true})
	return {ok = r.ok, summary = tprint("%s exited with %d", editor ? "the editor" : g.name, r.exit_code)}
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
	for a, i in args {
		if a == "--" {
			split = i
			break
		}
	}
	parse(&opts, args[:split])
	pos := opts.overflow[:]
	g: Game
	name: string
	switch len(pos) {
	case 1:
		g, name = game(""), pos[0]
	case 2:
		g, name = game(pos[0]), pos[1]
	case:
		usage("name the script: uni tool [game] <script>")
	}
	script := tool_script(g, name)
	if script == "" {
		usage("%s has no game/tools/%s.gd", g.name, name)
	}
	if opts.shots && !opts.window {
		usage("--shots needs --window")
	}
	if (opts.mute || opts.screen != "") && !opts.window {
		usage("--mute and --screen need --window")
	}
	if has_extension(g) {
		ensure_extension(g, .dev)
	}
	ensure_imported(g.dir)
	if opts.cold {
		clear_shader_cache(g)
	}
	r := run_tool(
		{
			dir = g.dir,
			script = script,
			args = split < len(args) ? args[split + 1:] : nil,
			window = opts.window,
			shots = opts.shots ? name : "",
			place = {opts.mute, opts.screen},
			timeout = 1800,
		},
	)
	return {
		ok = r.ok,
		summary = tprint("%s %s: %s in %.1fs", g.name, name, r.ok ? "ok" : "FAILED", r.seconds),
		data = box(r.result),
	}
}

// Deletes the project's compiled-shader caches, so the next run compiles like a player's first launch: the editor's
// in .godot/ and the one in its Godot user directory (runs read both).
@(private)
clear_shader_cache :: proc(g: Game) {
	remove_tree(join(g.dir, ".godot", "shader_cache"))
	c, _ := config_load(join(g.dir, "project.godot"))
	name, ok := config_get(c, "application", "config/name")
	if ok {
		dir := join(godot_user_dir(), "app_userdata", name, "shader_cache")
		remove_tree(dir)
		log("uni: cleared the shader caches of %s", g.name)
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
// processes running game/tools/coop.gd; the host hands the lobby code over through a file. The joiner is always
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
	g := game(opts.game)
	if tool_script(g, "coop") == "" {
		usage("%s has no game/tools/coop.gd", g.name)
	}
	if !has_extension(g) {
		usage("%s has no extension", g.name)
	}
	ensure_extension(g, .dev)
	ensure_imported(g.dir)
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
	code := join(g.dir, ".out", "coop_code.txt")
	os.remove(code)
	join_args: [dynamic]string
	append(&join_args, "--role=join", "--code-file=res://.out/coop_code.txt")
	append(&join_args, ..extra[:])
	joiner_run := Tool_Run {
		dir     = g.dir,
		script  = "res://game/tools/coop.gd",
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
			log_to = join(g.dir, ".out", "coop_join"),
		},
	)
	host_args: [dynamic]string
	append(&host_args, "--role=host", "--code-file=res://.out/coop_code.txt")
	append(&host_args, ..extra[:])
	if opts.crash {
		return coop_crash(g, &joiner, host_args[:], opts.window, {opts.mute, opts.screen})
	}
	host := run_tool(
		{
			dir = g.dir,
			script = "res://game/tools/coop.gd",
			args = host_args[:],
			window = opts.window,
			shots = opts.window ? "coop" : "",
			place = {opts.mute, opts.screen},
			timeout = 180,
		},
	)
	jr := wait(&joiner)
	log("uni: the joiner:")
	join := judge_tool(jr, true)
	ok := host.ok && join.ok
	return {
		ok = ok,
		summary = tprint("coop %s: host %s, joiner %s", g.name, host.ok ? "ok" : "FAILED", join.ok ? "ok" : "FAILED"),
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
	n := 0
	for g in games_or_all(opts.game) {
		if !os.is_directory(join(g.dir, "game", "levels")) {
			if opts.game != "" {
				usage("%s has no game/levels", g.name)
			}
			continue
		}
		r := bake(g, opts.check)
		ok = ok && r.ok
		n += 1
	}
	return {ok = ok, summary = tprint("bake%s: %d game(s) %s", opts.check ? " --check" : "", n, ok ? "ok" : "FAILED")}
}

// Runs unified's level exporter (src/level/godot/level_export.gd, copied into <game>/.out/tools/) on the game's
// level scenes (src/level/SPEC.md).
bake :: proc(g: Game, check: bool) -> Tool_Result {
	ensure_imported(g.dir)
	copy_file(
		join(g.dir, ".out", "tools", "level_export.gd"),
		join(state.project.unified, "src", "level", "godot", "level_export.gd"),
	)
	r := run_tool(
		{
			dir = g.dir,
			script = "res://.out/tools/level_export.gd",
			args = check ? strs("--check") : nil,
			timeout = 60,
			quiet = true,
		},
	)
	if obj, ok := r.result.(json.Object); ok {
		if levels, isa := obj["levels"].(json.Array); isa {
			for lv in levels {
				if l, iso := lv.(json.Object); iso {
					changed, _ := l["changed"].(json.Boolean)
					log(
						"uni: %s -> %s (%d bytes%s)",
						json_string(l["scene"]),
						json_string(l["level"]),
						json_int(l["bytes"]),
						changed ? ", changed" : "",
					)
				}
			}
		}
	}
	return r
}

// `coop --crash`: the host runs alongside; the first joiner kills itself mid-match; then a second joiner with the
// same EOS identity (no fresh device: the first one's) enters the same code. Both coop.gd sides report the times.
@(private)
coop_crash :: proc(g: Game, joiner: ^Proc, host_args: []string, window: bool, place: Window_Opts) -> Result {
	host_run := Tool_Run {
		dir    = g.dir,
		script = "res://game/tools/coop.gd",
		args   = host_args,
		window = window,
		shots  = window ? "coop" : "",
		place  = place,
	}
	host := start(
		{
			cmd = tool_cmd(host_run),
			capture = true,
			timeout = 300 * time.Second,
			log_to = join(g.dir, ".out", "coop_host"),
		},
	)
	first := wait(joiner)
	log("uni: the first joiner (it kills itself mid-match):")
	out := strings.concatenate({first.stdout, first.stderr})
	for line in strings.split_lines(out) do if strings.contains(line, " ok ") || strings.contains(line, "FAIL") do log("%s", line)
	crashed := strings.contains(out, "crashing (the process kills itself")
	second_run := Tool_Run {
		dir    = g.dir,
		script = "res://game/tools/coop.gd",
		args   = {"--role=join", "--code-file=res://.out/coop_code.txt", "--after-crash"},
		env    = env_with("USER=Friend", "USERNAME=Friend"), // the first joiner's device ID: the same player
	}
	second := start(
		{
			cmd = tool_cmd(second_run),
			capture = true,
			timeout = 240 * time.Second,
			env = second_run.env,
			log_to = join(g.dir, ".out", "coop_rejoin"),
		},
	)
	log("uni: the host:")
	h := judge_tool(wait(&host), true)
	log("uni: the same player again:")
	j := judge_tool(wait(&second), true)
	ok := crashed && h.ok && j.ok
	return {
		ok = ok,
		summary = tprint(
			"coop %s --crash: host %s, first joiner %s, the same player again %s",
			g.name,
			h.ok ? "ok" : "FAILED",
			crashed ? "crashed as planned" : "DID NOT CRASH",
			j.ok ? "ok" : "FAILED",
		),
	}
}
