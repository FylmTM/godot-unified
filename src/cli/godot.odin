// Godot: the pinned editor, the import cache, and running a game's tool scripts strictly (README.md, Tool scripts).
package cli

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// The pinned editor: UNIFIED_GODOT when it names an install that reports exactly the pinned version (checked once
// per file: its path, size and time), else the official build downloaded (hash-checked) into the per-user cache
// (user_cache), shared by every checkout: one download per machine, and one path for the OS to know it by (Windows
// Firewall remembers programs by path).
godot :: proc() -> string {
	@(static) cached: string
	if cached != "" {
		return cached
	}
	version := pin("godot", "version")
	want := aprintf("%s.stable.official", version)
	if path := os.get_env("UNIFIED_GODOT", context.allocator); path != "" {
		// `--version` costs a Godot start: remember the answer for this exact file.
		check := join(state.project.out, "godot", "unified_godot.checked")
		id := file_identity(path)
		if !stamp_ok(check, id) {
			got := godot_version(path)
			if !strings.has_prefix(got, want) {
				fatal("UNIFIED_GODOT=%s reports %q; the pin is %s", path, got, want)
			}
			write_text(check, aprintf("%s\n", id))
		}
		cached = path
		return path
	}
	dir, exe, asset, sha256 := godot_download()
	if !os.is_file(exe) {
		// Unpacked beside its final place and renamed into it: another checkout may be fetching it at the same time
		// (the first rename wins), and a half-unpacked editor never sits at the final path.
		tmp := aprintf("%s.%d.tmp", dir, os.get_pid())
		remove_tree(tmp)
		zip := join(tmp, asset)
		download(
			aprintf("https://github.com/godotengine/godot/releases/download/%s-stable/%s", version, asset),
			zip,
			sha256,
			asset,
		)
		archive := zip_open_file(zip)
		zip_extract_all(&archive, tmp)
		os.remove(zip)
		tmp_exe := join(tmp, exe[len(dir) + 1:])
		os.change_mode(tmp_exe, os.perm_number(0o755))
		if got := godot_version(tmp_exe); !strings.has_prefix(got, want) {
			fatal("the downloaded Godot reports %q, want %s", got, want)
		}
		rename_into_place(tmp, dir, exe)
	}
	cached = exe
	return exe
}

// Where the pinned editor goes in the per-user cache (a directory per version and SHA-256, so a re-published
// asset never mixes with the old one), the editor executable in it, its release asset and pinned hash.
godot_download :: proc() -> (dir, exe, asset, sha256: string) {
	version := pin("godot", "version")
	tag := aprintf("%s-stable", version)
	when ODIN_OS == .Darwin {
		sha256 = pin("godot", "sha256_macos")
		asset = aprintf("Godot_v%s_macos.universal.zip", tag)
	} else when ODIN_OS == .Windows {
		sha256 = pin("godot", "sha256_windows")
		asset = aprintf("Godot_v%s_win64.exe.zip", tag)
	} else {
		sha256 = pin("godot", "sha256_linux")
		asset = aprintf("Godot_v%s_linux.x86_64.zip", tag)
	}
	dir = join(user_cache(), "godot", aprintf("%s-%s", version, sha256[:min(12, len(sha256))]))
	when ODIN_OS == .Darwin {
		exe = join(dir, "Godot.app", "Contents", "MacOS", "Godot")
	} else when ODIN_OS == .Windows {
		exe = join(dir, aprintf("Godot_v%s_win64_console.exe", tag))
	} else {
		exe = join(dir, aprintf("Godot_v%s_linux.x86_64", tag))
	}
	return
}

// What a Godot executable reports for --version (its last line; "" when it doesn't run), to check it against
// the pin before it is used.
godot_version :: proc(exe: string) -> string {
	result := run_proc({
		cmd     = strs(exe, "--version"),
		capture = true,
		quiet   = true,
		timeout = 60 * time.Second,
	})
	lines := strings.split_lines(strings.trim_space(result.stdout))
	return len(lines) > 0 ? lines[len(lines) - 1] : ""
}

// Whether godot_problems found that the game's extension did not install (its problems are then all it lists).
not_installed :: proc(problems: []string) -> bool {
	return len(problems) > 0 && strings.has_prefix(problems[0], "the extension is not installed: ")
}

// Godot's error lines.
godot_errors :: proc(text: string) -> []string {
	return lines_with(text, "ERROR", "Parse Error")
}

// The GDScript errors in a Godot run's output, each once as `res://file.gd:line: message`: one the debugger broke on
// (`Debugger Break, Reason: '<message>'`, then `*Frame 0 - res://file.gd:line ...`) and a script error with its place
// (`SCRIPT ERROR: <message>`, then `at: <function> (res://file.gd:line)`). A parse error in a `-s` script can crash
// Godot under the debugger (signal 11), and the crash's backtrace says nothing of it: this is the cause.
script_errors :: proc(text: string) -> []string {
	out: [dynamic]string
	lines := strings.split_lines(text)
	for line, i in lines {
		trimmed := strings.trim_space(line)
		message, place := "", ""
		BREAK :: "Debugger Break, Reason: '"
		SCRIPT :: "SCRIPT ERROR: "
		FRAME :: "*Frame 0 - "
		if strings.has_prefix(trimmed, BREAK) {
			message = strings.trim_suffix(trimmed[len(BREAK):], "'")
			for next in lines[i + 1:min(i + 4, len(lines))] {
				frame := strings.trim_space(next)
				if !strings.has_prefix(frame, FRAME) do continue
				place, _, _ = strings.partition(frame[len(FRAME):], " in function")
				break
			}
		} else if strings.has_prefix(trimmed, SCRIPT) {
			message = trimmed[len(SCRIPT):]
			for next in lines[i + 1:min(i + 4, len(lines))] {
				at := strings.index(next, "(res://")
				if !strings.contains(next, "at: ") || at < 0 do continue
				place = strings.trim_suffix(strings.trim_space(next[at + 1:]), ")")
				break
			}
		}
		if message == "" do continue
		entry := place != "" ? aprintf("%s: %s", place, message) : message
		if !slice.contains(out[:], entry) do append(&out, entry)
	}
	return out[:]
}

// A Godot run's output with a crash's C++ backtrace (from the `CrashHandlerException` line to `-- END OF C++
// BACKTRACE --`, with the rules around it) left out, for a crash right after a debugger break (the break's script
// error, script_errors, is the cause).
without_backtrace :: proc(text: string) -> string {
	out := strings.builder_make()
	skipping := false
	for line in strings.split_lines(text) {
		if strings.contains(line, "CrashHandlerException") {
			skipping = true
			strings.write_string(&out, "(Godot crashed after the script error; its C++ backtrace is left out)\n")
			continue
		}
		if skipping {
			if strings.contains(line, "END OF C++ BACKTRACE") do skipping = false
			continue
		}
		if strings.has_prefix(line, "=========") do continue // the rules around the backtrace
		strings.write_string(&out, line)
		strings.write_byte(&out, '\n')
	}
	return strings.to_string(out)
}

// A tool run's output as uni shows it: a crash right after a debugger break (a parse error in the `-s` script itself)
// without its backtrace (without_backtrace), as the break's script error (listed last) is the cause; any other output,
// another crash's included (a window or coop run, which has no debugger), as it is.
tool_output_shown :: proc(out: string) -> string {
	crash_at := strings.index(out, "CrashHandlerException")
	break_at := strings.index(out, "Debugger Break")
	return crash_at >= 0 && break_at >= 0 && break_at < crash_at ? without_backtrace(out) : out
}

// What fails a Godot run besides its exit code, each with what it is: a script error (script_errors) first, an error
// line, a leak at exit, a GDScript
// warning, and a warning a game's own script raised (its backtrace names a res://game/ frame; the engine's warnings
// and the library's pass). When the game's extension did not install (godot.install_problems), only why: every
// other error (scripts naming the game's classes, a session that can't start) follows from it.
godot_problems :: proc(text: string) -> []string {
	problems: [dynamic]string
	lines := strings.split_lines(text)
	for line in lines {
		if _, _, reason := strings.partition(line, " is not installed: "); reason != "" {
			append(&problems, aprintf("the extension is not installed: %s", strings.trim_space(reason)))
		}
	}
	if len(problems) > 0 do return problems[:]
	for script_error in script_errors(text) do append(&problems, aprintf("script error: %s", script_error))
	for line, i in lines {
		if strings.contains(line, "leaked at exit") || strings.contains(line, "still in use at exit") {
			append(&problems, aprintf("leak at exit: %s", strings.trim_space(line)))
		}
		if !strings.has_prefix(line, "WARNING:") do continue
		if i + 1 < len(lines) && strings.contains(lines[i + 1], "GDScript::reload") {
			append(&problems, aprintf("GDScript warning: %s", strings.trim_space(line)))
			continue
		}
		for next in lines[i + 1:] { 	// the warning's indented "at:" line and backtrace
			if len(next) == 0 || (next[0] != ' ' && next[0] != '\t') do break
			if strings.contains(next, "res://game/") {
				append(&problems, aprintf("game warning: %s", strings.trim_space(line)))
				break
			}
		}
	}
	for error_line in godot_errors(text) {
		append(&problems, aprintf("error line: %s", strings.trim_space(error_line)))
	}
	return problems[:]
}

// --- the import cache -------------------------------------------------------------------------------------------

// What Godot imports: an import is needed when it changes.
@(private)
IMPORTED :: []string {
	".svg",
	".png",
	".jpg",
	".webp",
	".wav",
	".ogg",
	".mp3",
	".glb",
	".gltf",
	".fbx",
	".ttf",
	".otf",
	".csv",
}

// What an import depends on: global class names (class_name lines), new scripts (.uid files), imported assets and
// their import settings (.import: path and time each). Editing a script body or a scene needs no import, so the edit
// loop skips it. Walks what Godot scans: no hidden entries, no directory holding a .gdignore (all of a unified
// submodule but its tools_godot/).
@(private)
import_signature :: proc(dir: string) -> string {
	parts: [dynamic]string
	walk :: proc(root, dir: string, parts: ^[dynamic]string) {
		infos, _ := os.read_all_directory_by_path(dir, context.allocator)
		for info in infos {
			if strings.has_prefix(info.name, ".") {
				continue
			}
			if info.type == .Directory {
				if !os.exists(join(info.fullpath, ".gdignore")) {
					walk(root, info.fullpath, parts)
				}
				continue
			}
			relative := info.fullpath[len(root) + 1:]
			ext := strings.to_lower(os.ext(info.name), context.temp_allocator)
			if ext == ".gd" {
				text, _ := read_text(info.fullpath)
				names: [dynamic]string
				for line in strings.split_lines(text, context.temp_allocator) {
					if strings.has_prefix(line, "class_name ") {
						append(&names, strings.trim_space(line))
					}
				}
				append(parts, aprintf("%s %v %v", relative, names[:], os.exists(aprintf("%s.uid", info.fullpath))))
			} else if slice.contains(IMPORTED, ext) || ext == ".import" {
				append(parts, aprintf("%s %d", relative, time.to_unix_nanoseconds(info.modification_time)))
			}
		}
	}
	walk(dir, dir, &parts)
	slice.sort(parts[:])
	return strings.join(parts[:], "\n")
}

// Refreshes Godot's import cache (.godot/) when it is missing or stale, after mirroring unified's tool scripts and
// writing the extension list (so the import sees the extension's classes). Returns the extensions listed. Every
// command that starts Godot on a project calls it first but the editor, which imports by itself: a script that
// names a class Godot hasn't cached stops at `Could not find base class` and hangs until its timeout.
ensure_imported :: proc(dir: string) -> []string {
	sync_tools(dir)
	exts := write_extension_list_dir(dir)
	if import_current(dir) {
		return exts
	}
	start := time.tick_now()
	result := run_godot({"--headless", "--path", dir, "--import"}, 300, editor_env(dir))
	if !result.ok {
		log("%s", tail(strings.concatenate({result.stdout, result.stderr}), 4000))
		fatal("the Godot import of %s failed (exit %d)", rel(dir), result.exit_code)
	}
	import_mark_current(dir) // after the import: it may have added .uid files
	log("uni: imported %s in %.1fs", rel(dir), seconds_since(start))
	return exts
}

// Whether Godot's import cache of a project is current: its class cache exists (a fresh checkout has none) and the
// import signature (class names, new scripts, imported assets and their import settings; the mirrored shared code
// included) is the one the last import recorded.
import_current :: proc(dir: string) -> bool {
	have, ok := read_text(join(dir, ".godot", "unified_import.sig"))
	return ok && os.is_file(join(dir, ".godot", "global_script_class_cache.cfg")) && have == import_signature(dir)
}

// Records the project's import signature as imported.
import_mark_current :: proc(dir: string) {
	write_text(join(dir, ".godot", "unified_import.sig"), import_signature(dir))
}

// Runs Godot to the end with a timeout (a headless Godot can hang, e.g. when an extension fails to load), output
// captured, stdin a `quit` line (with -d, a script error must end the run, not wait at the debugger prompt: `start`).
run_godot :: proc(args: []string, timeout_s: f64, env: []string = nil) -> Ran {
	cmd: [dynamic]string
	append(&cmd, godot())
	append(&cmd, ..args)
	return run_proc({
		cmd     = cmd[:],
		capture = true,
		timeout = time.Duration(timeout_s * f64(time.Second)),
		env     = env,
	})
}

// The environment of a headless editor run on a project (`--import`, the godot suite's `editor` step): Godot's
// per-user config and cache directories (editor_settings-<version>.tres, and the doc cache, which each project's
// extension changes) moved into the project's .out/godot-editor/, so editors running at once on different projects
// (the godot suite's games in parallel, other checkouts) never read a file another is writing. Exports (`release`)
// run with the real directories, where the export templates are, and `uni editor` too: it is the developer's
// editor, with their settings.
editor_env :: proc(dir: string) -> []string {
	home := join(dir, ".out", "godot-editor")
	make_dirs(home)
	when ODIN_OS == .Windows {
		// Godot's config and data directory (%APPDATA%) and its cache (%LOCALAPPDATA%)
		return env_with(aprintf("APPDATA=%s", join(home, "config")), aprintf("LOCALAPPDATA=%s", join(home, "cache")))
	} else {
		// Godot reads the XDG variables on macOS too
		return env_with(
			aprintf("XDG_CONFIG_HOME=%s", join(home, "config")),
			aprintf("XDG_CACHE_HOME=%s", join(home, "cache")),
		)
	}
}

// --- tool scripts -----------------------------------------------------------------------------------------------

// A run of game/tools/<script>.gd. Every run is strict: a failing exit, a missing or `ok: false` UNIFIED_RESULT
// line, an ERROR line, a leak at exit or a GDScript warning fails it.
Tool_Run :: struct {
	dir:     string, // the Godot project
	script:  string, // res:// path
	args:    []string, // after --
	window:  bool,
	place:   Window_Opts, // with window: sound and screen
	shots:   string, // a name: --shots=res://.out/shots/<name>
	size:    string, // with window: `WxH`, --window-size (UnifiedTool places and sizes it)
	timeout: f64,
	env:     []string, // the whole environment (nil: user_env's, the project's own user data)
	quiet:   bool, // don't echo the script's output (it is shown on failure)
}

// How a tool script run went, judged by the strict rules (judge_tool).
Tool_Result :: struct {
	ok:       bool,
	result:   json.Value, // the UNIFIED_RESULT object (nil when missing)
	problems: []string,
	seconds:  f64,
	output:   string,
}

RESULT_MARKER :: "UNIFIED_RESULT "

// The Godot command line of a tool script run: headless, or a window placed by `place`, always with
// --no-settings and --local-net. Also for callers that start the process themselves (coop's host and joiner).
tool_cmd :: proc(tool_run: Tool_Run) -> []string {
	cmd: [dynamic]string
	append(&cmd, godot())
	if tool_run.window {
		append(&cmd, ..window_args(tool_run.place)) // the project's window size, as a headless run's (UnifiedTool)
	} else {
		append(&cmd, "--headless", "-d")
	}
	append(&cmd, "--path", tool_run.dir, "-s", tool_run.script, "--", "--no-settings", "--local-net")
	if tool_run.shots != "" {
		append(&cmd, aprintf("--shots=res://.out/shots/%s", tool_run.shots))
	}
	if tool_run.window && tool_run.size != "" {
		append(&cmd, aprintf("--window-size=%s", tool_run.size))
	}
	append(&cmd, ..tool_run.args)
	return cmd[:]
}

// Runs a tool script to its end and judges it by the strict rules (judge_tool). A window run prepares the project
// with with_window and, on macOS, gives focus back to the app that was in front.
run_tool :: proc(tool_run: Tool_Run) -> Tool_Result {
	cleanup := tool_run.window ? with_window(tool_run.dir, tool_run.place) : no_cleanup
	defer cleanup(tool_run.dir)
	ran := run_proc({
		cmd     = tool_cmd(tool_run),
		capture = true,
		timeout = time.Duration(tool_run.timeout * f64(time.Second)),
		env     = tool_run.env if tool_run.env != nil else user_env(tool_run.dir),
	})
	return judge_tool(ran, !tool_run.quiet)
}

// Judges a tool script's run by the strict rules.
judge_tool :: proc(ran: Ran, echo: bool) -> Tool_Result {
	out := strings.concatenate({ran.stdout, ran.stderr})
	report := Tool_Result {
		seconds = ran.seconds,
		output  = out,
	}
	problems: [dynamic]string
	append(&problems, ..godot_problems(out))
	crashed := strings.contains(out, "CrashHandlerException")
	shown := tool_output_shown(out)
	for line in strings.split_lines(shown) {
		if strings.has_prefix(line, RESULT_MARKER) {
			value, err := json.parse_string(line[len(RESULT_MARKER):], parse_integers = true)
			if err == nil {
				report.result = value
			}
		} else if echo && strings.trim_space(line) != "" && !strings.has_prefix(line, "Godot Engine v") {
			log("%s", line)
		}
	}
	if ran.timed_out {
		append(&problems, aprintf("timed out after %.0fs", ran.seconds))
	} else if crashed {
		append(&problems, aprintf("Godot crashed (exit code %d)", ran.exit_code))
	} else if ran.exit_code != 0 {
		append(&problems, aprintf("exit code %d", ran.exit_code))
	}
	if obj, ok := report.result.(json.Object); !ok {
		append(&problems, "no UNIFIED_RESULT line")
	} else if okv, has := obj["ok"]; has {
		if value, isb := okv.(json.Boolean); isb && !value {
			append(&problems, "the result says ok: false")
		}
	}
	report.problems = problems[:]
	report.ok = len(problems) == 0
	if !report.ok && !echo && !not_installed(problems[:]) {
		log("%s", tail(shown, 6000))
	}
	for problem in problems {
		log("uni: %s", problem)
	}
	return report
}

// A tool script by name: the game's game/tools/<name>.gd, else unified's (res://unified/tools_godot/) ("" when
// neither has it). A name ending in .gd is a script file by path instead (relative to the working directory),
// anywhere: an agent's throwaway script, run against the project without joining it. It comes back absolute, which
// Godot's -s takes as it takes a res:// path ("" when there is no such file).
tool_script :: proc(game: Game, name: string) -> string {
	if strings.has_suffix(name, ".gd") {
		if !os.is_file(name) do return ""
		path, _ := os.get_absolute_path(name, context.allocator)
		slashed, _ := strings.replace_all(path, "\\", "/")
		return slashed
	}
	if os.is_file(join(game.dir, "game", "tools", aprintf("%s.gd", name))) {
		return aprintf("res://game/tools/%s.gd", name)
	}
	if os.is_file(join(state.project.unified, TOOLS_SOURCE, aprintf("%s.gd", name))) {
		return aprintf("res://%s/%s.gd", TOOLS_DIR, name)
	}
	return ""
}

// Whether the script file at `path` can be Godot's -s main loop: it extends SceneTree or MainLoop, directly or through
// the classes and res:// scripts it extends, found in the project at `dir` or in unified's tools at `library` (what
// res://unified/tools_godot/ is). Godot refuses any other -s script and runs the main scene instead, a run that
// never ends, so `tool` refuses it first. `extends` is what the script itself extends ("": nothing found).
tool_script_runs :: proc(path, dir, library: string) -> (ok: bool, extends: string) {
	classes := make(map[string]string, context.temp_allocator) // class_name -> what it extends
	for source in ([]string{dir, library}) {
		for file in godot_files(source, ".gd") {
			text, _ := read_text(file)
			name, base := script_header(text)
			if name != "" && name not_in classes do classes[name] = base
		}
	}
	text, _ := read_text(path)
	_, extends = script_header(text)
	for current, depth := extends, 0; current != "" && depth < 32; depth += 1 {
		if current == "SceneTree" || current == "MainLoop" do return true, extends
		if strings.has_prefix(current, "res://") {
			rel_path := current[len("res://"):]
			file := join(dir, rel_path)
			if strings.has_prefix(rel_path, TOOLS_DIR + "/") do file = join(library, rel_path[len(TOOLS_DIR) + 1:])
			next, _ := read_text(file)
			_, current = script_header(next)
		} else {
			current = classes[current] or_else ""
		}
	}
	return false, extends
}

// A GDScript's `class_name` and what it `extends` (a class name, or a res:// path without its quotes); "" for one it
// doesn't declare. Both are read from the lines before its first declaration (`class_name A extends B` included).
script_header :: proc(text: string) -> (class_name, extends: string) {
	for raw in strings.split_lines(text, context.temp_allocator) {
		line := raw
		if comment := strings.index_byte(line, '#'); comment >= 0 do line = line[:comment]
		line = strings.trim_space(line)
		if strings.has_prefix(line, "class_name ") {
			rest := strings.trim_space(line[len("class_name "):])
			name, _, base := strings.partition(rest, " extends ")
			class_name = strings.trim_space(name)
			if base != "" do extends = strings.trim(strings.trim_space(base), "\"'")
		} else if strings.has_prefix(line, "extends ") {
			extends = strings.trim(strings.trim_space(line[len("extends "):]), "\"'")
		} else if strings.has_prefix(line, "func ") ||
		   strings.has_prefix(line, "var ") ||
		   strings.has_prefix(line, "const ") {
			break
		}
	}
	return
}

// The environment of a game run that must never touch the developer's own data (the godot suite's runs, tool
// scripts, `drive`, `coop`): Godot's user data directory, so the game's user:// (saves, settings, the LAN token), moved
// into the project's .out/user/, kept from run to run (a whole godot suite run clears it first); `extra` overrides on
// top. `run` and `editor` keep the real one: they are the developer's own.
user_env :: proc(dir: string, extra: ..string) -> []string {
	home := user_base(dir)
	make_dirs(home)
	overrides: [dynamic]string
	when ODIN_OS == .Windows {
		append(&overrides, aprintf("APPDATA=%s", home)) // %APPDATA%/Godot/app_userdata/<name>
	} else {
		append(&overrides, aprintf("XDG_DATA_HOME=%s", home)) // Godot reads it on macOS too
	}
	append(&overrides, ..extra)
	return env_with(..overrides[:])
}

// Where user_env puts a project's Godot user data (godot_user_dir(user_base(dir)) is Godot's directory there).
user_base :: proc(dir: string) -> string {
	return join(dir, ".out", "user")
}

// The environment plus overrides (KEY=value), for a child that needs a few variables changed.
env_with :: proc(overrides: ..string) -> []string {
	env, _ := os.environ(context.allocator)
	out: [dynamic]string
	for entry in env {
		key := entry[:max(0, strings.index_byte(entry, '='))]
		replaced := false
		for override in overrides {
			if strings.has_prefix(override, aprintf("%s=", key)) {
				replaced = true
			}
		}
		if !replaced {
			append(&out, entry)
		}
	}
	append(&out, ..overrides)
	return out[:]
}

// --- windows ----------------------------------------------------------------------------------------------------

// Where and how a game window opens (run, editor, tool --window, coop --window): `mute` starts Godot with the dummy
// audio driver; `screen` is Godot's screen index, or left / right / primary (read from the OS: os_screens, on Windows,
// macOS and Linux with xrandr);
// `background`: the window never takes focus (`with_window`). `run` and `editor` take them as flags (an agent's
// `run` passes all three); a check's window is always AGENT_WINDOW.
Window_Opts :: struct {
	mute:       bool,
	screen:     string,
	background: bool,
}

// The window of a check (tool --window, coop --window, this repo's view-bench --window): muted, on the leftmost
// screen, never taking focus, so it never disturbs the developer's screen or keyboard.
AGENT_WINDOW :: Window_Opts {
	mute       = true,
	screen     = "left",
	background = true,
}

// The project override uni writes for a background window: Godot's no-focus flag, which can only be set before the
// main window exists. Godot reads <project>/override.cfg at startup (a run, not the editor, which ignores it).
OVERRIDE_CFG :: "override.cfg"
BACKGROUND_OVERRIDE :: `; Written by uni for a window that must not take focus; removed when that run ends (safe to delete).
[display]

window/size/no_focus=true
`

// Prepares the project for a window opened with `window` and returns the cleanup to run when the Godot process has ended.
// A background window opens without activation and clicks never activate it (Windows: SW_SHOWNA and
// WS_EX_NOACTIVATE, kept on top of other windows; it never calls SetForegroundWindow), so the app in front keeps the
// keyboard, and the game runs on while it isn't frontmost. macOS activates Godot anyway: a focus guard hands the
// focus straight back (focus_darwin.odin). A window that may take focus removes an override a crashed run left behind.
with_window :: proc(dir: string, window: Window_Opts) -> (cleanup: proc(dir: string)) {
	path := join(dir, OVERRIDE_CFG)
	if window.background {
		write_text(path, BACKGROUND_OVERRIDE)
		start_focus_guard()
		return proc(dir: string) {
				stop_focus_guard()
				path := join(dir, OVERRIDE_CFG)
				if text, ok := read_text(path); ok && text == BACKGROUND_OVERRIDE {
					os.remove(path)
				}
			}
	}
	if text, ok := read_text(path); ok && text == BACKGROUND_OVERRIDE {
		os.remove(path)
	}
	return no_cleanup
}

// The cleanup for a run that left nothing in the project to undo (no window, or one that may take focus).
no_cleanup :: proc(_: string) {}

// A screen as the OS lists it (os_screens, in Godot's screen order): its left and right edges in the desktop's
// coordinates, and whether it is the primary one.
Screen :: struct {
	left, right: i32,
	primary:     bool,
}

// How long `xrandr --listmonitors` may take (Linux, screens_linux.odin): it answers in milliseconds.
XRANDR_TIMEOUT :: 5 * time.Second

// The monitors `xrandr --listmonitors` lists, in its order (XRandR's, Godot's on X11): a line per monitor,
// ` 0: +*DP-1 2560/597x1440/336+0+0  DP-1`, `*` marking the primary, the geometry width/mm x height/mm + x + y.
parse_xrandr_monitors :: proc(text: string) -> []Screen {
	out: [dynamic]Screen
	for line in strings.split_lines(text, context.temp_allocator) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 3 || !strings.has_suffix(fields[0], ":") {
			continue
		}
		if _, is_index := strconv.parse_int(strings.trim_suffix(fields[0], ":")); !is_index {
			continue // the "Monitors: 2" header
		}
		// width/mm x height/mm + x + y
		geometry := fields[2]
		slash := strings.index_byte(geometry, '/')
		plus := strings.index_byte(geometry, '+')
		if slash < 0 || plus < 0 {
			continue
		}
		offsets := strings.split(geometry[plus + 1:], "+", context.temp_allocator)
		width, width_ok := strconv.parse_int(geometry[:slash])
		x, x_ok := strconv.parse_int(len(offsets) > 0 ? offsets[0] : "")
		if !width_ok || !x_ok {
			continue
		}
		append(&out, Screen{i32(x), i32(x + width), strings.contains(fields[1], "*")})
	}
	return out[:]
}

// Godot's arguments for `window` (before --).
window_args :: proc(window: Window_Opts) -> []string {
	args: [dynamic]string
	if window.mute {
		append(&args, "--audio-driver", "Dummy")
	}
	if window.screen != "" {
		append(&args, "--screen", aprintf("%d", screen_index(window.screen)))
	}
	return args[:]
}

// Reads a window size, `WxH` (1280x720), for a --size option; usage error otherwise.
parse_window_size :: proc(text: string) -> (size: [2]int) {
	x := strings.index_byte(text, 'x')
	width, width_ok := strconv.parse_int(text[:max(x, 0)])
	height, height_ok := strconv.parse_int(x >= 0 ? text[x + 1:] : "")
	if x < 0 || !width_ok || !height_ok || width < 64 || height < 64 {
		usage("--size takes WIDTHxHEIGHT, at least 64x64 (got %q)", text)
	}
	return {width, height}
}

@(private)
screen_index :: proc(name: string) -> int {
	if index, ok := strconv.parse_int(name); ok && index >= 0 {
		return index
	}
	if name != "left" && name != "right" && name != "primary" {
		usage("--screen takes Godot's screen index, left, right or primary (got %q)", name)
	}
	screens := os_screens()
	if len(screens) == 0 {
		usage(
			"--screen %s: this OS's screens can't be read here (Linux: needs xrandr and an X11 or XWayland display); pass Godot's screen index",
			name,
		)
	}
	best := 0
	for screen, i in screens {
		best_screen := screens[best]
		switch name {
		case "left":
			if screen.left < best_screen.left do best = i
		case "right":
			if screen.right > best_screen.right do best = i
		case "primary":
			if screen.primary do best = i
		}
	}
	return best
}
