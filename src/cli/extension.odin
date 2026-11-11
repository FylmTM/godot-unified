package cli

import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The Godot bindings (src/gdext/*.gen.odin), generated from the committed API dump: no Godot needed. Skipped when
// the inputs (api/*.json, bindings.txt, the generator's source) hash the same as last time and the outputs exist.
ensure_bindings :: proc(force := false) {
	gdext := join(state.project.unified, "src", "gdext")
	inputs: [dynamic]string
	append(&inputs, ..find_files(join(gdext, "api"), ".json"))
	append(&inputs, join(gdext, "bindings.txt"))
	append(&inputs, ..find_files(join(gdext, "gen"), ".odin"))
	b := strings.builder_make()
	for f in inputs {
		strings.write_string(&b, rel(f))
		strings.write_byte(&b, 0)
		strings.write_string(&b, sha256_hex(transmute([]byte)must_read(f)))
		strings.write_byte(&b, '\n')
	}
	key := sha256_hex(transmute([]byte)strings.to_string(b))
	out := join(state.project.out, "gen")
	stamp := join(out, "gdext.stamp")
	outputs := []string{join(gdext, "api.gen.odin"), join(gdext, "gdi", "gdi.gen.odin")}
	if !force && stamp_ok(stamp, key) && os.is_file(outputs[0]) && os.is_file(outputs[1]) {
		return
	}
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
extension_lib :: proc(g: Game) -> string {
	return join(g.dir, ".out", "bin", lib_name(g.name))
}

extension_build :: proc(g: Game, m: Mode) -> Build {
	flags: [dynamic]string
	append(&flags, "-build-mode:dll")
	append(&flags, ..mode_flags(m))
	append(&flags, ..box3d_defines(m, game_uses_box3d(g)))
	append(&flags, ..eos_defines(g))
	return {pkg = join(g.dir, "simulation", "extension"), out = extension_lib(g), flags = flags[:]}
}

has_extension :: proc(g: Game) -> bool {
	return os.is_directory(join(g.dir, "simulation", "extension"))
}

// Builds the game's extension when stale (always with `force`). The build tag
// (-define:UNIFIED_BUILD_TAG=<mode>-<time>) is outside the manifest key, so it doesn't make every build stale. The
// Box3D library goes next to it (the .gdextension's [dependencies] ship it from there): the debug build for --mode
// debug.
ensure_extension :: proc(g: Game, m: Mode, force := false) -> string {
	if !has_extension(g) {
		fatal("%s has no simulation/extension to build", g.name)
	}
	if game_uses_box3d(g) {
		ensure_box3d()
		stage_box3d(os.dir(extension_lib(g)), debug = m == .debug)
		for ext in gdextensions(g.dir) {
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
	stage_eos(g)
	b := extension_build(g, m)
	if !force && !stale(b) {
		write_extension_list(g)
		return b.out
	}
	start := time.tick_now()
	lib := b.out
	make_dirs(os.dir(lib))
	// macOS dev builds get a new file each time and lib<game>.dylib becomes a symlink to it: dyld never unloads an
	// image with thread-locals (Odin's runtime has some), so the editor would keep running the old code.
	versioned := ODIN_OS == .Darwin && m != .release
	now := time.now()
	stamp := timestamp(now)
	tmp :=
		versioned ? join(os.dir(lib), tprint("lib%s-%s.dylib", g.name, stamp)) : tprint("%s.tmp%s", lib, ODIN_OS == .Windows ? ".dll" : "")
	built := b
	built.out = tmp
	flags: [dynamic]string
	append(&flags, ..b.flags)
	append(&flags, tprint("-define:UNIFIED_BUILD_TAG=%v-%s", m, stamp[:15]))
	built.flags = flags[:]
	secs := odin_build(built, tprint("building %s's extension", g.name), tprint("%s.inputs", lib))
	// The manifest's key is the build without the tag (see above).
	if entries, _, ok := read_manifest(tprint("%s.inputs", lib)); ok {
		files: [dynamic]string
		odin_path := ""
		for e in entries {
			if e.kind == "file" {
				append(&files, e.path)
			} else if e.kind == "odin" {
				odin_path = e.path
			}
		}
		write_manifest(tprint("%s.inputs", lib), build_key(b), files[:], odin_path)
	}
	if versioned {
		link := tprint("%s.new", lib)
		os.remove(link)
		if os.symlink(os.base(tmp), link) != nil || os.rename(link, lib) != nil {
			os.remove(tprint("%s.inputs", lib)) // not current: the next command builds again
			fatal("cannot point %s at %s", lib, os.base(tmp))
		}
		prune_versions(g)
	} else {
		os.remove(lib)
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
					os.rename(from, to)
				}
			}
		}
	}
	write_extension_list(g)
	log("uni: %s extension (%v) -> %s in %.2fs (odin %.2fs)", g.name, m, rel(lib), seconds_since(start), secs)
	return lib
}

// Keeps the newest four versioned builds: a running editor may still have older ones mapped.
@(private)
prune_versions :: proc(g: Game) {
	dir := join(g.dir, ".out", "bin")
	infos, _ := os.read_all_directory_by_path(dir, context.allocator)
	prefix := tprint("lib%s-", g.name)
	builds: [dynamic]os.File_Info
	for fi in infos {
		if strings.has_prefix(fi.name, prefix) && strings.has_suffix(fi.name, ".dylib") && fi.type == .Regular {
			append(&builds, fi)
		}
	}
	// newest first, by time: the names' stamps are labels, not the order
	slice.sort_by(builds[:], proc(a, b: os.File_Info) -> bool {
		return time.diff(a.modification_time, b.modification_time) < 0
	})
	for fi in builds[min(4, len(builds)):] {
		os.remove(fi.fullpath)
		remove_tree(tprint("%s.dSYM", fi.fullpath))
	}
}

// 20261111-142309-858: sortable, unique per millisecond.
timestamp :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	ms := (time.to_unix_nanoseconds(t) / 1_000_000) % 1000
	return tprint("%04d%02d%02d-%02d%02d%02d-%03d", y, int(mo), d, h, mi, s, ms)
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
write_extension_list :: proc(g: Game) -> []string {
	return write_extension_list_dir(g.dir)
}

write_extension_list_dir :: proc(dir: string) -> []string {
	listed: [dynamic]string
	for ext in gdextensions(dir) {
		c, _ := config_load(ext)
		for key in LIB_KEYS {
			lib, ok := config_get(c, "libraries", key)
			if ok && os.exists(join(dir, strings.trim_prefix(lib, "res://"))) {
				r, _ := strings.replace_all(ext[len(dir) + 1:], "\\", "/")
				append(&listed, tprint("res://%s", r))
				break
			}
		}
	}
	b := strings.builder_make()
	for e in listed {
		strings.write_string(&b, e)
		strings.write_byte(&b, '\n')
	}
	path := join(dir, ".godot", "extension_list.cfg")
	if have, ok := read_text(path); !ok || have != strings.to_string(b) {
		write_text(path, strings.to_string(b))
	}
	return listed[:]
}
