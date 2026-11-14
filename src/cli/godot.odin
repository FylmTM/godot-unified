package cli

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// Godot: the pinned editor, the import cache, and running a game's tool scripts strictly (SPEC.md, Test suites and
// tool scripts).

// The pinned editor: UNIFIED_GODOT when it names an install that reports exactly the pinned version, else the
// official build downloaded (hash-checked) into the per-user cache (user_cache), shared by every checkout: one
// download per machine, and one path for the OS to know it by (Windows Firewall remembers programs by path).
godot :: proc() -> string {
	@(static) cached: string
	if cached != "" {
		return cached
	}
	version := pin("godot", "version")
	want := tprint("%s.stable.official", version)
	if path := os.get_env("UNIFIED_GODOT", context.allocator); path != "" {
		// `--version` costs a Godot start: remember the answer for this exact file.
		check := join(state.project.out, "godot", "unified_godot.checked")
		id := file_identity(path)
		if !stamp_ok(check, id) {
			got := godot_version(path)
			if !strings.has_prefix(got, want) {
				fatal("UNIFIED_GODOT=%s reports %q; the pin is %s", path, got, want)
			}
			write_text(check, tprint("%s\n", id))
		}
		cached = path
		return path
	}
	dir, exe, asset, sha256 := godot_download()
	if !os.is_file(exe) {
		cold("Godot download")
		// Unpacked beside its final place and renamed into it: another checkout may be fetching it at the same time
		// (the first rename wins), and a half-unpacked editor never sits at the final path.
		tmp := tprint("%s.%d.tmp", dir, os.get_pid())
		remove_tree(tmp)
		zip := join(tmp, asset)
		download(
			tprint("https://github.com/godotengine/godot/releases/download/%s-stable/%s", version, asset),
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
	tag := tprint("%s-stable", version)
	when ODIN_OS == .Darwin {
		sha256 = pin("godot", "sha256_macos")
		asset = tprint("Godot_v%s_macos.universal.zip", tag)
	} else when ODIN_OS == .Windows {
		sha256 = pin("godot", "sha256_windows")
		asset = tprint("Godot_v%s_win64.exe.zip", tag)
	} else {
		sha256 = pin("godot", "sha256_linux")
		asset = tprint("Godot_v%s_linux.x86_64.zip", tag)
	}
	dir = join(user_cache(), "godot", tprint("%s-%s", version, sha256[:min(12, len(sha256))]))
	when ODIN_OS == .Darwin {
		exe = join(dir, "Godot.app", "Contents", "MacOS", "Godot")
	} else when ODIN_OS == .Windows {
		exe = join(dir, tprint("Godot_v%s_win64_console.exe", tag))
	} else {
		exe = join(dir, tprint("Godot_v%s_linux.x86_64", tag))
	}
	return
}

godot_version :: proc(exe: string) -> string {
	result := run_proc({cmd = strs(exe, "--version"), capture = true, quiet = true, timeout = 60 * time.Second})
	lines := strings.split_lines(strings.trim_space(result.stdout))
	return len(lines) > 0 ? lines[len(lines) - 1] : ""
}

// Godot's error lines.
godot_errors :: proc(text: string) -> []string {
	return lines_with(text, "ERROR", "Parse Error")
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

// What an import depends on: global class names (class_name lines), new scripts (.uid files), imported assets (path
// and time). Editing a script body or a scene needs no import, so the edit loop skips it. Walks what Godot scans: no
// hidden entries, no directory holding a .gdignore (a unified submodule).
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
				append(parts, tprint("%s %v %v", relative, names[:], os.exists(tprint("%s.uid", info.fullpath))))
			} else if slice.contains(IMPORTED, ext) {
				append(parts, tprint("%s %d", relative, time.to_unix_nanoseconds(info.modification_time)))
			}
		}
	}
	walk(dir, dir, &parts)
	slice.sort(parts[:])
	return strings.join(parts[:], "\n")
}

// Refreshes Godot's import cache (.godot/) when it is missing or stale, after mirroring the shared Godot code and
// writing the extension list (so the import sees the extension's classes). Returns the extensions listed. Every
// command that starts Godot on a project calls it first but the editor, which imports by itself: a script that
// names a class Godot hasn't cached stops at `Could not find base class` and hangs until its timeout.
ensure_imported :: proc(dir: string) -> []string {
	sync_shared(dir)
	exts := write_extension_list_dir(dir)
	if import_current(dir) {
		return exts
	}
	start := time.tick_now()
	result := run_godot({"--headless", "--path", dir, "--import"}, 300)
	if !result.ok {
		log("%s", tail(strings.concatenate({result.stdout, result.stderr}), 4000))
		fatal("the Godot import of %s failed (exit %d)", rel(dir), result.exit_code)
	}
	import_mark_current(dir) // after the import: it may have added .uid files
	cold(tprint("Godot import of %s", os.base(dir)))
	log("uni: imported %s in %.1fs", rel(dir), seconds_since(start))
	return exts
}

// Whether Godot's import cache of a project is current: its class cache exists (a fresh checkout has none) and the
// import signature (class names, new scripts, imported assets; the mirrored shared code included) is the one the
// last import recorded.
import_current :: proc(dir: string) -> bool {
	have, ok := read_text(join(dir, ".godot", "unified_import.sig"))
	return ok && os.is_file(join(dir, ".godot", "global_script_class_cache.cfg")) && have == import_signature(dir)
}

// Records the project's import signature as imported.
import_mark_current :: proc(dir: string) {
	write_text(join(dir, ".godot", "unified_import.sig"), import_signature(dir))
}

// Runs Godot to the end with a timeout (a headless Godot can hang, e.g. when an extension fails to load), output
// captured, stdin closed (with -d, a script error must end the run, not wait at the debugger prompt).
run_godot :: proc(args: []string, timeout_s: f64, env: []string = nil) -> Ran {
	cmd: [dynamic]string
	append(&cmd, godot())
	append(&cmd, ..args)
	return run_proc({cmd = cmd[:], capture = true, timeout = time.Duration(timeout_s * f64(time.Second)), env = env})
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
	timeout: f64,
	env:     []string,
	quiet:   bool, // don't echo the script's output (it is shown on failure)
}

Tool_Result :: struct {
	ok:       bool,
	result:   json.Value, // the UNIFIED_RESULT object (nil when missing)
	problems: []string,
	seconds:  f64,
	output:   string,
}

RESULT_MARKER :: "UNIFIED_RESULT "

tool_cmd :: proc(tool_run: Tool_Run) -> []string {
	cmd: [dynamic]string
	append(&cmd, godot())
	if tool_run.window {
		append(&cmd, "--resolution", "1280x720")
		append(&cmd, ..window_args(tool_run.place))
	} else {
		append(&cmd, "--headless", "-d")
	}
	append(&cmd, "--path", tool_run.dir, "-s", tool_run.script, "--", "--no-settings", "--local-net")
	if tool_run.shots != "" {
		append(&cmd, tprint("--shots=res://.out/shots/%s", tool_run.shots))
	}
	append(&cmd, ..tool_run.args)
	return cmd[:]
}

run_tool :: proc(tool_run: Tool_Run) -> Tool_Result {
	cleanup := tool_run.window ? with_window(tool_run.dir, tool_run.place) : no_cleanup
	defer cleanup(tool_run.dir)
	front := tool_run.window ? front_app() : ""
	ran := run_proc(
		{
			cmd = tool_cmd(tool_run),
			capture = true,
			timeout = time.Duration(tool_run.timeout * f64(time.Second)),
			env = tool_run.env,
		},
	)
	if front != "" {
		restore_front_app(front)
	}
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
	lines := strings.split_lines(out)
	for line, i in lines {
		if strings.has_prefix(line, RESULT_MARKER) {
			value, err := json.parse_string(line[len(RESULT_MARKER):])
			if err == nil {
				report.result = value
			}
		} else if echo && strings.trim_space(line) != "" && !strings.has_prefix(line, "Godot Engine v") {
			log("%s", line)
		}
		if strings.contains(line, "leaked at exit") || strings.contains(line, "still in use at exit") {
			append(&problems, tprint("leak at exit: %s", strings.trim_space(line)))
		}
		if strings.has_prefix(line, "WARNING:") &&
		   i + 1 < len(lines) &&
		   strings.contains(lines[i + 1], "GDScript::reload") {
			append(&problems, tprint("GDScript warning: %s", strings.trim_space(line)))
		}
	}
	for error_line in godot_errors(out) {
		append(&problems, tprint("error line: %s", strings.trim_space(error_line)))
	}
	if ran.timed_out {
		append(&problems, tprint("timed out after %.0fs", ran.seconds))
	} else if ran.exit_code != 0 {
		append(&problems, tprint("exit code %d", ran.exit_code))
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
	if !report.ok && !echo {
		log("%s", tail(out, 6000))
	}
	for problem in problems {
		log("uni: %s", problem)
	}
	return report
}

// macOS: a windowed Godot may activate itself even with no_focus (not verified there yet); give focus back to the
// app that was in front.
front_app :: proc() -> string {
	when ODIN_OS == .Darwin {
		asn := run_proc({cmd = strs("lsappinfo", "front"), capture = true, quiet = true})
		info := run_proc(
			{
				cmd = strs("lsappinfo", "info", "-only", "bundleid", strings.trim_space(asn.stdout)),
				capture = true,
				quiet = true,
			},
		)
		if eq := strings.index_byte(info.stdout, '='); eq >= 0 {
			bundle_id := strings.trim(strings.trim_space(info.stdout[eq + 1:]), "\"")
			return bundle_id == "[ NULL ]" ? "" : bundle_id
		}
	}
	return ""
}

restore_front_app :: proc(bundle: string) {
	when ODIN_OS == .Darwin {
		run_proc({cmd = strs("open", "-b", bundle), capture = true, quiet = true})
	}
}

// A tool script by name: the game's game/tools/<name>.gd, else the shared code's tools/<name>.gd when the game uses
// it, else unified's (src/godot/tools, mirrored as res://addons/unified/) ("" when none has it).
tool_script :: proc(game: Game, name: string) -> string {
	if os.is_file(join(game.dir, "game", "tools", tprint("%s.gd", name))) {
		return tprint("res://game/tools/%s.gd", name)
	}
	if uses_shared(game.dir) && os.is_file(join(state.project.root, SHARED_SOURCE, "tools", tprint("%s.gd", name))) {
		return tprint("res://%s/tools/%s.gd", SHARED_DIR, name)
	}
	if os.is_file(join(state.project.unified, TOOLS_SOURCE, tprint("%s.gd", name))) {
		return tprint("res://%s/%s.gd", TOOLS_DIR, name)
	}
	return ""
}

// The environment plus overrides (KEY=value), for a child that needs a few variables changed.
env_with :: proc(overrides: ..string) -> []string {
	env, _ := os.environ(context.allocator)
	out: [dynamic]string
	for entry in env {
		key := entry[:max(0, strings.index_byte(entry, '='))]
		replaced := false
		for override in overrides {
			if strings.has_prefix(override, tprint("%s=", key)) {
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
// audio driver; `screen` is Godot's screen index, or left / right / primary (read from the OS: Windows only for now);
// `background`: the window never takes focus (`with_window`). An agent starting a window for the developer passes
// all three, so it doesn't get in the way; tool and coop windows are always in the background.
Window_Opts :: struct {
	mute:       bool,
	screen:     string,
	background: bool,
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
// keyboard, and the game runs on while it isn't frontmost. A window that may take focus removes an override a
// crashed run left behind.
with_window :: proc(dir: string, window: Window_Opts) -> (cleanup: proc(dir: string)) {
	path := join(dir, OVERRIDE_CFG)
	if window.background {
		write_text(path, BACKGROUND_OVERRIDE)
		return proc(dir: string) {
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

no_cleanup :: proc(_: string) {}

@(private)
Screen :: struct {
	left, right: i32,
	primary:     bool,
}

// Godot's arguments for `window` (before --).
window_args :: proc(window: Window_Opts) -> []string {
	args: [dynamic]string
	if window.mute {
		append(&args, "--audio-driver", "Dummy")
	}
	if window.screen != "" {
		append(&args, "--screen", tprint("%d", screen_index(window.screen)))
	}
	return args[:]
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
		usage("--screen %s: this OS's screens can't be read yet; pass Godot's screen index", name)
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
