package cli

import "core:os"
import "core:strings"
import "core:time"

// Dependencies the CLI fetches or builds, pinned in pins.cfg (SPEC.md, Dependencies). Each `ensure_*` is a stamp
// check when nothing changed (no process started), else it does the work and marks the run cold.

// Bump when a recipe below changes in a way its inputs don't capture.
RECIPE_VERSION :: 1
MACOS_MIN :: "11.0"

// --- downloads --------------------------------------------------------------------------------------------------

// Downloads `url` to `dest` through the system curl (retries, redirects), checked against the pinned SHA-256.
download :: proc(url, dest, sha256, what: string) {
	make_dirs(os.dir(dest))
	part := tprint("%s.part", dest)
	log("uni: downloading %s", url)
	must_run(
		{
			cmd = {curl(), "-fL", "--retry", "5", "--retry-all-errors", "--silent", "--show-error", "-o", part, url},
			quiet = true,
		},
		tprint("downloading %s", url),
	)
	check_sha256(part, sha256, what)
	if os.rename(part, dest) != nil {
		fatal("cannot move %s into place", dest)
	}
}

curl :: proc() -> string {
	c := which("curl")
	if c == "" {
		fatal("curl is not on PATH (macOS, Windows 10+ and Linux ship it)")
	}
	return c
}

git :: proc() -> string {
	g := which("git")
	if g == "" {
		fatal("git is not on PATH")
	}
	return g
}

// A file's identity without reading it: path, size and time (a compiler upgrade changes it).
file_identity :: proc(path: string) -> string {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return path
	}
	return tprint("%s %d %d", path, fi.size, time.to_unix_nanoseconds(fi.modification_time))
}

stamp_ok :: proc(path, key: string) -> bool {
	text, ok := read_text(path)
	return ok && strings.trim_space(text) == key
}

// --- C toolchain ------------------------------------------------------------------------------------------------

C_Toolchain :: struct {
	cc:      string, // clang, or clang-cl on Windows
	cxx:     string, // clang++, or clang-cl
	ar:      string, // llvm-ar / ar, or llvm-lib
	msvc:    bool,
	env:     []string, // Windows: the MSVC environment for the compiler (nil: ours)
	compile: []string, // flags every C and C++ compile gets (target, CRT)
}

@(private)
toolchain_cache: Maybe(C_Toolchain)

// The C toolchain Dear ImGui builds with: one compiler family everywhere, clang (clang-cl on Windows, with
// the MSVC environment from vswhere and vcvarsall passed to the child processes, and the static CRT like Odin's).
c_toolchain :: proc() -> C_Toolchain {
	if t, ok := toolchain_cache.?; ok {
		return t
	}
	t: C_Toolchain
	when ODIN_OS == .Windows {
		t.msvc = true
		t.env = msvc_env()
		t.cc = find_clang_cl()
		if t.cc == "" {
			fatal("clang-cl not found: install LLVM, or Visual Studio's \"C++ Clang tools\" component")
		}
		t.cxx = t.cc
		lib := join(os.dir(t.cc), "llvm-lib.exe")
		t.ar = os.is_file(lib) ? lib : "lib.exe"
		t.compile = strs("/nologo", "/c", "/MT")
	} else {
		t.cc = which("clang")
		t.cxx = which("clang++")
		if t.cc == "" || t.cxx == "" {
			fatal("clang and clang++ must be on PATH (Odin links through clang too)")
		}
		t.ar = which("llvm-ar")
		if t.ar == "" {
			t.ar = which("ar")
		}
		t.compile = strs("-c", "-fPIC")
		when ODIN_OS == .Darwin {
			t.compile = strs(
				"-c",
				"-fPIC",
				"-arch",
				ODIN_ARCH == .arm64 ? "arm64" : "x86_64",
				"-mmacosx-version-min=" + MACOS_MIN,
			)
		}
	}
	toolchain_cache = t
	return t
}

// Compiles C or C++ sources in parallel and archives the objects into a static library.
build_static_lib :: proc(t: C_Toolchain, compiler: string, flags, sources: []string, obj_dir, lib: string) {
	remove_tree(obj_dir)
	make_dirs(obj_dir)
	runs := make([]Run, len(sources))
	objs := make([]string, len(sources))
	for src, i in sources {
		objs[i] = join(obj_dir, tprint("%s%s", os.stem(src), t.msvc ? ".obj" : ".o"))
		cmd: [dynamic]string
		append(&cmd, compiler)
		append(&cmd, ..t.compile)
		append(&cmd, ..flags)
		append(&cmd, src)
		if t.msvc {
			append(&cmd, tprint("/Fo%s", objs[i]))
		} else {
			append(&cmd, "-o", objs[i])
		}
		runs[i] = {
			cmd     = cmd[:],
			env     = t.env,
			capture = true,
			quiet   = true,
		}
	}
	log("uni: compiling %d sources with %s", len(sources), os.base(compiler))
	for r, i in run_all(runs, os.get_processor_core_count()) {
		if !r.ok {
			log("%s%s", r.stdout, r.stderr)
			fatal("compiling %s failed", sources[i])
		}
	}
	make_dirs(os.dir(lib))
	os.remove(lib)
	cmd: [dynamic]string
	if t.msvc {
		append(&cmd, t.ar, "/nologo", tprint("/out:%s", lib))
	} else {
		append(&cmd, t.ar, "rcs", lib)
	}
	append(&cmd, ..objs)
	must_run({cmd = cmd[:], env = t.env, capture = true, quiet = true}, tprint("archiving %s", os.base(lib)))
}

when ODIN_OS == .Windows {
	@(private)
	vs_install_path :: proc() -> string {
		pf86 := os.get_env("ProgramFiles(x86)", context.temp_allocator)
		if pf86 == "" {
			pf86 = `C:\Program Files (x86)`
		}
		vswhere := join(pf86, "Microsoft Visual Studio", "Installer", "vswhere.exe")
		if !os.is_file(vswhere) {
			return ""
		}
		r := run_proc(
			{
				cmd = {
					vswhere,
					"-latest",
					"-products",
					"*",
					"-requires",
					"Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
					"-property",
					"installationPath",
				},
				capture = true,
				quiet = true,
			},
		)
		return strings.trim_space(r.stdout)
	}

	// The vcvarsall.bat x64 environment for the compiler's child processes, unless this shell already is a
	// developer prompt (INCLUDE and LIB set, as in CI).
	@(private)
	msvc_env :: proc() -> []string {
		if os.get_env("INCLUDE", context.temp_allocator) != "" && os.get_env("LIB", context.temp_allocator) != "" {
			return nil
		}
		vs := vs_install_path()
		if vs == "" {
			log("uni: warning: Visual Studio with the C++ tools not found (vswhere); building without its environment")
			return nil
		}
		vcvars := join(vs, "VC", "Auxiliary", "Build", "vcvarsall.bat")
		// Separate arguments: Odin quotes each one that needs it (a hand-quoted cmd line gets quoted again).
		r := run_proc(
			{cmd = strs("cmd", "/c", "call", vcvars, "x64", ">nul", "&&", "set"), capture = true, quiet = true},
		)
		if !r.ok {
			log("uni: warning: vcvarsall.bat failed: %s", strings.trim_space(r.stderr))
			return nil
		}
		env: [dynamic]string
		text := r.stdout
		for line in strings.split_lines_iterator(&text) {
			if strings.index_byte(line, '=') > 0 {
				append(&env, strings.trim_right(line, "\r"))
			}
		}
		return env[:]
	}

	@(private)
	find_clang_cl :: proc() -> string {
		if p := which("clang-cl"); p != "" {
			return p
		}
		pf := os.get_env("ProgramFiles", context.temp_allocator)
		if pf == "" {
			pf = `C:\Program Files`
		}
		if c := join(pf, "LLVM", "bin", "clang-cl.exe"); os.is_file(c) {
			return c
		}
		if vs := vs_install_path(); vs != "" {
			if c := join(vs, "VC", "Tools", "Llvm", "x64", "bin", "clang-cl.exe"); os.is_file(c) {
				return c
			}
		}
		return ""
	}
}

// --- git checkouts ----------------------------------------------------------------------------------------------

// A shallow checkout of one pinned commit in `dir` (git init + fetch of that commit; reset to it, cleaned).
git_checkout :: proc(dir, url, commit: string) {
	g := git()
	gitc :: proc(g, dir: string, args: ..string) -> Ran {
		cmd: [dynamic]string
		append(&cmd, g, "-c", "core.autocrlf=false", "-c", "advice.detachedHead=false", "-C", dir)
		append(&cmd, ..args)
		return run_proc({cmd = cmd[:], capture = true, quiet = true})
	}
	if !os.is_directory(join(dir, ".git")) {
		remove_tree(dir)
		make_dirs(dir)
		for args in ([][]string{{"init", "-q"}, {"config", "core.autocrlf", "false"}, {"remote", "add", "origin", url}}) {
			if r := gitc(g, dir, ..args); !r.ok {
				fatal("git %s in %s failed: %s", args[0], dir, r.stderr)
			}
		}
	}
	if !gitc(g, dir, "cat-file", "-e", tprint("%s^{commit}", commit)).ok {
		log("uni: fetching %s @ %s", url, commit[:10])
		if r := gitc(g, dir, "fetch", "-q", "--depth", "1", "origin", commit); !r.ok {
			fatal("fetching %s failed: %s", url, r.stderr)
		}
	}
	for args in ([][]string{{"checkout", "-q", "--force", "--detach", commit}, {"clean", "-q", "-fdx"}}) {
		if r := gitc(g, dir, ..args); !r.ok {
			fatal("git %s in %s failed: %s", args[0], dir, r.stderr)
		}
	}
}

// --- Box3D ------------------------------------------------------------------------------------------------------

// Box3D is unified-box3d (Box3D ported to Odin): a shared library with upstream's C API, its headers and Odin
// bindings, in box3d_dir() (the `box3d:` collection). By default the pinned release for this platform, downloaded,
// checked against its SHA-256 and unpacked with the zip's top folder flattened into .out/unified-box3d/; with
// UNIFIED_BOX3D, a local unified-box3d checkout, built there by its own `b3 build` (release and --debug). A program
// links lib/<platform>[-debug]/ and loads the library from its own directory (stage_box3d): Odin's default rpath
// ($ORIGIN, @loader_path) and Windows' DLL search look there, and so does Godot for an extension's dependencies.

box3d_dir :: proc() -> string {
	if local := box3d_local(); local != "" {
		return local
	}
	return join(state.project.out, "unified-box3d")
}

// The unified-box3d checkout UNIFIED_BOX3D names, or "".
box3d_local :: proc() -> string {
	p := os.get_env("UNIFIED_BOX3D", context.allocator)
	if p == "" {
		return ""
	}
	p = strings.trim_right(p, `/\`)
	if !os.is_file(join(p, "bindings", "library.odin")) {
		fatal("UNIFIED_BOX3D=%s is not a unified-box3d checkout (no bindings/library.odin)", p)
	}
	return p
}

// The library for this platform: the release build, or the debug one (-define:BOX3D_LIB_DEBUG=true links it).
box3d_lib :: proc(debug := false) -> string {
	return join(box3d_dir(), "lib", tprint("%s%s", PLATFORM, debug ? "-debug" : ""), lib_name("box3d"))
}

// Makes box3d_dir() hold the library (both builds) and the bindings: a stamp check when they do. With UNIFIED_BOX3D,
// builds a missing library in the checkout (`build`: always; quick when nothing changed).
ensure_box3d :: proc(build := false) {
	if local := box3d_local(); local != "" {
		if build || !box3d_ready() {
			box3d_build_local(local)
		}
		return
	}
	if box3d_ready() {
		return
	}
	dir := box3d_dir()
	repo, tag := pin("box3d", "repo"), pin("box3d", "tag")
	start := time.tick_now()
	cold("unified-box3d download")
	name := tprint("unified-box3d-%s-%s.zip", tag, PLATFORM)
	sha := pin("box3d", PLATFORM)
	zip := join(state.project.out, "downloads", name)
	download(tprint("https://github.com/%s/releases/download/%s/%s", repo, tag, name), zip, sha, name)
	remove_tree(dir)
	if os.exists(dir) {
		fatal("cannot replace %s: in use? (close Godot and other uni commands)", dir)
	}
	z := zip_open_file(zip)
	zip_extract_all(&z, dir, strip_top = true)
	os.remove(zip)
	if !os.is_file(box3d_lib()) || !os.is_file(box3d_lib(debug = true)) {
		fatal("%s holds no %s for %s (release and debug)", name, lib_name("box3d"), PLATFORM)
	}
	write_text(join(dir, "release.stamp"), tprint("%s\n", box3d_release_key()))
	log("uni: unified-box3d %s ready in %.1fs", tag, seconds_since(start))
}

// Whether box3d_dir() holds both builds of the library (and, from a release, the pinned one): no process started.
box3d_ready :: proc() -> bool {
	if !os.is_file(box3d_lib()) || !os.is_file(box3d_lib(debug = true)) {
		return false
	}
	return box3d_local() != "" || stamp_ok(join(box3d_dir(), "release.stamp"), box3d_release_key())
}

@(private)
box3d_release_key :: proc() -> string {
	return tprint("%s %s %s %s", pin("box3d", "repo"), pin("box3d", "tag"), PLATFORM, pin("box3d", PLATFORM))
}

// `b3 build` and `b3 build --debug` in a local checkout (each rebuilds only when the port's sources changed).
@(private)
box3d_build_local :: proc(local: string) {
	for debug in ([]bool{false, true}) {
		cmd: [dynamic]string
		when ODIN_OS == .Windows {
			append(&cmd, "cmd", "/c", join(local, "b3.cmd"), "build")
		} else {
			append(&cmd, join(local, "b3"), "build")
		}
		if debug {
			append(&cmd, "--debug")
		}
		what := tprint("b3 build%s in %s", debug ? " --debug" : "", local)
		must_run({cmd = cmd[:], dir = local, capture = true, quiet = true}, what)
		if !os.is_file(box3d_lib(debug)) {
			fatal("%s made no %s", what, box3d_lib(debug))
		}
	}
}

// Copies the library into `dir`, next to an executable or extension that loads it (for --mode debug the debug build,
// with its .pdb on Windows); nothing when the copy there is current.
stage_box3d :: proc(dir: string, debug := false) {
	src := box3d_lib(debug)
	files: [dynamic]string
	append(&files, src)
	when ODIN_OS == .Windows {
		if pdb := tprint("%s.pdb", src[:len(src) - len(".dll")]); debug && os.is_file(pdb) {
			append(&files, pdb)
		} else if !debug {
			os.remove(join(dir, "box3d.pdb")) // the debug build's, from an earlier --mode debug
		}
	}
	for f in files {
		dst := join(dir, os.base(f))
		sfi, e1 := os.stat(f, context.temp_allocator)
		if e1 != nil {
			fatal("%s is missing (uni setup)", f)
		}
		dfi, e2 := os.stat(dst, context.temp_allocator)
		if e2 == nil && sfi.size == dfi.size {
			if time.diff(dfi.modification_time, sfi.modification_time) <= 0 {
				continue
			}
			// a newer source (a fresh download, a local rebuild) may hold the same bytes; a running program holds
			// the copy on Windows
			a, _ := sha256_file(f)
			b, _ := sha256_file(dst)
			if a == b {
				continue
			}
		}
		make_dirs(dir)
		copy_file(dst, f)
	}
}

// The defines of a build in mode `m` that links Box3D (`uses`): --mode debug links the library's debug build. Odin
// rejects a -define nothing declares, so a build without Box3D gets none.
box3d_defines :: proc(m: Mode, uses: bool) -> []string {
	return uses && m == .debug ? strs("-define:BOX3D_LIB_DEBUG=true") : nil
}

// Whether a game's Odin code uses Box3D (through unified's physics, or directly): only then is it fetched for it.
game_uses_box3d :: proc(g: Game) -> bool {
	return sources_import(join(g.dir, "simulation"), `"unified:physics"`, `"unified:b3"`, `"box3d:`)
}

// Whether anything this project builds links Box3D (this repo's tests always do).
project_uses_box3d :: proc() -> bool {
	if is_unified_repo() {
		return true
	}
	for g in state.project.games {
		if game_uses_box3d(g) {
			return true
		}
	}
	return false
}

sources_import :: proc(dir: string, imports: ..string) -> bool {
	for f in find_files(dir, ".odin") {
		text, _ := read_text(f)
		for i in imports {
			if strings.contains(text, i) {
				return true
			}
		}
	}
	return false
}

// --- Dear ImGui -------------------------------------------------------------------------------------------------

// Dear ImGui (docking) and dear_bindings' C API (pinned release files) as one static library for src/imgui:
// third_party/imgui/build/<platform>/libimgui.a (imgui.lib).
ensure_imgui :: proc() {
	root := join(state.project.unified, "third_party", "imgui")
	src := join(root, "src")
	lib := join(root, "build", PLATFORM, ODIN_OS == .Windows ? "imgui.lib" : "libimgui.a")
	t := c_toolchain()
	flags := imgui_flags(t, src)
	key := sha256_hex(
		transmute([]byte)tprint(
			"%d %s %s %s %s %s %s",
			RECIPE_VERSION,
			pin("imgui", "commit"),
			pin("imgui", "bindings_tag"),
			pin("imgui", "dcimgui_nodefaultargfunctions.cpp"),
			PLATFORM,
			strings.join(flags, " ", context.temp_allocator),
			file_identity(t.cxx),
		),
	)
	stamp := join(os.dir(lib), "imgui.stamp")
	if os.is_file(lib) && stamp_ok(stamp, key) {
		return
	}
	start := time.tick_now()
	cold("Dear ImGui build")
	src_key := tprint("%s %s", pin("imgui", "commit"), pin("imgui", "bindings_tag"))
	src_stamp := join(root, "src.stamp")
	if !stamp_ok(src_stamp, src_key) || !os.is_file(join(src, "imgui.cpp")) {
		git_checkout(src, pin("imgui", "url"), pin("imgui", "commit"))
		for f in ([]string{"dcimgui_nodefaultargfunctions.cpp", "dcimgui_nodefaultargfunctions.h"}) {
			download(
				tprint(
					"https://github.com/dearimgui/dear_bindings/releases/download/%s/%s",
					pin("imgui", "bindings_tag"),
					f,
				),
				join(src, "dcimgui", f),
				pin("imgui", f),
				f,
			)
		}
		write_text(src_stamp, tprint("%s\n", src_key))
	}
	sources := []string {
		join(src, "imgui.cpp"),
		join(src, "imgui_draw.cpp"),
		join(src, "imgui_tables.cpp"),
		join(src, "imgui_widgets.cpp"),
		join(src, "imgui_demo.cpp"),
		join(src, "dcimgui", "dcimgui_nodefaultargfunctions.cpp"),
	}
	build_static_lib(t, t.cxx, flags, sources, join(root, "obj", PLATFORM), lib)
	write_text(stamp, tprint("%s\n", key))
	log("uni: Dear ImGui built in %.1fs", time.duration_seconds(time.tick_since(start)))
}

@(private)
imgui_flags :: proc(t: C_Toolchain, src: string) -> []string {
	if t.msvc {
		return strs(
			"/O2",
			"/std:c++14",
			"/GR-",
			"/EHs-c-",
			"/DNDEBUG",
			"/DIMGUI_DISABLE_OBSOLETE_FUNCTIONS",
			"/DIMGUI_DISABLE_OBSOLETE_KEYIO",
			tprint("/I%s", src),
		)
	}
	return strs(
		"-std=c++11",
		"-O2",
		"-DNDEBUG",
		"-fno-exceptions",
		"-fno-rtti",
		"-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS",
		"-DIMGUI_DISABLE_OBSOLETE_KEYIO",
		tprint("-I%s", src),
	)
}

// --- odinfmt ----------------------------------------------------------------------------------------------------

// odinfmt built from the pinned OLS commit into .out/odinfmt/ (no other odinfmt is used: CI and the format hook
// must agree).
ensure_odinfmt :: proc() -> string {
	dir := join(state.project.out, "odinfmt")
	exe := join(dir, tprint("odinfmt%s", EXE))
	commit := pin("odinfmt", "commit")
	key := tprint("%s %s", commit, ODIN_VERSION_HASH)
	stamp := join(dir, "odinfmt.stamp")
	if os.is_file(exe) && stamp_ok(stamp, key) {
		return exe
	}
	cold("odinfmt build")
	src := join(dir, "ols-src")
	git_checkout(src, pin("odinfmt", "url"), commit)
	must_run(
		{
			cmd = {
				odin(),
				"build",
				"tools/odinfmt/main.odin",
				"-file",
				"-collection:src=src",
				"-o:speed",
				tprint("-out:%s", exe),
			},
			dir = src,
			capture = true,
		},
		"building odinfmt",
	)
	write_text(stamp, tprint("%s\n", key))
	return exe
}

odin :: proc() -> string {
	o := which("odin")
	if o == "" {
		fatal("odin is not on PATH")
	}
	return o
}
