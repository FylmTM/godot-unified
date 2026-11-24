package cli

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The Godot bindings (src/gdext/*.gen.odin), generated from the committed API dump: no Godot needed. Skipped when
// the inputs (api/*.json, bindings.txt, the generator's source) hash the same as last time and the outputs exist.
// Generating them is first-time work (a fresh checkout or game repo, a Godot upgrade). Checked once per run (the dump
// is several megabytes to hash).
ensure_bindings :: proc(force := false) {
	@(static) checked: bool
	if checked && !force {
		return
	}
	checked = true
	gdext := join(state.project.unified, "src", "gdext")
	inputs: [dynamic]string
	append(&inputs, ..find_files(join(gdext, "api"), ".json"))
	append(&inputs, join(gdext, "bindings.txt"))
	append(&inputs, ..find_files(join(gdext, "gen"), ".odin"))
	builder := strings.builder_make()
	for file in inputs {
		strings.write_string(&builder, rel(file))
		strings.write_byte(&builder, 0)
		strings.write_string(&builder, sha256_hex(transmute([]byte)must_read(file)))
		strings.write_byte(&builder, '\n')
	}
	key := sha256_hex(transmute([]byte)strings.to_string(builder))
	out := join(state.project.out, "gen")
	stamp := join(out, "gdext.stamp")
	outputs := []string{join(gdext, "api.gen.odin"), join(gdext, "gdi", "gdi.gen.odin")}
	if !force && stamp_ok(stamp, key) && os.is_file(outputs[0]) && os.is_file(outputs[1]) {
		return
	}
	start := time.tick_now()
	make_dirs(join(gdext, "gdi"))
	make_dirs(out)
	gen := join(out, aprintf("gdext_gen%s", EXE))
	cmd: [dynamic]string
	append(&cmd, odin(), "build", join(gdext, "gen"), aprintf("-out:%s", gen), "-o:minimal")
	append(&cmd, ..VET)
	must_run({cmd = cmd[:]}, "building the binding generator")
	must_run({cmd = {gen, join(gdext, "api"), join(gdext, "bindings.txt"), gdext}}, "the binding generator")
	write_text(stamp, aprintf("%s\n", key))
	log("uni: the Godot bindings -> src/gdext/*.gen.odin in %.2fs", seconds_since(start))
}

// --- a game's GDExtension -----------------------------------------------------------------------------------------

// The game's library: <game>/.out/bin/lib<game>.dylib (.so, .dll), where its .gdextension points.
extension_lib :: proc(game: Game) -> string {
	return join(game.dir, ".out", "bin", lib_name(game.name))
}

// The build of the game's GDExtension (simulation/extension) as a shared library for `mode`, with the Box3D
// and EOS defines it needs and the game's view index (view_index_define); ensure_extension runs it when stale.
extension_build :: proc(game: Game, mode: Mode) -> Build {
	flags: [dynamic]string
	append(&flags, "-build-mode:dll")
	append(&flags, ..mode_flags(mode))
	append(&flags, ..box3d_defines(mode, game_uses_box3d(game)))
	append(&flags, ..eos_defines(game))
	append(&flags, view_index_define(game.dir)) // a view scene added, moved or renamed rebuilds the extension
	return {
		pkg   = join(game.dir, "simulation", "extension"),
		out   = extension_lib(game),
		flags = flags[:],
	}
}

// Whether the game has a GDExtension to build (simulation/extension) for Godot to load.
has_extension :: proc(game: Game) -> bool {
	return os.is_directory(join(game.dir, "simulation", "extension"))
}

// Builds the game's extension when stale (always with `force`; `defines`: extra -define flags) and returns its
// library: every command that runs the game goes through here. A failed build stops the command.
ensure_extension :: proc(game: Game, mode: Mode, force := false, defines: []string = nil) -> string {
	running, started := start_extension(game, mode, force, defines).?
	if !started {
		return extension_lib(game)
	}
	lib, ok := finish_extension(&running)
	if !ok {
		fatal("building %s's extension failed", game.name)
	}
	return lib
}

// An extension build start_extension started; finish_extension puts it in place.
Extension_Build :: struct {
	game:      Game,
	build:     Build, // to the temporary file, its manifest the library's
	child:     Proc,
	stamp:     string,
	versioned: bool,
	start:     time.Tick,
	mode:      Mode,
}

// Prepares the game's extension and starts its build when stale (always with `force`), without waiting: stages the
// Box3D library next to it (the .gdextension's [dependencies]
// ship it from there; the debug build for --mode debug) and the EOS SDK's. nil when it is current. The build tag
// (-define:UNIFIED_BUILD_TAG=<mode>-<time>) is outside the manifest key, so it doesn't make every build stale.
start_extension :: proc(game: Game, mode: Mode, force := false, defines: []string = nil) -> Maybe(Extension_Build) {
	if !has_extension(game) {
		fatal("%s has no simulation/extension to build", game.name)
	}
	uses_box3d := game_uses_box3d(game)
	if uses_box3d {
		ensure_box3d()
		stage_box3d(os.dir(extension_lib(game)), debug = mode == .debug)
	}
	write_dependencies(game, uses_box3d, extension_uses_eos(game))
	ensure_bindings()
	stage_eos(game)
	build := extension_build(game, mode)
	if len(defines) > 0 { 	// extra -define flags (uni release --no-devui): part of the build's key
		flags: [dynamic]string
		append(&flags, ..build.flags)
		append(&flags, ..defines)
		build.flags = flags[:]
	}
	if !force && !stale(build) {
		write_extension_list(game)
		return nil
	}
	lib := build.out
	make_dirs(os.dir(lib))
	// macOS dev builds get a new file each time and lib<game>.dylib becomes a symlink to it: dyld never unloads an
	// image with thread-locals (Odin's runtime has some), so the editor would keep running the old code.
	versioned := ODIN_OS == .Darwin && mode != .release
	stamp := timestamp(time.now())
	built := build
	built.out =
		versioned ? join(os.dir(lib), aprintf("lib%s-%s.dylib", game.name, stamp)) : aprintf("%s.tmp%s", lib, ODIN_OS == .Windows ? ".dll" : "")
	built.manifest = aprintf("%s.inputs", lib)
	built.unkeyed = strs(aprintf("-define:UNIFIED_BUILD_TAG=%v-%s", mode, stamp[:15]))
	return Extension_Build {
		game      = game,
		build     = built,
		child     = start_build(built),
		stamp     = stamp,
		versioned = versioned,
		start     = time.tick_now(),
		mode      = mode,
	}
}

// Builds the GDExtension of a Godot project that is no game (a test project: package `pkg`, library `stem`) when
// stale, dev, to <dir>/.out/bin/, where its .gdextension points; a failed build stops the command.
ensure_project_extension :: proc(dir, pkg, stem: string) {
	ensure_bindings() // the extension imports unified:gdext, whose bindings are generated
	build := project_extension_build(dir, pkg, stem)
	if !stale(build) do return
	seconds := odin_build(build, aprintf("building %s", rel(pkg)))
	log("uni: %s -> %s in %.2fs", rel(pkg), rel(build.out), seconds)
}

// The `mode` build of a test project's GDExtension (package `pkg`, library `stem`) to <dir>/.out/bin/, with the
// project's view index (view_index_define) when it has view scenes: a test project's extension may not import
// unified:godot, and Odin refuses a define nothing reads.
project_extension_build :: proc(dir, pkg, stem: string, mode: Mode = .dev) -> Build {
	flags: [dynamic]string
	append(&flags, "-build-mode:dll")
	append(&flags, ..mode_flags(mode))
	if index, _ := view_index(dir); index != "" do append(&flags, view_index_define(dir))
	return {pkg = pkg, out = join(dir, ".out", "bin", lib_name(stem)), flags = flags[:]}
}

// Waits for an extension build start_extension started and moves the library into place; false when the build
// failed (the compiler's errors are on the terminal).
finish_extension :: proc(running: ^Extension_Build) -> (lib: string, ok: bool) {
	game, tmp := running.game, running.build.out
	lib = extension_lib(game)
	ran := finish_build(running.build, &running.child)
	if !ran.ok {
		return lib, false
	}
	if running.versioned {
		link := aprintf("%s.new", lib)
		os.remove(link)
		if os.symlink(os.base(tmp), link) != nil || os.rename(link, lib) != nil {
			os.remove(aprintf("%s.inputs", lib)) // not current: the next command builds again
			fatal("cannot point %s at %s", lib, os.base(tmp))
		}
		prune_versions(game)
	} else {
		os.remove(lib)
		when ODIN_OS == .Windows {
			// A running game (or editor) holds the library: it can't be removed, but it can be renamed. The game keeps
			// running on the old file; the next start gets the new one. Old ones go once nothing holds them.
			infos, _ := os.read_all_directory_by_path(os.dir(lib), context.temp_allocator)
			for info in infos do if strings.contains(info.name, ".old-") do os.remove(info.fullpath)
			if os.exists(lib) do os.rename(lib, aprintf("%s.old-%s", lib, running.stamp))
		}
		if os.rename(tmp, lib) != nil {
			os.remove(aprintf("%s.inputs", lib)) // not current: the next command builds again
			fatal("cannot move %s into place (a running game holds it?)", lib)
		}
		when ODIN_OS == .Windows {
			for ext in ([]string{".pdb", ".lib", ".exp"}) {
				from := aprintf("%s%s", tmp[:len(tmp) - 4], ext)
				if os.exists(from) {
					to := aprintf("%s%s", lib[:len(lib) - 4], ext)
					os.remove(to)
					if os.exists(to) do os.rename(to, aprintf("%s.old-%s", to, running.stamp))
					os.rename(from, to)
				}
			}
		}
	}
	write_extension_list(game)
	log("uni: %s extension (%v) -> %s in %.2fs", game.name, running.mode, rel(lib), seconds_since(running.start))
	return lib, true
}

// Keeps the newest four versioned builds: a running editor may still have older ones mapped.
@(private)
prune_versions :: proc(game: Game) {
	dir := join(game.dir, ".out", "bin")
	infos, _ := os.read_all_directory_by_path(dir, context.allocator)
	prefix := aprintf("lib%s-", game.name)
	builds: [dynamic]os.File_Info
	for info in infos {
		if strings.has_prefix(info.name, prefix) && strings.has_suffix(info.name, ".dylib") && info.type == .Regular {
			append(&builds, info)
		}
	}
	// newest first, by time: the names' stamps are labels, not the order
	slice.sort_by(builds[:], proc(first, second: os.File_Info) -> bool {
		return time.diff(first.modification_time, second.modification_time) < 0
	})
	for info in builds[min(4, len(builds)):] {
		os.remove(info.fullpath)
		remove_tree(aprintf("%s.dSYM", info.fullpath))
	}
}

// 20261111-142309-858: sortable, unique per millisecond.
timestamp :: proc(moment: time.Time) -> string {
	year, month, day := time.date(moment)
	hour, minute, second := time.clock(moment)
	millis := (time.to_unix_nanoseconds(moment) / 1_000_000) % 1000
	return aprintf("%04d%02d%02d-%02d%02d%02d-%03d", year, int(month), day, hour, minute, second, millis)
}

// --- a .gdextension's [dependencies] ------------------------------------------------------------------------------

// The runtime libraries an extension links, on every platform an export targets: the section `uni build` keeps in the
// game's .gdextension (Godot loads them with the extension, an export ships them next to it). Linux has no EOS SDK
// in an export. Empty when it links neither.
dependencies_section :: proc(box3d, eos: bool) -> string {
	if !box3d && !eos do return ""
	Platform :: struct {
		keys:            []string,
		box3d, eos, dir: string,
	}
	PLATFORMS :: []Platform {
		{{"macos.debug", "macos.release"}, "libbox3d.dylib", "libEOSSDK-Mac-Shipping.dylib", "Contents/Frameworks"},
		{{"windows.x86_64"}, "box3d.dll", "EOSSDK-Win64-Shipping.dll", ""},
		{{"linux.x86_64"}, "libbox3d.so", "", ""},
	}
	builder := strings.builder_make()
	strings.write_string(
		&builder,
		"; Runtime libraries Godot loads with ours and the export ships next to it, from what the extension links (Box3D,\n" +
		"; the EOS SDK): written by `uni build`, which also copies this OS's into .out/bin.\n" +
		"[dependencies]\n\n",
	)
	for platform in PLATFORMS {
		libs: [dynamic]string
		if box3d do append(&libs, platform.box3d)
		if eos && platform.eos != "" do append(&libs, platform.eos)
		if len(libs) == 0 do continue
		entries: [dynamic]string
		for lib in libs do append(&entries, aprintf(`"res://.out/bin/%s": "%s"`, lib, platform.dir))
		for key in platform.keys {
			fmt.sbprintf(&builder, "%s = {{ %s }}\n", key, strings.join(entries[:], ", "))
		}
	}
	return strings.to_string(builder)
}

// A .gdextension's text with its [dependencies] section (and the comment lines right above it) replaced by
// `section` (empty: removed), or appended when it has none.
with_dependencies :: proc(text, section: string) -> string {
	lines := strings.split_lines(strings.trim_right(text, "\n"))
	start, end := -1, len(lines)
	for line, i in lines {
		trimmed := strings.trim_space(line)
		if start < 0 && trimmed == "[dependencies]" {
			start = i
			for start > 0 && strings.has_prefix(strings.trim_space(lines[start - 1]), ";") do start -= 1
		} else if start >= 0 && strings.has_prefix(trimmed, "[") {
			end = i
			break
		}
	}
	before := lines[:]
	after: []string
	if start >= 0 {
		before, after = lines[:start], lines[end:]
	}
	head := strings.trim_right(strings.join(before, "\n"), "\n")
	out := strings.builder_make()
	strings.write_string(&out, head)
	strings.write_byte(&out, '\n')
	if section != "" {
		strings.write_byte(&out, '\n')
		strings.write_string(&out, section)
	}
	if len(after) > 0 {
		strings.write_byte(&out, '\n')
		strings.write_string(&out, strings.join(after, "\n"))
		strings.write_byte(&out, '\n')
	}
	return strings.to_string(out)
}

// Keeps the game's .gdextension files' [dependencies] what the extension links (dependencies_section), rewriting a
// missing or stale section: a game never copies it by hand, and one that starts using physics or EOS ships it.
write_dependencies :: proc(game: Game, box3d, eos: bool) {
	section := dependencies_section(box3d, eos)
	for ext in gdextensions(game.dir) {
		text, ok := read_text(ext)
		if !ok do continue
		want := with_dependencies(text, section)
		if want != text {
			write_text(ext, want)
			log("uni: %s: [dependencies] written from what the extension links", rel(ext))
		}
	}
}

// --- Godot's extension list ---------------------------------------------------------------------------------------

// The .gdextension files of a Godot project (godot_files: not in .godot/, .out/ or a game repo's unified/).
gdextensions :: proc(dir: string) -> []string {
	return godot_files(dir, ".gdextension")
}

when ODIN_OS == .Windows {
	LIB_KEYS :: []string{"windows.x86_64", "windows.release.x86_64", "windows.release", "windows"}
} else when ODIN_OS == .Darwin {
	LIB_KEYS :: []string{"macos.debug", "macos.release", "macos.arm64", "macos"}
} else {
	LIB_KEYS :: []string{"linux.x86_64", "linux"}
}

// Godot loads the GDExtensions listed in .godot/extension_list.cfg, which the editor writes on its first scan. This
// writes it for a fresh checkout, listing only extensions whose library for this host exists: a missing library is
// an error on every run (a game without its library shows its "library failed to load" screen). Returns the list.
write_extension_list :: proc(game: Game) -> []string {
	sync_tools(game.dir)
	return write_extension_list_dir(game.dir)
}

// write_extension_list for any Godot project directory, without mirroring the tool scripts first: also
// for the test projects (ensure_imported mirrors it itself).
write_extension_list_dir :: proc(dir: string) -> []string {
	listed: [dynamic]string
	for ext in gdextensions(dir) {
		config, _ := config_load(ext)
		for key in LIB_KEYS {
			lib, ok := config_get(config, "libraries", key)
			if ok && os.exists(join(dir, strings.trim_prefix(lib, "res://"))) {
				relative, _ := strings.replace_all(ext[len(dir) + 1:], "\\", "/")
				append(&listed, aprintf("res://%s", relative))
				break
			}
		}
	}
	builder := strings.builder_make()
	for entry in listed {
		strings.write_string(&builder, entry)
		strings.write_byte(&builder, '\n')
	}
	path := join(dir, ".godot", "extension_list.cfg")
	if have, ok := read_text(path); !ok || have != strings.to_string(builder) {
		write_text(path, strings.to_string(builder))
	}
	return listed[:]
}
