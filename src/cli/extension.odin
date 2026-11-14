package cli

import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The Godot bindings (src/gdext/*.gen.odin), generated from the committed API dump: no Godot needed. Skipped when
// the inputs (api/*.json, bindings.txt, the generator's source) hash the same as last time and the outputs exist.
// Generating them is first-time work (a fresh checkout or game repo, a Godot upgrade): it makes the run cold.
ensure_bindings :: proc(force := false) {
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
	cold("Godot bindings")
	start := time.tick_now()
	make_dirs(join(gdext, "gdi"))
	make_dirs(out)
	gen := join(out, tprint("gdext_gen%s", EXE))
	cmd: [dynamic]string
	append(&cmd, odin(), "build", join(gdext, "gen"), tprint("-out:%s", gen), "-o:minimal")
	append(&cmd, ..VET)
	must_run({cmd = cmd[:]}, "building the binding generator")
	must_run({cmd = {gen, join(gdext, "api"), join(gdext, "bindings.txt"), gdext}}, "the binding generator")
	write_text(stamp, tprint("%s\n", key))
	log("uni: godot-gen -> src/gdext/*.gen.odin in %.2fs", seconds_since(start))
}

// --- a game's GDExtension -----------------------------------------------------------------------------------------

// The game's library: <game>/.out/bin/lib<game>.dylib (.so, .dll), where its .gdextension points.
extension_lib :: proc(game: Game) -> string {
	return join(game.dir, ".out", "bin", lib_name(game.name))
}

extension_build :: proc(game: Game, mode: Mode) -> Build {
	flags: [dynamic]string
	append(&flags, "-build-mode:dll")
	append(&flags, ..mode_flags(mode))
	append(&flags, ..box3d_defines(mode, game_uses_box3d(game)))
	append(&flags, ..eos_defines(game))
	return {pkg = join(game.dir, "simulation", "extension"), out = extension_lib(game), flags = flags[:]}
}

has_extension :: proc(game: Game) -> bool {
	return os.is_directory(join(game.dir, "simulation", "extension"))
}

// Builds the game's extension when stale (always with `force`). The build tag
// (-define:UNIFIED_BUILD_TAG=<mode>-<time>) is outside the manifest key, so it doesn't make every build stale. The
// Box3D library goes next to it (the .gdextension's [dependencies] ship it from there): the debug build for --mode
// debug.
ensure_extension :: proc(game: Game, mode: Mode, force := false) -> string {
	if !has_extension(game) {
		fatal("%s has no simulation/extension to build", game.name)
	}
	if game_uses_box3d(game) {
		ensure_box3d()
		stage_box3d(os.dir(extension_lib(game)), debug = mode == .debug)
		for ext in gdextensions(game.dir) {
			if text, _ := read_text(ext); !strings.contains(text, tprint("res://.out/bin/%s", lib_name("box3d"))) {
				log(
					"uni: warning: %s's [dependencies] don't list %s: an export won't load",
					rel(ext),
					lib_name("box3d"),
				)
			}
		}
	}
	ensure_bindings()
	stage_eos(game)
	build := extension_build(game, mode)
	if !force && !stale(build) {
		write_extension_list(game)
		return build.out
	}
	start := time.tick_now()
	lib := build.out
	make_dirs(os.dir(lib))
	// macOS dev builds get a new file each time and lib<game>.dylib becomes a symlink to it: dyld never unloads an
	// image with thread-locals (Odin's runtime has some), so the editor would keep running the old code.
	versioned := ODIN_OS == .Darwin && mode != .release
	now := time.now()
	stamp := timestamp(now)
	tmp :=
		versioned ? join(os.dir(lib), tprint("lib%s-%s.dylib", game.name, stamp)) : tprint("%s.tmp%s", lib, ODIN_OS == .Windows ? ".dll" : "")
	built := build
	built.out = tmp
	flags: [dynamic]string
	append(&flags, ..build.flags)
	append(&flags, tprint("-define:UNIFIED_BUILD_TAG=%v-%s", mode, stamp[:15]))
	built.flags = flags[:]
	secs := odin_build(built, tprint("building %s's extension", game.name), tprint("%s.inputs", lib))
	// The manifest's key is the build without the tag (see above).
	if entries, _, ok := read_manifest(tprint("%s.inputs", lib)); ok {
		files: [dynamic]string
		odin_path := ""
		for entry in entries {
			if entry.kind == "file" {
				append(&files, entry.path)
			} else if entry.kind == "odin" {
				odin_path = entry.path
			}
		}
		write_manifest(tprint("%s.inputs", lib), build_key(build), files[:], odin_path)
	}
	if versioned {
		link := tprint("%s.new", lib)
		os.remove(link)
		if os.symlink(os.base(tmp), link) != nil || os.rename(link, lib) != nil {
			os.remove(tprint("%s.inputs", lib)) // not current: the next command builds again
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
			if os.exists(lib) do os.rename(lib, tprint("%s.old-%s", lib, stamp))
		}
		if os.rename(tmp, lib) != nil {
			os.remove(tprint("%s.inputs", lib)) // not current: the next command builds again
			fatal("cannot move %s into place (a running game holds it?)", lib)
		}
		when ODIN_OS == .Windows {
			for ext in ([]string{".pdb", ".lib", ".exp"}) {
				from := tprint("%s%s", tmp[:len(tmp) - 4], ext)
				if os.exists(from) {
					to := tprint("%s%s", lib[:len(lib) - 4], ext)
					os.remove(to)
					if os.exists(to) do os.rename(to, tprint("%s.old-%s", to, stamp))
					os.rename(from, to)
				}
			}
		}
	}
	write_extension_list(game)
	log("uni: %s extension (%v) -> %s in %.2fs (odin %.2fs)", game.name, mode, rel(lib), seconds_since(start), secs)
	return lib
}

// Keeps the newest four versioned builds: a running editor may still have older ones mapped.
@(private)
prune_versions :: proc(game: Game) {
	dir := join(game.dir, ".out", "bin")
	infos, _ := os.read_all_directory_by_path(dir, context.allocator)
	prefix := tprint("lib%s-", game.name)
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
		remove_tree(tprint("%s.dSYM", info.fullpath))
	}
}

// 20261111-142309-858: sortable, unique per millisecond.
timestamp :: proc(moment: time.Time) -> string {
	year, month, day := time.date(moment)
	hour, minute, second := time.clock(moment)
	millis := (time.to_unix_nanoseconds(moment) / 1_000_000) % 1000
	return tprint("%04d%02d%02d-%02d%02d%02d-%03d", year, int(month), day, hour, minute, second, millis)
}

// --- Godot's extension list ---------------------------------------------------------------------------------------

// The .gdextension files of a Godot project (not in hidden directories such as .godot/ and .out/).
gdextensions :: proc(dir: string) -> []string {
	return find_files(dir, ".gdextension")
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
// an error on every run (a game without its library falls back to its mock session). Returns the list.
write_extension_list :: proc(game: Game) -> []string {
	sync_shared(game.dir)
	return write_extension_list_dir(game.dir)
}

write_extension_list_dir :: proc(dir: string) -> []string {
	listed: [dynamic]string
	for ext in gdextensions(dir) {
		config, _ := config_load(ext)
		for key in LIB_KEYS {
			lib, ok := config_get(config, "libraries", key)
			if ok && os.exists(join(dir, strings.trim_prefix(lib, "res://"))) {
				relative, _ := strings.replace_all(ext[len(dir) + 1:], "\\", "/")
				append(&listed, tprint("res://%s", relative))
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
