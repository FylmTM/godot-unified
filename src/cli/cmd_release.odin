package cli

import "core:encoding/endian"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:time"


// `uni release`: playable game builds of this host's platform, every game's or one's (README.md, Releases). The
// `unified-release` skill is the pipeline's home for a game: the steps, the version, the rules a game's export follows.

// What a release build of this host's platform is: the export preset it exports, the export templates Godot needs
// for it, the preset's numeric version keys, the .gdextension library keys it ships and the zip's platform name.
@(private)
Release_Host :: struct {
	preset:       string,
	templates:    []string,
	version_keys: []string,
	lib_keys:     []string,
	platform:     string,
}

when ODIN_OS == .Darwin {
	@(private)
	HOST :: Release_Host {
		preset       = "macOS",
		templates    = {"macos.zip"},
		version_keys = {"application/short_version", "application/version"},
		lib_keys     = {"macos.release", "macos.arm64", "macos"},
		platform     = "macos-arm64",
	}
} else {
	@(private)
	HOST :: Release_Host {
		preset       = "Windows Desktop",
		// Godot checks for the debug template too, even for a release export.
		templates    = {"windows_release_x86_64.exe", "windows_debug_x86_64.exe"},
		version_keys = {"application/file_version", "application/product_version"},
		lib_keys     = {"windows.release.x86_64", "windows.x86_64", "windows.release", "windows"},
		platform     = "windows-x64",
	}
}

@(private)
SMOKE_MARKER :: "unified: extension initialized"
@(private)
SMOKE_TICKS :: 256 // the smoke test's session: ~4 s at 64 Hz
@(private)
SMOKE_FRAMES :: 1200 // at --max-fps 60, ~20 s: the session must have ended (and quit) well before

// Where `release` keeps the originals of the files it stamps while it runs (swap_text), so a killed run's stamps are
// undone by the next run before it reads them, relative to the project's .out/.
RELEASE_BACKUPS :: "release/restore"

@(private)
Release_Opts :: struct {
	game:     string `args:"pos=0" usage:"a game (default: every game with export_presets.cfg, in turn)"`,
	version:  string `usage:"the version to stamp (default: dev-<commit>)"`,
	no_eos:   bool `usage:"no online play: no EOS SDK or IDs in the package (CI has neither); single player and LAN"`,
	no_devui: bool `usage:"no dev UI (overlay, panels, F3 notes): the build for the public; playtest builds keep it"`,
}

@(private)
cmd_release :: proc(args: []string) -> Result {
	opts: Release_Opts
	parse(&opts, args)
	when ODIN_OS != .Darwin && ODIN_OS != .Windows {
		fatal("game builds are made on macOS and Windows only")
	} else when ODIN_OS == .Darwin && ODIN_ARCH != .arm64 {
		fatal("macOS builds are arm64 and need an Apple Silicon host")
	}
	// a run killed while its stamps were in place (Ctrl-C) left their originals: those come back first
	for path in restore_backups(join(state.project.out, RELEASE_BACKUPS)) {
		log("release: %s put back as it was before a release that did not finish", rel(path))
	}
	version := opts.version
	games: [dynamic]Game
	if opts.game != "" {
		append(&games, game(opts.game))
	} else {
		for game in state.project.games {
			if os.is_file(join(game.dir, "export_presets.cfg")) do append(&games, game)
		}
		if len(games) == 0 {
			fatal("no game has an export_presets.cfg")
		}
	}
	if version == "" {
		commit := short_commit(state.project.root)
		version = aprintf("dev-%s", commit != "" ? commit : "local")
	}
	if !valid_version(version) {
		usage("bad version %q (letters, digits, . + - only)", version)
	}
	zips: [dynamic]string
	for game in games {
		append(&zips, release_build(game, version, opts.no_eos, opts.no_devui))
	}
	return {ok = true, summary = strings.join(zips[:], "\n"), data = box(zips[:])}
}

// Whether a version can be stamped and name a zip: letters, digits, `.`, `+` and `-`, starting with a letter or digit.
valid_version :: proc(version: string) -> bool {
	if version == "" || !(is_alnum(version[0])) {
		return false
	}
	for char in version {
		if !(char < 128 && is_alnum(u8(char)) || char == '.' || char == '+' || char == '-') {
			return false
		}
	}
	return true
}

@(private)
is_alnum :: proc(char: u8) -> bool {
	return char >= '0' && char <= '9' || char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z'
}

// The version as a zip's name shows it: `v0.1.2` for a release's, a dev version (`dev-<sha>`) as it is.
release_label :: proc(version: string) -> string {
	return version[0] >= '0' && version[0] <= '9' ? aprintf("v%s", version) : version
}

// What goes into the platforms' numeric version fields (macOS CFBundle*Version, Windows file version): the version's
// numbers (a release's 0.1.1; a release candidate's 0.2.0-rc.1: 0.2.0), else 0.0.0 (local builds: dev-<commit>).
platform_version :: proc(version: string) -> string {
	numbers, _, _ := strings.partition(version, "-")
	parts := strings.split(numbers, ".")
	if len(parts) > 4 {
		return "0.0.0"
	}
	for part in parts {
		if part == "" {
			return "0.0.0"
		}
		for char in part {
			if char < '0' || char > '9' {
				return "0.0.0"
			}
		}
	}
	return numbers
}

@(private)
short_commit :: proc(dir: string) -> string {
	ran := run_proc({
		cmd     = strs("git", "-C", dir, "rev-parse", "--short", "HEAD"),
		capture = true,
		quiet   = true,
	})
	return strings.trim_space(ran.stdout)
}

@(private)
release_step :: proc(name: string) -> time.Tick {
	log("release: == %s", name)
	return time.tick_now()
}

// One game's package; the zip's path.
@(private)
release_build :: proc(game: Game, version: string, no_eos: bool, no_devui := false) -> string {
	start := time.tick_now()
	if !os.is_file(join(game.dir, "export_presets.cfg")) {
		fatal("%s has no export_presets.cfg", game.name)
	}
	uses_eos := extension_uses_eos(game)
	if uses_eos && no_eos {
		// nothing of EOS goes in: no IDs compiled in (whatever this shell holds), no SDK library shipped
		for key in EOS_ENV_DEFINES do os.unset_env(key)
		log("release: --no-eos: single player and LAN only, no online play")
	} else if uses_eos {
		missing: [dynamic]string
		for key in EOS_ENV_DEFINES {
			if os.get_env(key, context.temp_allocator) == "" {
				append(&missing, key)
			}
		}
		if len(missing) > 0 {
			fatal(
				"%s's extension imports unified:eos: set %s (the environment or .env), or build with --no-eos",
				game.name,
				strings.join(missing[:], ", "),
			)
		}
		if problem := eos_problem(); problem != "" {
			fatal("the EOS SDK: %s (or build with --no-eos)", problem)
		}
	}
	started := release_step("game extension (release)")
	libs := release_libraries(game)
	if no_devui do log("release: --no-devui: the extension without the dev UI")
	ensure_extension(game, .release, force = true, defines = no_devui ? strs("-define:UNIFIED_DEVUI=false") : nil)
	for lib in libs {
		if !os.is_file(lib) {
			fatal("the .gdextension names %s, which the build did not produce", lib)
		}
	}
	if uses_eos && !no_eos {
		check_embedded(libs)
	}
	log("release: extension in %.1fs", seconds_since(started))
	started = release_step("Godot + export templates")
	editor := godot()
	ensure_templates()
	log("release: Godot and templates in %.1fs", seconds_since(started))
	write_extension_list(game)
	target: string
	{
		// stamped for the export only, and put back right after it; a failure on the way puts them back too
		stamp_version(game, version)
		if no_eos do drop_eos_dependency(game)
		release_godot(editor, game, {"--import"}, "import", 600)
		target = release_export(editor, game)
		restore_texts()
	}
	check_version(target, version)
	files: [dynamic]string
	append(&files, ..libs)
	for dependency in release_dependencies(game) do if !(no_eos && is_eos_lib(dependency)) do append(&files, dependency)
	check_payload(target, files[:])
	if no_eos {
		check_no_eos(target)
	}
	zip := join(
		game.dir,
		".out",
		"release",
		aprintf("%s-%s-%s%s.zip", game.name, release_label(version), HOST.platform, no_devui ? "-nodevui" : ""),
	)
	sign_and_zip(target, zip)
	release_smoke(zip, game.name, no_devui)
	log("release: %s done in %.1fs", game.name, seconds_since(start))
	return zip
}

// Every GDExtension library this host's export ships.
@(private)
release_libraries :: proc(game: Game) -> []string {
	out: [dynamic]string
	for ext in gdextensions(game.dir) {
		config, _ := config_load(ext)
		found := false
		for key in HOST.lib_keys {
			if value, ok := config_get(config, "libraries", key); ok {
				append(&out, res_path(game, value))
				found = true
				break
			}
		}
		if !found {
			fatal("%s has no library for this platform (keys: %s)", ext, strings.join(HOST.lib_keys, ", "))
		}
	}
	if len(out) == 0 {
		fatal("%s has no .gdextension", game.name)
	}
	return out[:]
}

// Files the .gdextension [dependencies] sections ship with this host's export (the EOS SDK).
@(private)
release_dependencies :: proc(game: Game) -> []string {
	out: [dynamic]string
	for ext in gdextensions(game.dir) {
		config, _ := config_load(ext)
		for key in HOST.lib_keys {
			if value, ok := config_get(config, "dependencies", key); ok {
				rest := value
				for {
					start := strings.index(rest, `"res://`)
					if start < 0 {
						break
					}
					rest = rest[start + 1:]
					end := strings.index_byte(rest, '"')
					if end < 0 {
						break
					}
					append(&out, res_path(game, rest[:end]))
					rest = rest[end + 1:]
				}
				break
			}
		}
	}
	return out[:]
}

@(private)
res_path :: proc(game: Game, res: string) -> string {
	if !strings.has_prefix(res, "res://") {
		fatal("library path %q is not a res:// path", res)
	}
	return join(game.dir, res[len("res://"):])
}

// Each EOS value is compiled into one of the libraries (found as bytes; the values are never printed).
@(private)
check_embedded :: proc(libs: []string) {
	blobs := make([]string, len(libs))
	for lib, i in libs {
		blobs[i] = must_read(lib)
	}
	absent: [dynamic]string
	for key in EOS_ENV_DEFINES {
		value := os.get_env(key, context.temp_allocator)
		found := false
		for blob in blobs {
			if strings.contains(blob, value) {
				found = true
			}
		}
		if !found {
			append(&absent, key)
		}
	}
	if len(absent) > 0 {
		fatal("the extension does not contain the value of %s", strings.join(absent[:], ", "))
	}
	log("release: the EOS IDs are compiled into the extension")
}

// --- export templates -------------------------------------------------------------------------------------------

// This host's export templates in Godot's own folder, pulled out of the official archive (~120 MB of 1.3 GB with
// range reads), each file checked against its pin.
@(private)
ensure_templates :: proc() {
	version := pin("godot", "version")
	dir := join(godot_user_dir(), "export_templates", aprintf("%s.stable", version))
	need: [dynamic]string
	for name in HOST.templates {
		if !os.is_file(join(dir, name)) {
			append(&need, name)
		}
	}
	if !os.is_file(join(dir, "version.txt")) {
		append(&need, "version.txt")
	}
	if len(need) == 0 {
		return
	}
	url := aprintf(
		"https://github.com/godotengine/godot/releases/download/%s-stable/Godot_v%s-stable_export_templates.tpz",
		version,
		version,
	)
	log("release: export templates %s from %s (range reads)", strings.join(need[:], ", "), url)
	archive := zip_open_url(url)
	entries := zip_entries(&archive)
	for name in need {
		found := false
		for entry in entries {
			if entry.name == aprintf("templates/%s", name) {
				data := zip_read(&archive, entry)
				part := join(dir, aprintf("%s.part", name))
				if !write_file(part, data) {
					fatal("cannot write %s", part)
				}
				check_sha256(part, pin("godot_templates", name), aprintf("export template %s", name))
				os.rename(part, join(dir, name))
				found = true
			}
		}
		if !found {
			fatal("the templates archive has no %s", name)
		}
	}
	if strings.trim_space(must_read(join(dir, "version.txt"))) != aprintf("%s.stable", version) {
		fatal("unexpected templates version in %s", dir)
	}
	log("release: templates ready (%d MB fetched)", archive.fetched >> 20)
}

// --- the version ------------------------------------------------------------------------------------------------

// Stamps the version into project.godot (application/config/version, which the game shows) and the export
// preset's version keys, for the export: swap_text keeps the originals, restore_texts (or a failure) puts them back.
@(private)
stamp_version :: proc(game: Game, version: string) {
	proj := join(game.dir, "project.godot")
	presets := join(game.dir, "export_presets.cfg")
	backups := join(state.project.out, RELEASE_BACKUPS)
	swap_text(proj, set_keys(must_read(proj), "application", {"config/version"}, version, "project.godot"), backups)
	section := ""
	text := must_read(presets)
	lines := strings.split_lines(text)
	current := ""
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "[") {
			current = strings.trim(trimmed, "[]")
		} else if strings.has_prefix(current, "preset.") &&
		   !strings.contains(current, ".options") &&
		   trimmed == aprintf(`name="%s"`, HOST.preset) {
			section = current
		}
	}
	if section == "" {
		fatal("export_presets.cfg has no %q preset", HOST.preset) // the project.godot stamp is undone
	}
	num := platform_version(version)
	swap_text(
		presets,
		set_keys(text, aprintf("%s.options", section), HOST.version_keys, num, "export_presets.cfg"),
		backups,
	)
	log("release: version %s (platform fields %s) stamped for the export", version, num)
}

// `text` (a Godot ConfigFile) with each key in [section] set to the quoted value; every key must be there exactly
// once.
set_keys :: proc(text, section: string, keys: []string, value, what: string) -> string {
	lines := strings.split(text, "\n")
	current := ""
	seen := make([]int, len(keys))
	for &line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "[") {
			current = strings.trim(trimmed, "[]")
		} else if current == section {
			eq := strings.index_byte(trimmed, '=')
			if eq < 0 {
				continue
			}
			name := strings.trim_space(trimmed[:eq])
			for key, i in keys {
				if name == key {
					line = aprintf(`%s="%s"`, key, value)
					seen[i] += 1
				}
			}
		}
	}
	for count, i in seen {
		if count != 1 {
			fatal("%s [%s] must set %s once", what, section, keys[i])
		}
	}
	return strings.join(lines, "\n")
}

// The export carries the stamped version: in the .pck's project settings (what the game shows) and, on macOS, in
// Info.plist.
@(private)
check_version :: proc(target, version: string) {
	root := os.is_directory(target) ? target : os.dir(target)
	pcks := find_files(root, ".pck")
	if len(pcks) != 1 {
		fatal("expected one .pck in the export, found %d", len(pcks))
	}
	data := must_read(pcks[0])
	key := "application/config/version"
	index := strings.index(data, key)
	want := make([]byte, 4 + len(version))
	endian.put_u32(want, .Little, u32(len(version)))
	copy(want[4:], version)
	if index < 0 ||
	   !strings.contains(data[index + len(key):min(len(data), index + len(key) + 16 + len(version))], string(want)) {
		fatal("%s does not carry application/config/version = %s", os.base(pcks[0]), version)
	}
	when ODIN_OS == .Darwin {
		plist := must_read(join(target, "Contents", "Info.plist"))
		num := platform_version(version)
		for plist_key in ([]string{"CFBundleShortVersionString", "CFBundleVersion"}) {
			if plist_string(plist, plist_key) != num {
				fatal("Info.plist has %s = %q, want %s", plist_key, plist_string(plist, plist_key), num)
			}
		}
	}
	log("release: the export carries version %s", version)
}

// A <string> value of an XML plist key.
@(private)
plist_string :: proc(plist, key: string) -> string {
	index := strings.index(plist, aprintf("<key>%s</key>", key))
	if index < 0 {
		return ""
	}
	rest := plist[index:]
	open := strings.index(rest, "<string>")
	close := strings.index(rest, "</string>")
	if open < 0 || close < open {
		return ""
	}
	return rest[open + len("<string>"):close]
}

// --- Godot steps ------------------------------------------------------------------------------------------------

// The lines of a Godot run's output that fail a release step: an error line, a parse error, an extension library
// that did not load, a resource that failed to load.
release_errors :: proc(text: string) -> []string {
	out: [dynamic]string
	for line in strings.split_lines(text) {
		trimmed := strings.trim_left_space(line)
		trimmed = strings.trim_prefix(trimmed, "USER ")
		trimmed = strings.trim_prefix(trimmed, "SCRIPT ")
		if strings.has_prefix(trimmed, "ERROR") ||
		   strings.contains(line, "Parse Error") ||
		   strings.contains(line, "Can't open dynamic library") ||
		   strings.contains(line, "GDExtension dynamic library not found") ||
		   strings.contains(line, "Failed loading resource") {
			append(&out, strings.trim_space(line))
		}
	}
	return out[:]
}

// One headless Godot run on the game for a release (the import, the export); its error lines (release_errors) or a
// failed exit stop the command.
@(private)
release_godot :: proc(editor: string, game: Game, args: []string, what: string, timeout_s: f64) {
	started := release_step(what)
	cmd: [dynamic]string
	append(&cmd, editor, "--headless", "--path", game.dir)
	append(&cmd, ..args)
	ran := run_proc({
		cmd     = cmd[:],
		capture = true,
		timeout = time.Duration(timeout_s * f64(time.Second)),
	})
	out := strings.concatenate({ran.stdout, ran.stderr})
	errs := release_errors(out)
	if !ran.ok || len(errs) > 0 {
		log("%s", tail(out, 20000))
		fatal(
			"%s failed (exit %d, %d error line(s)): %s",
			what,
			ran.exit_code,
			len(errs),
			strings.join(errs[:min(5, len(errs))], "; "),
		)
	}
	log("release: %s in %.1fs", what, seconds_since(started))
}

// The game exported with this host's preset into <game>/.out/export/<platform>/; the export's path.
@(private)
release_export :: proc(editor: string, game: Game) -> string {
	out_dir := join(game.dir, ".out", "export", HOST.platform)
	remove_tree(out_dir)
	make_dirs(out_dir)
	target := join(out_dir, aprintf("%s%s", game.name, ODIN_OS == .Darwin ? ".app" : ".exe"))
	release_godot(
		editor,
		game,
		strs("--export-release", HOST.preset, target),
		aprintf("export (%s)", HOST.preset),
		600,
	)
	if !os.exists(target) {
		fatal("the export produced no %s", target)
	}
	return target
}

// Every library the game needs made it into the export, as a real file (not a link into .out/), arm64 on macOS.
@(private)
check_payload :: proc(target: string, files: []string) {
	root := os.is_directory(target) ? target : os.dir(target)
	for file in files {
		name := os.base(file)
		found := find_files(root, name)
		hit := ""
		for path in found {
			if os.base(path) == name {
				hit = path
			}
		}
		if hit == "" {
			fatal("%s is missing from the export", name)
		}
		if info, err := os.stat_do_not_follow_links(hit, context.temp_allocator); err == nil && info.type == .Symlink {
			fatal("%s is a symlink in the export", name)
		}
		when ODIN_OS == .Darwin {
			if strings.has_suffix(name, ".dylib") && !strings.contains(lipo_archs(hit), "arm64") {
				fatal("%s has architectures %s, want arm64", name, lipo_archs(hit))
			}
		}
	}
}

@(private)
lipo_archs :: proc(path: string) -> string {
	return strings.trim_space(run_proc({
			cmd     = strs("lipo", "-archs", path),
			capture = true,
			quiet   = true,
		}).stdout)
}

// macOS: the template is universal only; our extension is arm64, so every universal binary is thinned to arm64 (the
// download shrinks by about half the engine). Their signatures break; the ad-hoc codesign after re-signs it all.
@(private)
thin_to_arm64 :: proc(app: string) {
	files: [dynamic]string
	append(&files, ..find_files(join(app, "Contents", "MacOS"), ""))
	append(&files, ..find_files(join(app, "Contents", "Frameworks"), ".dylib"))
	for file in files {
		if len(strings.fields(lipo_archs(file))) > 1 {
			must_run({cmd = strs("lipo", file, "-thin", "arm64", "-output", file)}, "lipo")
		}
	}
}

// macOS: thinned, signed ad hoc and zipped with ditto; Windows: zipped by us. The zip unpacks to one folder named like
// it, with the game inside; its .sha256 beside it.
@(private)
sign_and_zip :: proc(target, zip: string) {
	started := release_step("sign + zip")
	make_dirs(os.dir(zip))
	os.remove(zip)
	stem := os.stem(zip)
	when ODIN_OS == .Darwin {
		thin_to_arm64(target)
		must_run({cmd = strs("codesign", "--force", "--deep", "-s", "-", target)}, "codesign")
		must_run({cmd = strs("codesign", "--verify", "--deep", "--strict", target)}, "codesign --verify")
		// the .app inside one folder named like the zip
		folder := join(os.dir(target), stem)
		make_dirs(folder)
		moved := join(folder, os.base(target))
		if os.rename(target, moved) != nil {
			fatal("cannot move %s", target)
		}
		must_run({cmd = strs("ditto", "-c", "-k", "--keepParent", folder, zip)}, "ditto")
	} else {
		// the exe, its .pck and the libraries, inside one folder named like the zip
		writer: Zip_Writer
		dir := os.dir(target)
		for file in find_files(dir, "") {
			name := slashed(file[len(dir) + 1:])
			zip_add(&writer, aprintf("%s/%s", stem, name), transmute([]byte)must_read(file))
		}
		if !write_file(zip, zip_finish(&writer)) {
			fatal("cannot write %s", zip)
		}
	}
	// LF on every OS: SHA256SUMS.txt concatenates these, and macOS `shasum -c` rejects a CRLF line.
	sum, _ := sha256_file(zip)
	write_text(aprintf("%s.sha256", zip), aprintf("%s  %s\n", sum, os.base(zip)))
	info, _ := os.stat(zip, context.temp_allocator)
	log("release: %s (%.1f MB) in %.1fs", os.base(zip), f64(info.size) / 1e6, seconds_since(started))
}

// Unpacks the zip (what a tester gets) and runs a single-player session of the game headless for a few seconds.
@(private)
release_smoke :: proc(zip, name: string, no_devui: bool) {
	started := release_step("smoke test")
	tmp := join(state.project.out, "tmp", aprintf("smoke-%d", os.get_pid()))
	remove_tree(tmp)
	make_dirs(tmp)
	defer remove_tree(tmp)
	stem := os.stem(zip)
	exe: string
	when ODIN_OS == .Darwin {
		must_run({cmd = strs("ditto", "-x", "-k", zip, tmp)}, "ditto -x")
		bins := find_files(join(tmp, stem, aprintf("%s.app", name), "Contents", "MacOS"), "")
		if len(bins) == 0 {
			fatal("the zip has no app executable")
		}
		exe = bins[0]
	} else {
		archive := zip_open_file(zip)
		zip_extract_all(&archive, tmp)
		exe = join(tmp, stem, aprintf("%s.exe", name))
	}
	log_file := join(tmp, "smoke.log")
	ran := run_proc({
		cmd     = strs(
			exe,
			"--headless",
			"--log-file",
			log_file,
			"--max-fps",
			"60",
			"--quit-after",
			aprintf("%d", SMOKE_FRAMES),
			"--",
			"--autostart",
			"--ticks",
			aprintf("%d", SMOKE_TICKS),
			"--quit-at-end",
		),
		dir     = tmp,
		capture = true,
		timeout = 90 * time.Second,
	})
	out := strings.concatenate({ran.stdout, ran.stderr})
	if text, ok := read_text(log_file); ok {
		out = strings.concatenate({out, "\n", text})
	}
	errs := release_errors(out)
	problems: [dynamic]string
	if ran.timed_out {
		append(&problems, "did not quit within 90 s")
	} else if ran.exit_code != 0 {
		append(&problems, aprintf("exit %d", ran.exit_code))
	}
	if len(errs) > 0 {
		append(&problems, aprintf("%d error line(s): %s", len(errs), strings.join(errs[:min(5, len(errs))], "; ")))
	}
	if !strings.contains(out, SMOKE_MARKER) {
		append(&problems, aprintf("no %q line (the extension did not load)", SMOKE_MARKER))
	} else if devui := no_devui ? "dev ui off" : "dev ui on"; !strings.contains(out, devui) {
		append(&problems, aprintf("the extension did not say %q", devui))
	}
	report, has_report := last_json_after(out, "unified: result ").(json.Object)
	if !has_report {
		append(&problems, "no session result line (the session did not end)")
	} else if final := json_int(report["final_tick"]); final != SMOKE_TICKS {
		append(&problems, aprintf("the session ended at tick %d, not %d", final, SMOKE_TICKS))
	}
	if len(problems) > 0 {
		log("%s", tail(out, 20000))
		fatal("smoke test failed: %s", strings.join(problems[:], ", "))
	}
	log("release: smoke test ok (%d ticks, exit 0, no errors) in %.1fs", SMOKE_TICKS, seconds_since(started))
}

// --no-eos: the export holds no EOS SDK library, under any platform's name. The IDs can't be looked for without
// their values, but without the library no build goes online.
@(private)
check_no_eos :: proc(target: string) {
	root := os.is_directory(target) ? target : os.dir(target)
	for path in find_files(root, "") {
		if is_eos_lib(os.base(path)) {
			fatal("--no-eos, but the export holds the EOS SDK library %s", path)
		}
	}
}

@(private)
is_eos_lib :: proc(path: string) -> bool {
	return strings.contains(path, "EOSSDK")
}

// --no-eos: each .gdextension's [dependencies] without the EOS SDK library, for the export (it would fail on the
// missing file), swapped for the export like the version (swap_text). A line is
// `key = { "res://a": "dir", "res://b": "dir" }`.
@(private)
drop_eos_dependency :: proc(game: Game) {
	for ext in gdextensions(game.dir) {
		text := must_read(ext)
		lines := strings.split(text, "\n")
		section := ""
		for &line in lines {
			trimmed := strings.trim_space(line)
			if strings.has_prefix(trimmed, "[") do section = trimmed
			open, close := strings.index_byte(line, '{'), strings.last_index_byte(line, '}')
			if section != "[dependencies]" || !strings.contains(line, "EOSSDK") || open < 0 || close < open do continue
			kept: [dynamic]string
			for raw in strings.split(line[open + 1:close], `, "`) {
				entry := strings.trim_space(raw)
				if strings.contains(entry, "EOSSDK") do continue
				append(&kept, strings.has_prefix(entry, `"`) ? entry : aprintf(`"%s`, entry))
			}
			body := strings.join(kept[:], ", ")
			pad := len(kept) > 0 ? " " : ""
			// (not fmt: a brace in a format string starts an argument index)
			line = strings.concatenate({line[:open], "{", pad, body, pad, "}"}, context.temp_allocator)
		}
		swap_text(ext, strings.join(lines, "\n"), join(state.project.out, RELEASE_BACKUPS))
	}
}
