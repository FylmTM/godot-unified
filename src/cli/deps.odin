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

// The C toolchain Box3D and Dear ImGui build with: one compiler family everywhere, clang (clang-cl on Windows, with
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
		r := run_proc(
			{cmd = {"cmd", "/s", "/c", tprint(`""%s" x64 >nul && set"`, vcvars)}, capture = true, quiet = true},
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

// Box3D: the pinned commit plus third_party/box3d.patch (applied exactly), compiled with our flags into
// third_party/box3d/build/<platform>/lib, its public headers into .../include (the bindings test reads them). The
// flags are CMake's for the upstream project, minus warnings: C17 with GNU extensions, -O2 -DNDEBUG, no FP
// contraction, the AVX2 path compiled out (x64 runs the same 4-wide path as ARM64), the static CRT on Windows.
ensure_box3d :: proc() {
	root := join(state.project.unified, "third_party", "box3d")
	src := join(root, "src")
	out := join(root, "build", PLATFORM)
	lib := join(out, "lib", ODIN_OS == .Windows ? "box3d.lib" : "libbox3d.a")
	patch_text := must_read(join(state.project.unified, "third_party", "box3d.patch"))
	patch, _ := strings.replace_all(patch_text, "\r\n", "\n")
	commit := pin("box3d", "commit")
	t := c_toolchain()
	flags := box3d_flags(t, src)
	key := sha256_hex(
		transmute([]byte)tprint(
			"%d %s %s %s %s %s",
			RECIPE_VERSION,
			commit,
			sha256_hex(transmute([]byte)patch),
			PLATFORM,
			strings.join(flags, " ", context.temp_allocator),
			file_identity(t.cc),
		),
	)
	stamp := join(out, "box3d.stamp")
	if os.is_file(lib) && stamp_ok(stamp, key) {
		return
	}
	start := time.tick_now()
	cold("Box3D build")
	src_key := tprint("%s %s", commit, sha256_hex(transmute([]byte)patch))
	src_stamp := join(root, "src.stamp")
	if !stamp_ok(src_stamp, src_key) || !os.is_file(join(src, "src", "world_state.c")) {
		git_checkout(src, pin("box3d", "url"), commit)
		lf_patch := join(root, "box3d.lf.patch")
		write_text(lf_patch, patch)
		check := run_proc({cmd = {git(), "-C", src, "apply", "--check", lf_patch}, capture = true, quiet = true})
		if !check.ok {
			fatal("third_party/box3d.patch does not apply cleanly to %s:\n%s", commit, check.stderr)
		}
		must_run(
			{cmd = {git(), "-C", src, "apply", "--whitespace=nowarn", lf_patch}, capture = true, quiet = true},
			"applying the Box3D patch",
		)
		os.remove(lf_patch)
		write_text(src_stamp, tprint("%s\n", src_key))
	}
	sources := find_files(join(src, "src"), ".c")
	if len(sources) < 20 {
		fatal("Box3D has only %d sources in %s", len(sources), join(src, "src"))
	}
	remove_tree(out)
	build_static_lib(t, t.cc, flags, sources, join(root, "work", PLATFORM), lib)
	// The public headers, as CMake's install laid them out.
	for h in find_files(join(src, "include", "box3d"), ".h") {
		copy_file(join(out, "include", "box3d", os.base(h)), h)
	}
	write_text(stamp, tprint("%s\n", key))
	log("uni: Box3D built in %.1fs (%d sources)", time.duration_seconds(time.tick_since(start)), len(sources))
}

@(private)
box3d_flags :: proc(t: C_Toolchain, src: string) -> []string {
	inc := join(src, "include")
	srcdir := join(src, "src")
	if t.msvc {
		return strs(
			tprint("/I%s", inc),
			tprint("/I%s", srcdir),
			"/DBOX3D_DISABLE_AVX2",
			"/O2",
			"/DNDEBUG",
			"/std:c17",
			"/clang:-ffp-contract=off",
		)
	}
	return strs(
		tprint("-I%s", inc),
		tprint("-I%s", srcdir),
		"-DBOX3D_DISABLE_AVX2",
		"-O2",
		"-DNDEBUG",
		"-std=gnu17",
		"-fvisibility=hidden",
		"-ffp-contract=off",
	)
}

// Whether a game's Odin code imports physics: only then is Box3D built for it.
game_uses_box3d :: proc(g: Game) -> bool {
	return sources_import(join(g.dir, "simulation"), `"unified:physics"`, `"unified:box3d"`)
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
