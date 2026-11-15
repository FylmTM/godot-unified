package main

import "core:encoding/endian"
import "core:os"
import "core:strings"
import "core:time"

import "unified:cli"

// A playable game build (the `release` skill): the host platform's package (macOS arm64 on a Mac, Windows x64 on
// Windows) in <game>/.out/release/: <game>-v<version>-<platform>.zip (local builds: <game>-dev-<sha>-<platform>.zip)
// unpacking to one folder of the same name with the app, and its .sha256. The same command runs locally and in
// .github/workflows/release.yml (tag builds). Steps, each failing loudly:
//   1. the game's extension in release mode; when it imports unified:eos, the EOS SDK (UNIFIED_EOS_SDK) and the EOS
//      IDs (UNIFIED_EOS_*, the environment or .env) must be there, and their values must end up in the library;
//      with --no-eos (CI, which has neither) the package is single player and LAN only: no IDs, no SDK library,
//   2. the pinned Godot and this host's export templates (pulled out of the official archive with HTTP range reads,
//      each file checked against its pin) in Godot's own folder,
//   3. the version stamped into project.godot and the export preset's version keys for the export (the files are
//      restored byte for byte after); the export must carry it (.pck, macOS Info.plist),
//   4. headless import, then --export-release with the game's preset; any error line fails,
//   5. macOS: arm64 only (lipo), ad-hoc codesign, verify, ditto zip; Windows: our zip, the same folder layout,
//   6. smoke test: the unpacked zip runs headless for ~5 s (`-- --smoke-test`): exit 0, no error line, and the
//      extension's `unified: extension initialized` line.

Release_Host :: struct {
	preset:       string,
	templates:    []string,
	version_keys: []string,
	lib_keys:     []string,
	platform:     string,
}

when ODIN_OS == .Darwin {
	HOST :: Release_Host {
		preset       = "macOS",
		templates    = {"macos.zip"},
		version_keys = {"application/short_version", "application/version"},
		lib_keys     = {"macos.release", "macos.arm64", "macos"},
		platform     = "macos-arm64",
	}
} else {
	HOST :: Release_Host {
		preset       = "Windows Desktop",
		// Godot checks for the debug template too, even for a release export.
		templates    = {"windows_release_x86_64.exe", "windows_debug_x86_64.exe"},
		version_keys = {"application/file_version", "application/product_version"},
		lib_keys     = {"windows.release.x86_64", "windows.x86_64", "windows.release", "windows"},
		platform     = "windows-x64",
	}
}

SMOKE_MARKER :: "unified: extension initialized"
SMOKE_FRAMES :: 300 // at --max-fps 60: ~5 s

cmd_release :: proc(args: []string) -> cli.Result {
	if len(args) > 0 && args[0] == "notes" {
		return release_notes(args[1:])
	}
	Opts :: struct {
		game:     string `args:"pos=0" usage:"the game (default: the tag's, or the only one)"`,
		version:  string `usage:"the version to stamp (default: the tag's, or dev-<commit>)"`,
		tag:      string `usage:"a release tag, <game>-v<version>: the game and version come from it"`,
		no_eos:   bool `usage:"no online play: no EOS SDK or IDs in the package (CI has neither); single player and LAN"`,
		no_smoke: bool `usage:"skip the smoke test"`,
	}
	opts: Opts
	cli.parse(&opts, args)
	when ODIN_OS != .Darwin && ODIN_OS != .Windows {
		cli.fatal("game builds are made on macOS and Windows only")
	} else when ODIN_OS == .Darwin && ODIN_ARCH != .arm64 {
		cli.fatal("macOS builds are arm64 and need an Apple Silicon host")
	}
	game_name, version := opts.game, opts.version
	if opts.tag != "" {
		tg, tv := split_tag(opts.tag)
		if game_name != "" && game_name != tg {
			cli.usage("the tag %s is for %s, not %s", opts.tag, tg, game_name)
		}
		if version != "" && version != tv {
			cli.usage("the tag %s is version %s, not %s", opts.tag, tv, version)
		}
		game_name, version = tg, tv
	}
	g := cli.game(game_name)
	if version == "" {
		c := short_commit(g.dir)
		version = cli.tprint("dev-%s", c != "" ? c : "local")
	}
	if !valid_version(version) {
		cli.usage("bad version %q (letters, digits, . + - only)", version)
	}
	return release_build(g, version, !opts.no_smoke, opts.no_eos)
}

// <game>-v<version> -> game, version
split_tag :: proc(tag: string) -> (game, version: string) {
	i := strings.last_index(tag, "-v")
	if i <= 0 || i + 2 >= len(tag) {
		cli.usage("a release tag is <game>-v<version>, e.g. survivor-v0.1.0 (got %s)", tag)
	}
	return tag[:i], tag[i + 2:]
}

valid_version :: proc(v: string) -> bool {
	if v == "" || !(is_alnum(v[0])) {
		return false
	}
	for c in v {
		if !(c < 128 && is_alnum(u8(c)) || c == '.' || c == '+' || c == '-') {
			return false
		}
	}
	return true
}

is_alnum :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// `v0.1.2` for a release version, a dev version (`dev-<sha>`) as is: the zip names use it.
release_label :: proc(version: string) -> string {
	return version[0] >= '0' && version[0] <= '9' ? cli.tprint("v%s", version) : version
}

// What goes into the platforms' numeric version fields (macOS CFBundle*Version, Windows file version): the version
// itself when it is numeric (tags: 0.1.1), else 0.0.0 (local builds).
platform_version :: proc(version: string) -> string {
	parts := strings.split(version, ".")
	if len(parts) > 4 {
		return "0.0.0"
	}
	for p in parts {
		if p == "" {
			return "0.0.0"
		}
		for c in p {
			if c < '0' || c > '9' {
				return "0.0.0"
			}
		}
	}
	return version
}

short_commit :: proc(dir: string) -> string {
	r := cli.run_proc({
		cmd     = cli.strs("git", "-C", dir, "rev-parse", "--short", "HEAD"),
		capture = true,
		quiet   = true,
	})
	return strings.trim_space(r.stdout)
}

step :: proc(name: string) -> time.Tick {
	cli.log("release: == %s", name)
	return time.tick_now()
}

release_build :: proc(g: cli.Game, version: string, smoke_test: bool, no_eos: bool) -> cli.Result {
	start := time.tick_now()
	if !os.is_file(cli.join(g.dir, "export_presets.cfg")) {
		cli.fatal("%s has no export_presets.cfg", g.name)
	}
	uses_eos := cli.extension_uses_eos(g)
	if uses_eos && no_eos {
		// nothing of EOS goes in: no IDs compiled in (whatever this shell holds), no SDK library shipped
		for k in cli.EOS_ENV_DEFINES do os.unset_env(k)
		cli.log("release: --no-eos: single player and LAN only, no online play")
	} else if uses_eos {
		missing: [dynamic]string
		for k in cli.EOS_ENV_DEFINES {
			if os.get_env(k, context.temp_allocator) == "" {
				append(&missing, k)
			}
		}
		if len(missing) > 0 {
			cli.fatal(
				"%s's extension imports unified:eos: set %s (the environment or .env), or build with --no-eos",
				g.name,
				strings.join(missing[:], ", "),
			)
		}
		if problem := cli.eos_problem(); problem != "" {
			cli.fatal("the EOS SDK: %s (or build with --no-eos)", problem)
		}
	}
	t := step("game extension (release)")
	libs := release_libraries(g)
	cli.ensure_extension(g, .release, force = true)
	for l in libs {
		if !os.is_file(l) {
			cli.fatal("the .gdextension names %s, which the build did not produce", l)
		}
	}
	if uses_eos && !no_eos {
		check_embedded(libs)
	}
	cli.log("release: extension in %.1fs", cli.seconds_since(t))
	t = step("Godot + export templates")
	godot := cli.godot()
	ensure_templates()
	cli.log("release: Godot and templates in %.1fs", cli.seconds_since(t))
	cli.write_extension_list(g)
	target: string
	{
		restore := stamp_version(g, version)
		defer restore_files(restore)
		unship := no_eos ? drop_eos_dependency(g) : nil // restored with the version, after the export
		defer restore_files(unship)
		godot_step(godot, g, {"--import"}, "import", 600)
		target = export(godot, g)
	}
	check_version(target, version)
	files: [dynamic]string
	append(&files, ..libs)
	for d in release_dependencies(g) do if !(no_eos && is_eos_lib(d)) do append(&files, d)
	check_payload(target, files[:])
	zip := cli.join(
		g.dir,
		".out",
		"release",
		cli.tprint("%s-%s-%s.zip", g.name, release_label(version), HOST.platform),
	)
	sign_and_zip(target, zip)
	if smoke_test {
		smoke(zip, g.name)
	}
	cli.log("release: done in %.1fs", cli.seconds_since(start))
	return {
		ok      = true,
		summary = zip,
		data    = cli.box(zip),
	}
}

// Every GDExtension library this host's export ships.
release_libraries :: proc(g: cli.Game) -> []string {
	out: [dynamic]string
	for ext in cli.gdextensions(g.dir) {
		c, _ := cli.config_load(ext)
		found := false
		for k in HOST.lib_keys {
			if v, ok := cli.config_get(c, "libraries", k); ok {
				append(&out, res_path(g, v))
				found = true
				break
			}
		}
		if !found {
			cli.fatal("%s has no library for this platform (keys: %s)", ext, strings.join(HOST.lib_keys, ", "))
		}
	}
	if len(out) == 0 {
		cli.fatal("%s has no .gdextension", g.name)
	}
	return out[:]
}

// Files the .gdextension [dependencies] sections ship with this host's export (the EOS SDK).
release_dependencies :: proc(g: cli.Game) -> []string {
	out: [dynamic]string
	for ext in cli.gdextensions(g.dir) {
		c, _ := cli.config_load(ext)
		for k in HOST.lib_keys {
			if v, ok := cli.config_get(c, "dependencies", k); ok {
				rest := v
				for {
					i := strings.index(rest, `"res://`)
					if i < 0 {
						break
					}
					rest = rest[i + 1:]
					j := strings.index_byte(rest, '"')
					if j < 0 {
						break
					}
					append(&out, res_path(g, rest[:j]))
					rest = rest[j + 1:]
				}
				break
			}
		}
	}
	return out[:]
}

res_path :: proc(g: cli.Game, res: string) -> string {
	if !strings.has_prefix(res, "res://") {
		cli.fatal("library path %q is not a res:// path", res)
	}
	return cli.join(g.dir, res[len("res://"):])
}

// Each EOS value is compiled into one of the libraries (found as bytes; the values are never printed).
check_embedded :: proc(libs: []string) {
	blobs := make([]string, len(libs))
	for l, i in libs {
		blobs[i] = cli.must_read(l)
	}
	absent: [dynamic]string
	for k in cli.EOS_ENV_DEFINES {
		v := os.get_env(k, context.temp_allocator)
		found := false
		for b in blobs {
			if strings.contains(b, v) {
				found = true
			}
		}
		if !found {
			append(&absent, k)
		}
	}
	if len(absent) > 0 {
		cli.fatal("the extension does not contain the value of %s", strings.join(absent[:], ", "))
	}
	cli.log("release: the EOS IDs are compiled into the extension")
}

// --- export templates -------------------------------------------------------------------------------------------

// This host's export templates in Godot's own folder, pulled out of the official archive (~120 MB of 1.3 GB with
// range reads), each file checked against its pin.
ensure_templates :: proc() {
	version := cli.pin("godot", "version")
	dir := cli.join(cli.godot_user_dir(), "export_templates", cli.tprint("%s.stable", version))
	need: [dynamic]string
	for n in HOST.templates {
		if !os.is_file(cli.join(dir, n)) {
			append(&need, n)
		}
	}
	if !os.is_file(cli.join(dir, "version.txt")) {
		append(&need, "version.txt")
	}
	if len(need) == 0 {
		return
	}
	cli.cold("export templates")
	url := cli.tprint(
		"https://github.com/godotengine/godot/releases/download/%s-stable/Godot_v%s-stable_export_templates.tpz",
		version,
		version,
	)
	cli.log("release: export templates %s from %s (range reads)", strings.join(need[:], ", "), url)
	z := cli.zip_open_url(url)
	entries := cli.zip_entries(&z)
	for n in need {
		found := false
		for e in entries {
			if e.name == cli.tprint("templates/%s", n) {
				data := cli.zip_read(&z, e)
				part := cli.join(dir, cli.tprint("%s.part", n))
				if !cli.write_file(part, data) {
					cli.fatal("cannot write %s", part)
				}
				cli.check_sha256(part, cli.pin("godot_templates", n), cli.tprint("export template %s", n))
				os.rename(part, cli.join(dir, n))
				found = true
			}
		}
		if !found {
			cli.fatal("the templates archive has no %s", n)
		}
	}
	if strings.trim_space(cli.must_read(cli.join(dir, "version.txt"))) != cli.tprint("%s.stable", version) {
		cli.fatal("unexpected templates version in %s", dir)
	}
	cli.log("release: templates ready (%d MB fetched)", z.fetched >> 20)
}

// --- the version ------------------------------------------------------------------------------------------------

Saved_File :: struct {
	path: string,
	data: string,
}

// Stamps the version into project.godot (application/config/version, which the game shows) and the export
// preset's version keys; returns the files' original bytes for `restore_files`.
stamp_version :: proc(g: cli.Game, version: string) -> []Saved_File {
	proj := cli.join(g.dir, "project.godot")
	presets := cli.join(g.dir, "export_presets.cfg")
	saved := make([]Saved_File, 2)
	saved[0] = {proj, cli.must_read(proj)}
	saved[1] = {presets, cli.must_read(presets)}
	cli.write_text(proj, set_keys(saved[0].data, "application", {"config/version"}, version, "project.godot"))
	section := ""
	text := saved[1].data
	lines := strings.split_lines(text)
	current := ""
	for line in lines {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "[") {
			current = strings.trim(l, "[]")
		} else if strings.has_prefix(current, "preset.") &&
		   !strings.contains(current, ".options") &&
		   l == cli.tprint(`name="%s"`, HOST.preset) {
			section = current
		}
	}
	if section == "" {
		restore_files(saved)
		cli.fatal("export_presets.cfg has no %q preset", HOST.preset)
	}
	num := platform_version(version)
	cli.write_text(
		presets,
		set_keys(text, cli.tprint("%s.options", section), HOST.version_keys, num, "export_presets.cfg"),
	)
	cli.log("release: version %s (platform fields %s) stamped for the export", version, num)
	return saved
}

restore_files :: proc(saved: []Saved_File) {
	for f in saved {
		cli.write_text(f.path, f.data)
	}
}

// `text` (a Godot ConfigFile) with each key in [section] set to the quoted value; every key must be there exactly
// once.
set_keys :: proc(text, section: string, keys: []string, value, what: string) -> string {
	lines := strings.split(text, "\n")
	cur := ""
	seen := make([]int, len(keys))
	for &line in lines {
		s := strings.trim_space(line)
		if strings.has_prefix(s, "[") {
			cur = strings.trim(s, "[]")
		} else if cur == section {
			eq := strings.index_byte(s, '=')
			if eq < 0 {
				continue
			}
			k := strings.trim_space(s[:eq])
			for key, i in keys {
				if k == key {
					line = cli.tprint(`%s="%s"`, key, value)
					seen[i] += 1
				}
			}
		}
	}
	for n, i in seen {
		if n != 1 {
			cli.fatal("%s [%s] must set %s once", what, section, keys[i])
		}
	}
	return strings.join(lines, "\n")
}

// The export carries the stamped version: in the .pck's project settings (what the game shows) and, on macOS, in
// Info.plist.
check_version :: proc(target, version: string) {
	root := os.is_directory(target) ? target : os.dir(target)
	pcks := cli.find_files(root, ".pck")
	if len(pcks) != 1 {
		cli.fatal("expected one .pck in the export, found %d", len(pcks))
	}
	data := cli.must_read(pcks[0])
	key := "application/config/version"
	i := strings.index(data, key)
	want := make([]byte, 4 + len(version))
	endian.put_u32(want, .Little, u32(len(version)))
	copy(want[4:], version)
	if i < 0 || !strings.contains(data[i + len(key):min(len(data), i + len(key) + 16 + len(version))], string(want)) {
		cli.fatal("%s does not carry application/config/version = %s", os.base(pcks[0]), version)
	}
	when ODIN_OS == .Darwin {
		plist := cli.must_read(cli.join(target, "Contents", "Info.plist"))
		num := platform_version(version)
		for k in ([]string{"CFBundleShortVersionString", "CFBundleVersion"}) {
			if plist_string(plist, k) != num {
				cli.fatal("Info.plist has %s = %q, want %s", k, plist_string(plist, k), num)
			}
		}
	}
	cli.log("release: the export carries version %s", version)
}

// A <string> value of an XML plist key.
plist_string :: proc(plist, key: string) -> string {
	i := strings.index(plist, cli.tprint("<key>%s</key>", key))
	if i < 0 {
		return ""
	}
	rest := plist[i:]
	a := strings.index(rest, "<string>")
	b := strings.index(rest, "</string>")
	if a < 0 || b < a {
		return ""
	}
	return rest[a + len("<string>"):b]
}

// --- Godot steps ------------------------------------------------------------------------------------------------

release_errors :: proc(text: string) -> []string {
	out: [dynamic]string
	for line in strings.split_lines(text) {
		s := strings.trim_left_space(line)
		s = strings.trim_prefix(s, "USER ")
		s = strings.trim_prefix(s, "SCRIPT ")
		if strings.has_prefix(s, "ERROR") ||
		   strings.contains(line, "Parse Error") ||
		   strings.contains(line, "Can't open dynamic library") ||
		   strings.contains(line, "GDExtension dynamic library not found") ||
		   strings.contains(line, "Failed loading resource") {
			append(&out, strings.trim_space(line))
		}
	}
	return out[:]
}

godot_step :: proc(godot: string, g: cli.Game, args: []string, what: string, timeout_s: f64) {
	t := step(what)
	cmd: [dynamic]string
	append(&cmd, godot, "--headless", "--path", g.dir)
	append(&cmd, ..args)
	r := cli.run_proc({
		cmd     = cmd[:],
		capture = true,
		timeout = time.Duration(timeout_s * f64(time.Second)),
	})
	out := strings.concatenate({r.stdout, r.stderr})
	errs := release_errors(out)
	if !r.ok || len(errs) > 0 {
		cli.log("%s", cli.tail(out, 20000))
		cli.fatal(
			"%s failed (exit %d, %d error line(s)): %s",
			what,
			r.exit_code,
			len(errs),
			strings.join(errs[:min(5, len(errs))], "; "),
		)
	}
	cli.log("release: %s in %.1fs", what, cli.seconds_since(t))
}

export :: proc(godot: string, g: cli.Game) -> string {
	out_dir := cli.join(g.dir, ".out", "export", HOST.platform)
	cli.remove_tree(out_dir)
	cli.make_dirs(out_dir)
	target := cli.join(out_dir, cli.tprint("%s%s", g.name, ODIN_OS == .Darwin ? ".app" : ".exe"))
	godot_step(
		godot,
		g,
		cli.strs("--export-release", HOST.preset, target),
		cli.tprint("export (%s)", HOST.preset),
		600,
	)
	if !os.exists(target) {
		cli.fatal("the export produced no %s", target)
	}
	return target
}

// Every library the game needs made it into the export, as a real file (not a link into .out/), arm64 on macOS.
check_payload :: proc(target: string, files: []string) {
	root := os.is_directory(target) ? target : os.dir(target)
	for f in files {
		name := os.base(f)
		found := cli.find_files(root, name)
		hit := ""
		for p in found {
			if os.base(p) == name {
				hit = p
			}
		}
		if hit == "" {
			cli.fatal("%s is missing from the export", name)
		}
		if fi, err := os.stat_do_not_follow_links(hit, context.temp_allocator); err == nil && fi.type == .Symlink {
			cli.fatal("%s is a symlink in the export", name)
		}
		when ODIN_OS == .Darwin {
			if strings.has_suffix(name, ".dylib") && !strings.contains(lipo_archs(hit), "arm64") {
				cli.fatal("%s has architectures %s, want arm64", name, lipo_archs(hit))
			}
		}
	}
}

lipo_archs :: proc(path: string) -> string {
	return strings.trim_space(cli.run_proc({
			cmd     = cli.strs("lipo", "-archs", path),
			capture = true,
			quiet   = true,
		}).stdout)
}

// macOS: the template is universal only; our extension is arm64, so every universal binary is thinned to arm64 (the
// download shrinks by about half the engine). Their signatures break; the ad-hoc codesign after re-signs it all.
thin_to_arm64 :: proc(app: string) {
	files: [dynamic]string
	append(&files, ..cli.find_files(cli.join(app, "Contents", "MacOS"), ""))
	append(&files, ..cli.find_files(cli.join(app, "Contents", "Frameworks"), ".dylib"))
	for f in files {
		if len(strings.fields(lipo_archs(f))) > 1 {
			cli.must_run({cmd = cli.strs("lipo", f, "-thin", "arm64", "-output", f)}, "lipo")
		}
	}
}

sign_and_zip :: proc(target, zip: string) {
	t := step("sign + zip")
	cli.make_dirs(os.dir(zip))
	os.remove(zip)
	stem := os.stem(zip)
	when ODIN_OS == .Darwin {
		thin_to_arm64(target)
		cli.must_run({cmd = cli.strs("codesign", "--force", "--deep", "-s", "-", target)}, "codesign")
		cli.must_run({cmd = cli.strs("codesign", "--verify", "--deep", "--strict", target)}, "codesign --verify")
		// the .app inside one folder named like the zip
		folder := cli.join(os.dir(target), stem)
		cli.make_dirs(folder)
		moved := cli.join(folder, os.base(target))
		if os.rename(target, moved) != nil {
			cli.fatal("cannot move %s", target)
		}
		cli.must_run({cmd = cli.strs("ditto", "-c", "-k", "--keepParent", folder, zip)}, "ditto")
	} else {
		// the exe, its .pck and the libraries, inside one folder named like the zip
		w: cli.Zip_Writer
		dir := os.dir(target)
		for f in cli.find_files(dir, "") {
			rel, _ := strings.replace_all(f[len(dir) + 1:], "\\", "/")
			cli.zip_add(&w, cli.tprint("%s/%s", stem, rel), transmute([]byte)cli.must_read(f))
		}
		if !cli.write_file(zip, cli.zip_finish(&w)) {
			cli.fatal("cannot write %s", zip)
		}
	}
	// LF on every OS: SHA256SUMS.txt concatenates these, and macOS `shasum -c` rejects a CRLF line.
	sum, _ := cli.sha256_file(zip)
	cli.write_text(cli.tprint("%s.sha256", zip), cli.tprint("%s  %s\n", sum, os.base(zip)))
	fi, _ := os.stat(zip, context.temp_allocator)
	cli.log("release: %s (%.1f MB) in %.1fs", os.base(zip), f64(fi.size) / 1e6, cli.seconds_since(t))
}

// Unpacks the zip (what a tester gets) and runs the game headless for a few seconds.
smoke :: proc(zip, name: string) {
	t := step("smoke test")
	tmp := cli.join(cli.state.project.out, "tmp", cli.tprint("smoke-%d", os.get_pid()))
	cli.remove_tree(tmp)
	cli.make_dirs(tmp)
	defer cli.remove_tree(tmp)
	stem := os.stem(zip)
	exe: string
	when ODIN_OS == .Darwin {
		cli.must_run({cmd = cli.strs("ditto", "-x", "-k", zip, tmp)}, "ditto -x")
		bins := cli.find_files(cli.join(tmp, stem, cli.tprint("%s.app", name), "Contents", "MacOS"), "")
		if len(bins) == 0 {
			cli.fatal("the zip has no app executable")
		}
		exe = bins[0]
	} else {
		z := cli.zip_open_file(zip)
		cli.zip_extract_all(&z, tmp)
		exe = cli.join(tmp, stem, cli.tprint("%s.exe", name))
	}
	log_file := cli.join(tmp, "smoke.log")
	r := cli.run_proc({
		cmd     = cli.strs(
			exe,
			"--headless",
			"--log-file",
			log_file,
			"--max-fps",
			"60",
			"--quit-after",
			cli.tprint("%d", SMOKE_FRAMES),
			"--",
			"--smoke-test",
		),
		dir     = tmp,
		capture = true,
		timeout = 90 * time.Second,
	})
	out := strings.concatenate({r.stdout, r.stderr})
	if text, ok := cli.read_text(log_file); ok {
		out = strings.concatenate({out, "\n", text})
	}
	errs := release_errors(out)
	problems: [dynamic]string
	if r.timed_out {
		append(&problems, "did not quit within 90 s")
	} else if r.exit_code != 0 {
		append(&problems, cli.tprint("exit %d", r.exit_code))
	}
	if len(errs) > 0 {
		append(&problems, cli.tprint("%d error line(s): %s", len(errs), strings.join(errs[:min(5, len(errs))], "; ")))
	}
	if !strings.contains(out, SMOKE_MARKER) {
		append(&problems, cli.tprint("no %q line (the extension did not load)", SMOKE_MARKER))
	}
	if len(problems) > 0 {
		cli.log("%s", cli.tail(out, 20000))
		cli.fatal("smoke test failed: %s", strings.join(problems[:], ", "))
	}
	cli.log("release: smoke test ok (%d frames, exit 0, no errors) in %.1fs", SMOKE_FRAMES, cli.seconds_since(t))
}

// --- notes ------------------------------------------------------------------------------------------------------

NOTES ::
	`Test build of **%[0]s %[1]s** (commit ` +
	"`%[2]s`" +
	`). Unsigned prerelease for playtesting only.%[5]s

## Download

- **macOS** (Apple Silicon): ` +
	"`%[0]s-%[3]s-macos-arm64.zip`" +
	`
- **Windows** (x64): ` +
	"`%[0]s-%[3]s-windows-x64.zip`" +
	`

Each zip unpacks to a folder of the same name with the game inside.

` +
	"`SHA256SUMS.txt`" +
	` has the checksums (` +
	"`shasum -a 256 -c SHA256SUMS.txt` / `certutil -hashfile <zip> SHA256`" +
	`).

## Opening it

- **macOS:** unzip and open ` +
	"`%[0]s.app`" +
	` in the ` +
	"`%[0]s-%[3]s-macos-arm64`" +
	` folder. The app is ad-hoc signed,
  not notarized, so macOS blocks the first launch: click **Done**, open System Settings → Privacy & Security,
  scroll down to the message about ` +
	"`%[0]s`" +
	`, click **Open Anyway** and confirm. (On macOS 14 and older, right-click the app → **Open** → **Open** also works.)
  Last resort, in Terminal: ` +
	"`xattr -dr com.apple.quarantine %[0]s-%[3]s-macos-arm64`" +
	`.
- **Windows:** unzip, run ` +
	"`%[0]s.exe`" +
	` in the ` +
	"`%[0]s-%[3]s-windows-x64`" +
	` folder. If SmartScreen says
  "Windows protected your PC", click **More info** → **Run anyway**.
%[4]s`

// The prerelease notes (markdown) for a tag.
release_notes :: proc(args: []string) -> cli.Result {
	Opts :: struct {
		game:   string `args:"pos=0" usage:"the game (default: the tag's)"`,
		tag:    string `args:"required" usage:"the release tag, <game>-v<version>"`,
		no_eos: bool `usage:"the packages were built with --no-eos: say they have no online play"`,
	}
	opts: Opts
	cli.parse(&opts, args)
	name, version := split_tag(opts.tag)
	if opts.game != "" && opts.game != name {
		cli.usage("the tag %s is for %s, not %s", opts.tag, name, opts.game)
	}
	g := cli.game(name)
	extra := ""
	if text, ok := cli.read_text(cli.join(g.dir, "RELEASE_NOTES.md")); ok {
		extra = cli.tprint("\n%s", text)
	}
	lan := opts.no_eos ? "\n\n**Single player and LAN only:** this build has no online play (no EOS)." : ""
	notes := cli.tprint(NOTES, g.name, version, short_commit(g.dir), release_label(version), extra, lan)
	return {ok = true, summary = strings.trim_right(notes, "\n")}
}

is_eos_lib :: proc(path: string) -> bool {
	return strings.contains(path, "EOSSDK")
}

// --no-eos: each .gdextension's [dependencies] without the EOS SDK library, for the export (it would fail on the
// missing file). A line is `key = { "res://a": "dir", "res://b": "dir" }`. Returns the original bytes for
// `restore_files`.
drop_eos_dependency :: proc(g: cli.Game) -> []Saved_File {
	saved: [dynamic]Saved_File
	for ext in cli.gdextensions(g.dir) {
		text := cli.must_read(ext)
		lines := strings.split(text, "\n")
		section := ""
		for &line in lines {
			l := strings.trim_space(line)
			if strings.has_prefix(l, "[") do section = l
			open, close := strings.index_byte(line, '{'), strings.last_index_byte(line, '}')
			if section != "[dependencies]" || !strings.contains(line, "EOSSDK") || open < 0 || close < open do continue
			kept: [dynamic]string
			for raw in strings.split(line[open + 1:close], `, "`) {
				e := strings.trim_space(raw)
				if strings.contains(e, "EOSSDK") do continue
				append(&kept, strings.has_prefix(e, `"`) ? e : cli.tprint(`"%s`, e))
			}
			body := strings.join(kept[:], ", ")
			pad := len(kept) > 0 ? " " : ""
			// (not fmt: a brace in a format string starts an argument index)
			line = strings.concatenate({line[:open], "{", pad, body, pad, "}"}, context.temp_allocator)
		}
		append(&saved, Saved_File{ext, text})
		cli.write_text(ext, strings.join(lines, "\n"))
	}
	return saved[:]
}
