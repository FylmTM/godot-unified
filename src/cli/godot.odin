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
// official build downloaded (hash-checked) into .out/godot/<version>/.
godot :: proc() -> string {
	@(static) cached: string
	if cached != "" {
		return cached
	}
	version := pin("godot", "version")
	want := tprint("%s.stable.official", version)
	if p := os.get_env("UNIFIED_GODOT", context.allocator); p != "" {
		// `--version` costs a Godot start: remember the answer for this exact file.
		check := join(state.project.out, "godot", "unified_godot.checked")
		id := file_identity(p)
		if !stamp_ok(check, id) {
			got := godot_version(p)
			if !strings.has_prefix(got, want) {
				fatal("UNIFIED_GODOT=%s reports %q; the pin is %s", p, got, want)
			}
			write_text(check, tprint("%s\n", id))
		}
		cached = p
		return p
	}
	exe, asset, sha := godot_download()
	tag := tprint("%s-stable", version)
	dir := join(state.project.out, "godot", version)
	if !os.is_file(exe) {
		cold("Godot download")
		zip := join(dir, asset)
		download(tprint("https://github.com/godotengine/godot/releases/download/%s/%s", tag, asset), zip, sha, asset)
		z := zip_open_file(zip)
		zip_extract_all(&z, dir)
		os.remove(zip)
		os.change_mode(exe, os.perm_number(0o755))
		if got := godot_version(exe); !strings.has_prefix(got, want) {
			fatal("the downloaded Godot reports %q, want %s", got, want)
		}
	}
	cached = exe
	return exe
}

// Where the pinned download goes (the editor executable), its release asset and pinned hash.
godot_download :: proc() -> (exe, asset, sha: string) {
	version := pin("godot", "version")
	tag := tprint("%s-stable", version)
	dir := join(state.project.out, "godot", version)
	when ODIN_OS == .Darwin {
		return join(
			dir,
			"Godot.app",
			"Contents",
			"MacOS",
			"Godot",
		), tprint("Godot_v%s_macos.universal.zip", tag), pin("godot", "sha256_macos")
	} else when ODIN_OS == .Windows {
		return join(
			dir,
			tprint("Godot_v%s_win64_console.exe", tag),
		), tprint("Godot_v%s_win64.exe.zip", tag), pin("godot", "sha256_windows")
	} else {
		return join(
			dir,
			tprint("Godot_v%s_linux.x86_64", tag),
		), tprint("Godot_v%s_linux.x86_64.zip", tag), pin("godot", "sha256_linux")
	}
}

godot_version :: proc(exe: string) -> string {
	r := run_proc({cmd = strs(exe, "--version"), capture = true, quiet = true, timeout = 60 * time.Second})
	lines := strings.split_lines(strings.trim_space(r.stdout))
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
		for fi in infos {
			if strings.has_prefix(fi.name, ".") {
				continue
			}
			if fi.type == .Directory {
				if !os.exists(join(fi.fullpath, ".gdignore")) {
					walk(root, fi.fullpath, parts)
				}
				continue
			}
			r := fi.fullpath[len(root) + 1:]
			ext := strings.to_lower(os.ext(fi.name), context.temp_allocator)
			if ext == ".gd" {
				text, _ := read_text(fi.fullpath)
				names: [dynamic]string
				for line in strings.split_lines(text, context.temp_allocator) {
					if strings.has_prefix(line, "class_name ") {
						append(&names, strings.trim_space(line))
					}
				}
				append(parts, tprint("%s %v %v", r, names[:], os.exists(tprint("%s.uid", fi.fullpath))))
			} else if slice.contains(IMPORTED, ext) {
				append(parts, tprint("%s %d", r, time.to_unix_nanoseconds(fi.modification_time)))
			}
		}
	}
	walk(dir, dir, &parts)
	slice.sort(parts[:])
	return strings.join(parts[:], "\n")
}

// Refreshes Godot's import cache (.godot/) when it is missing or stale, after writing the extension list (so the
// import sees the extension's classes). Returns the extensions listed.
ensure_imported :: proc(dir: string) -> []string {
	exts := write_extension_list_dir(dir)
	stamp := join(dir, ".godot", "unified_import.sig")
	sig := import_signature(dir)
	fresh := os.is_file(join(dir, ".godot", "global_script_class_cache.cfg"))
	if have, ok := read_text(stamp); fresh && ok && have == sig {
		return exts
	}
	start := time.tick_now()
	r := run_godot({"--headless", "--path", dir, "--import"}, 300)
	if !r.ok {
		log("%s", tail(strings.concatenate({r.stdout, r.stderr}), 4000))
		fatal("the Godot import of %s failed (exit %d)", rel(dir), r.exit_code)
	}
	write_text(stamp, import_signature(dir)) // the import may have added .uid files
	cold(tprint("Godot import of %s", os.base(dir)))
	log("uni: imported %s in %.1fs", rel(dir), seconds_since(start))
	return exts
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

tool_cmd :: proc(t: Tool_Run) -> []string {
	cmd: [dynamic]string
	append(&cmd, godot())
	if t.window {
		append(&cmd, "--resolution", "1280x720")
		append(&cmd, ..window_args(t.place))
	} else {
		append(&cmd, "--headless", "-d")
	}
	append(&cmd, "--path", t.dir, "-s", t.script, "--", "--no-settings")
	if t.shots != "" {
		append(&cmd, tprint("--shots=res://.out/shots/%s", t.shots))
	}
	append(&cmd, ..t.args)
	return cmd[:]
}

run_tool :: proc(t: Tool_Run) -> Tool_Result {
	front := t.window ? front_app() : ""
	r := run_proc(
		{cmd = tool_cmd(t), capture = true, timeout = time.Duration(t.timeout * f64(time.Second)), env = t.env},
	)
	if front != "" {
		restore_front_app(front)
	}
	return judge_tool(r, !t.quiet)
}

// Judges a tool script's run by the strict rules.
judge_tool :: proc(r: Ran, echo: bool) -> Tool_Result {
	out := strings.concatenate({r.stdout, r.stderr})
	res := Tool_Result {
		seconds = r.seconds,
		output  = out,
	}
	problems: [dynamic]string
	lines := strings.split_lines(out)
	for line, i in lines {
		if strings.has_prefix(line, RESULT_MARKER) {
			v, err := json.parse_string(line[len(RESULT_MARKER):])
			if err == nil {
				res.result = v
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
	for e in godot_errors(out) {
		append(&problems, tprint("error line: %s", strings.trim_space(e)))
	}
	if r.timed_out {
		append(&problems, tprint("timed out after %.0fs", r.seconds))
	} else if r.exit_code != 0 {
		append(&problems, tprint("exit code %d", r.exit_code))
	}
	if obj, ok := res.result.(json.Object); !ok {
		append(&problems, "no UNIFIED_RESULT line")
	} else if okv, has := obj["ok"]; has {
		if b, isb := okv.(json.Boolean); isb && !b {
			append(&problems, "the result says ok: false")
		}
	}
	res.problems = problems[:]
	res.ok = len(problems) == 0
	if !res.ok && !echo {
		log("%s", tail(out, 6000))
	}
	for p in problems {
		log("uni: %s", p)
	}
	return res
}

// macOS: a windowed Godot steals focus; give it back to the app that was in front.
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
			b := strings.trim(strings.trim_space(info.stdout[eq + 1:]), "\"")
			return b == "[ NULL ]" ? "" : b
		}
	}
	return ""
}

restore_front_app :: proc(bundle: string) {
	when ODIN_OS == .Darwin {
		run_proc({cmd = strs("open", "-b", bundle), capture = true, quiet = true})
	}
}

// The game's tool script by name ("" when it has none).
tool_script :: proc(g: Game, name: string) -> string {
	if os.is_file(join(g.dir, "game", "tools", tprint("%s.gd", name))) {
		return tprint("res://game/tools/%s.gd", name)
	}
	return ""
}

// The environment plus overrides (KEY=value), for a child that needs a few variables changed.
env_with :: proc(overrides: ..string) -> []string {
	env, _ := os.environ(context.allocator)
	out: [dynamic]string
	for e in env {
		key := e[:max(0, strings.index_byte(e, '='))]
		replaced := false
		for o in overrides {
			if strings.has_prefix(o, tprint("%s=", key)) {
				replaced = true
			}
		}
		if !replaced {
			append(&out, e)
		}
	}
	append(&out, ..overrides)
	return out[:]
}

// --- windows ----------------------------------------------------------------------------------------------------

// Where and how a game window opens (run, editor, tool --window, coop --window): `mute` starts Godot with the dummy
// audio driver; `screen` is Godot's screen index, or left / right / primary (read from the OS: Windows only for now).
// An agent starting a window for the developer passes both, so it doesn't get in the way.
Window_Opts :: struct {
	mute:   bool,
	screen: string,
}

@(private)
Screen :: struct {
	left, right: i32,
	primary:     bool,
}

// Godot's arguments for `w` (before --).
window_args :: proc(w: Window_Opts) -> []string {
	args: [dynamic]string
	if w.mute {
		append(&args, "--audio-driver", "Dummy")
	}
	if w.screen != "" {
		append(&args, "--screen", tprint("%d", screen_index(w.screen)))
	}
	return args[:]
}

@(private)
screen_index :: proc(name: string) -> int {
	if n, ok := strconv.parse_int(name); ok && n >= 0 {
		return n
	}
	if name != "left" && name != "right" && name != "primary" {
		usage("--screen takes Godot's screen index, left, right or primary (got %q)", name)
	}
	screens := os_screens()
	if len(screens) == 0 {
		usage("--screen %s: this OS's screens can't be read yet; pass Godot's screen index", name)
	}
	best := 0
	for sc, i in screens {
		b := screens[best]
		switch name {
		case "left":
			if sc.left < b.left do best = i
		case "right":
			if sc.right > b.right do best = i
		case "primary":
			if sc.primary do best = i
		}
	}
	return best
}
