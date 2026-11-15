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

// Downloads `url` to `dest` through the system curl (retries, redirects), checked against the pinned SHA-256. The
// part file is this process's own: another checkout may download the same file into the shared cache meanwhile.
download :: proc(url, dest, sha256, what: string) {
	make_dirs(os.dir(dest))
	part := tprint("%s.%d.part", dest, os.get_pid())
	log("uni: downloading %s", url)
	must_run({
			cmd   = {curl(), "-fL", "--retry", "5", "--retry-all-errors", "--silent", "--show-error", "-o", part, url},
			quiet = true,
		}, tprint("downloading %s", url))
	check_sha256(part, sha256, what)
	if os.rename(part, dest) != nil {
		os.remove(part)
		if !os.is_file(dest) {
			fatal("cannot move %s into place", dest)
		} // else another process put the same checked file there first
	}
}

curl :: proc() -> string {
	path := which("curl")
	if path == "" {
		fatal("curl is not on PATH (macOS, Windows 10+ and Linux ship it)")
	}
	return path
}

git :: proc() -> string {
	git_exe := which("git")
	if git_exe == "" {
		fatal("git is not on PATH")
	}
	return git_exe
}

// A file's identity without reading it: path, size and time (a compiler upgrade changes it).
file_identity :: proc(path: string) -> string {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return path
	}
	return tprint("%s %d %d", path, info.size, time.to_unix_nanoseconds(info.modification_time))
}

stamp_ok :: proc(path, key: string) -> bool {
	text, ok := read_text(path)
	return ok && strings.trim_space(text) == key
}

// --- git checkouts ----------------------------------------------------------------------------------------------

// A shallow checkout of one pinned commit in `dir` (git init + fetch of that commit; reset to it, cleaned).
git_checkout :: proc(dir, url, commit: string) {
	git_exe := git()
	gitc :: proc(git_exe, dir: string, args: ..string) -> Ran {
		cmd: [dynamic]string
		append(&cmd, git_exe, "-c", "core.autocrlf=false", "-c", "advice.detachedHead=false", "-C", dir)
		append(&cmd, ..args)
		return run_proc({
			cmd     = cmd[:],
			capture = true,
			quiet   = true,
		})
	}
	if !os.is_directory(join(dir, ".git")) {
		remove_tree(dir)
		make_dirs(dir)
		for args in ([][]string{{"init", "-q"}, {"config", "core.autocrlf", "false"}, {"remote", "add", "origin", url}}) {
			if result := gitc(git_exe, dir, ..args); !result.ok {
				fatal("git %s in %s failed: %s", args[0], dir, result.stderr)
			}
		}
	}
	if !gitc(git_exe, dir, "cat-file", "-e", tprint("%s^{commit}", commit)).ok {
		log("uni: fetching %s @ %s", url, commit[:10])
		if result := gitc(git_exe, dir, "fetch", "-q", "--depth", "1", "origin", commit); !result.ok {
			fatal("fetching %s failed: %s", url, result.stderr)
		}
	}
	for args in ([][]string{{"checkout", "-q", "--force", "--detach", commit}, {"clean", "-q", "-fdx"}}) {
		if result := gitc(git_exe, dir, ..args); !result.ok {
			fatal("git %s in %s failed: %s", args[0], dir, result.stderr)
		}
	}
}

// --- Box3D ------------------------------------------------------------------------------------------------------

// Box3D is unified-box3d (Box3D ported to Odin): a shared library with upstream's C API, its headers and Odin
// bindings, in box3d_dir() (the `box3d:` collection). By default the pinned release for this platform, downloaded,
// checked against its SHA-256 (the zip kept in the per-user cache) and unpacked with the zip's top folder flattened into
// .out/unified-box3d/; with
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
	path := os.get_env("UNIFIED_BOX3D", context.allocator)
	if path == "" {
		return ""
	}
	path = strings.trim_right(path, `/\`)
	if !os.is_file(join(path, "bindings", "library.odin")) {
		fatal("UNIFIED_BOX3D=%s is not a unified-box3d checkout (no bindings/library.odin)", path)
	}
	return path
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
	name := tprint("unified-box3d-%s-%s.zip", tag, PLATFORM)
	sha256 := pin("box3d", PLATFORM)
	// The zip stays in the per-user cache: the next checkout unpacks it without a download. Each checkout unpacks
	// its own copy, so ols.json can name the bindings inside the project.
	zip := join(
		user_cache(),
		"downloads",
		tprint("%s-%s.zip", name[:len(name) - len(".zip")], sha256[:min(12, len(sha256))]),
	)
	if have, _ := sha256_file(zip); have == sha256 {
		cold("unified-box3d unpack (the download cached)")
	} else {
		cold("unified-box3d download")
		download(tprint("https://github.com/%s/releases/download/%s/%s", repo, tag, name), zip, sha256, name)
	}
	remove_tree(dir)
	if os.exists(dir) {
		fatal("cannot replace %s: in use? (close Godot and other uni commands)", dir)
	}
	archive := zip_open_file(zip)
	zip_extract_all(&archive, dir, strip_top = true)
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
		must_run({
				cmd     = cmd[:],
				dir     = local,
				capture = true,
				quiet   = true,
			}, what)
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
	for file in files {
		dst := join(dir, os.base(file))
		source_info, source_err := os.stat(file, context.temp_allocator)
		if source_err != nil {
			fatal("%s is missing (uni setup)", file)
		}
		dest_info, dest_err := os.stat(dst, context.temp_allocator)
		if dest_err == nil && source_info.size == dest_info.size {
			if time.diff(dest_info.modification_time, source_info.modification_time) <= 0 {
				continue
			}
			// a newer source (a fresh download, a local rebuild) may hold the same bytes; a running program holds
			// the copy on Windows
			source_hash, _ := sha256_file(file)
			dest_hash, _ := sha256_file(dst)
			if source_hash == dest_hash {
				continue
			}
		}
		make_dirs(dir)
		copy_file(dst, file)
	}
}

// The defines of a build in mode `m` that links Box3D (`uses`): --mode debug links the library's debug build. Odin
// rejects a -define nothing declares, so a build without Box3D gets none.
box3d_defines :: proc(mode: Mode, uses: bool) -> []string {
	return uses && mode == .debug ? strs("-define:BOX3D_LIB_DEBUG=true") : nil
}

// Whether a game's Odin code uses Box3D (through unified's physics, or directly): only then is it fetched for it.
game_uses_box3d :: proc(game: Game) -> bool {
	return sources_import(join(game.dir, "simulation"), `"unified:physics"`, `"unified:b3"`, `"box3d:`)
}

// Whether anything this project builds links Box3D (this repo's tests always do).
project_uses_box3d :: proc() -> bool {
	if is_unified_repo() {
		return true
	}
	for game in state.project.games {
		if game_uses_box3d(game) {
			return true
		}
	}
	return false
}

sources_import :: proc(dir: string, imports: ..string) -> bool {
	for file in find_files(dir, ".odin") {
		text, _ := read_text(file)
		for pattern in imports {
			if strings.contains(text, pattern) {
				return true
			}
		}
	}
	return false
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
	must_run({
			cmd     = {
				odin(),
				"build",
				"tools/odinfmt/main.odin",
				"-file",
				"-collection:src=src",
				"-o:speed",
				tprint("-out:%s", exe),
			},
			dir     = src,
			capture = true,
		}, "building odinfmt")
	write_text(stamp, tprint("%s\n", key))
	return exe
}

odin :: proc() -> string {
	path := which("odin")
	if path == "" {
		fatal("odin is not on PATH")
	}
	return path
}
