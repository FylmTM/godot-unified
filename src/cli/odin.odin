package cli

import "core:os"
import "core:strings"
import "core:time"

// Building Odin code: the strict flags, the build modes, build manifests (an output rebuilds when stale), and the
// packages each command covers, by convention (SPEC.md, Layout).

VET :: []string{"-vet", "-strict-style", "-vet-tabs", "-warnings-as-errors"}
// Tests build like dev: optimized enough that the sim tests take milliseconds, fast to compile.
TEST_FLAGS :: []string{"-o:speed", "-use-separate-modules", "-debug"}
VET_TARGETS :: []string{"darwin_arm64", "linux_amd64", "linux_arm64", "windows_amd64"}

Mode :: enum {
	dev, // optimized, the fastest to build: the everyday build
	release, // one LLVM module: the fastest binary
	debug, // unoptimized, for stepping in a debugger
}

// The odin flags of a build mode; every headless binary and extension build starts with them.
mode_flags :: proc(mode: Mode) -> []string {
	switch mode {
	case .dev:
		return strs("-o:speed", "-use-separate-modules", "-debug")
	case .release:
		return strs("-o:speed")
	case .debug:
		return strs("-o:none", "-debug")
	}
	return nil
}

// The collections every Odin build passes: unified's packages, and `box3d:` (unified-box3d's bindings and library,
// box3d_dir()) once it is there (odin refuses a collection that isn't a directory; a project without physics never
// fetches it).
collection :: proc() -> []string {
	unified := aprintf("-collection:unified=%s", join(state.project.unified, "src"))
	if dir := box3d_dir(); os.is_directory(dir) {
		return strs(unified, aprintf("-collection:box3d=%s", dir))
	}
	return strs(unified)
}

// This repo (unified itself) rather than a game repo: its own tests, the toy game and the Godot test projects.
is_unified_repo :: proc() -> bool {
	return state.project.root == state.project.unified
}

// A headless binary: each game's simulation/headless, and in this repo the toy game's.
Headless :: struct {
	name:  string,
	pkg:   string,
	box3d: bool, // links Box3D
}

// Every headless binary this project builds: each game's simulation/headless that exists, in this repo also
// the toy's, with whether it links Box3D.
headless_packages :: proc() -> []Headless {
	out: [dynamic]Headless
	for game in state.project.games {
		if pkg := join(game.dir, "simulation", "headless"); os.is_directory(pkg) {
			append(&out, Headless{game.name, pkg, game_uses_box3d(game)})
		}
	}
	if is_unified_repo() {
		toy := join(state.project.root, "tests", "toy")
		append(&out, Headless{"toy", join(toy, "headless"), sources_import(toy, `"unified:physics"`, `"box3d:`)})
	}
	return out[:]
}

// The headless binary a command names: a game's, in this repo also the toy's; the only one when it names none.
headless_package :: proc(name: string) -> Headless {
	packages := headless_packages()
	if name == "" && len(packages) == 1 {
		return packages[0]
	}
	names := make([]string, len(packages))
	for headless, i in packages {
		if headless.name == name {
			return headless
		}
		names[i] = headless.name
	}
	if name == "" {
		usage("name a game: %s", strings.join(names, ", "))
	}
	usage("no headless binary %q: %s", name, strings.join(names, ", "))
}

// Builds one headless binary when stale, with the Box3D library beside it when it links it; its path.
ensure_headless :: proc(headless: Headless, mode: Mode) -> string {
	build := headless_build(headless, mode)
	if headless.box3d {
		ensure_box3d()
		stage_box3d(os.dir(build.out), debug = mode == .debug)
	}
	if stale(build) {
		odin_build(build, aprintf("building %s's headless binary", headless.name))
	}
	return build.out
}

// Where a headless binary is built: .out/<mode>/<name>[.exe]. `bench` runs the release ones from there.
headless_path :: proc(name: string, mode: Mode) -> string {
	return join(state.project.out, aprintf("%v", mode), aprintf("%s%s", name, EXE))
}

// The packages `test` compiles: this repo's tests/ (every package, the games' suites included), or a game repo's
// simulation/tests.
test_root :: proc() -> string {
	if is_unified_repo() {
		return join(state.project.root, "tests")
	}
	return join(state.project.games[0].dir, "simulation", "tests")
}

// Everything `vet` type-checks: the headless binaries, the tests, the extensions, the CLI's own tools/.
Vet_Package :: struct {
	pkg:   string,
	entry: bool, // has an entry point (a program)
	ext:   bool, // a GDExtension (also checked without the dev UI)
}

// The packages `vet` type-checks: the headless binaries, the tests, this repo's Godot test extensions, every
// game's extension and the project's tools/.
vet_packages :: proc() -> []Vet_Package {
	out: [dynamic]Vet_Package
	for headless in headless_packages() {
		append(&out, Vet_Package{pkg = headless.pkg, entry = true})
	}
	append(&out, Vet_Package{pkg = test_root()})
	if is_unified_repo() {
		append(&out, Vet_Package{pkg = join(state.project.root, "tests", "godot", "ext")})
		append(&out, Vet_Package{pkg = join(state.project.root, "tests", "godot_views", "ext")})
	}
	for game in state.project.games {
		if ext := join(game.dir, "simulation", "extension"); os.is_directory(ext) {
			append(&out, Vet_Package{pkg = ext, ext = true})
		}
	}
	append(&out, Vet_Package{pkg = join(state.project.root, "tools"), entry = true})
	return out[:]
}

// In this repo, `uni init`'s template is type-checked too: its Odin files, written for a game named template_game into
// .out/template/, as the packages a new game repo has (one target: what breaks it is the library's API, which the
// other packages check on every target).
vet_template :: proc() -> []Vet_Package {
	if !is_unified_repo() {
		return nil
	}
	dir := join(state.project.out, "template")
	remove_tree(dir)
	write_template(
		join(state.project.unified, "src", "cli", "template"),
		dir,
		"template_game",
		repo = true,
		suffix = ".odin.tmpl",
	)
	simulation := join(dir, "simulation")
	out: [dynamic]Vet_Package
	append(
		&out,
		Vet_Package{pkg = join(simulation, "headless"), entry = true},
		Vet_Package{pkg = join(simulation, "tests")},
		Vet_Package{pkg = join(simulation, "extension"), ext = true},
		Vet_Package{pkg = join(dir, "tools"), entry = true},
	)
	return out[:]
}

// The directories `fmt` formats.
fmt_dirs :: proc() -> []string {
	out: [dynamic]string
	if is_unified_repo() {
		append(&out, join(state.project.root, "src"), join(state.project.root, "tests"))
	}
	for game in state.project.games {
		append(&out, join(game.dir, "simulation"))
	}
	append(&out, join(state.project.root, "tools"))
	return out[:]
}

// --- builds with manifests --------------------------------------------------------------------------------------

Build :: struct {
	pkg:   string,
	out:   string,
	flags: []string, // mode, defines, -build-mode:dll ...
	dir:   string, // working directory ("": ours)
}

// The full odin command line of a build.
build_cmd :: proc(build: Build, deps_file := "") -> []string {
	cmd: [dynamic]string
	append(&cmd, odin(), "build", build.pkg, aprintf("-out:%s", build.out))
	append(&cmd, ..collection())
	append(&cmd, ..build.flags)
	append(&cmd, ..VET)
	if deps_file != "" {
		append(&cmd, "-export-dependencies:json", aprintf("-export-dependencies-file:%s", deps_file))
	}
	return cmd[:]
}

// The manifest key of a build: its command line (another mode or define is another build).
@(private)
build_key :: proc(build: Build) -> string {
	return sha256_hex(transmute([]byte)strings.join(build_cmd(build), "\x00", context.temp_allocator))
}

// Whether `out` is missing or older than its sources (by its manifest: sizes and times of every source file and
// directory, the odin executable, the same command line).
stale :: proc(build: Build, manifest := "") -> bool {
	path := manifest != "" ? manifest : aprintf("%s.inputs", build.out)
	if !os.exists(build.out) {
		return true
	}
	entries, key, ok := read_manifest(path)
	return !ok || key != build_key(build) || !entries_current(entries)
}

// Starts a build that records its manifest when it finishes (`finish_build`).
start_build :: proc(build: Build) -> Proc {
	make_dirs(os.dir(build.out))
	return start({cmd = build_cmd(build, aprintf("%s.deps.json", build.out)), dir = build.dir})
}

// Waits for a build start_build started and, when it succeeded, writes its manifest from odin's dependency list
// so `stale` can judge it next time. Returns how it ran: the caller decides what a failure means.
finish_build :: proc(build: Build, child: ^Proc, manifest := "") -> Ran {
	ran := wait(child)
	deps := aprintf("%s.deps.json", build.out)
	if ran.ok {
		files, odin_path := read_deps(deps)
		write_manifest(manifest != "" ? manifest : aprintf("%s.inputs", build.out), build_key(build), files, odin_path)
	}
	os.remove(deps)
	return ran
}

// Builds one package now; a failure stops the command.
odin_build :: proc(build: Build, what: string, manifest := "") -> f64 {
	child := start_build(build)
	ran := finish_build(build, &child, manifest)
	if !ran.ok {
		fatal("%s failed (exit %d)", what, ran.exit_code)
	}
	return ran.seconds
}

// --- the headless binaries --------------------------------------------------------------------------------------

// Builds every headless binary into .out/<mode>/ in parallel (only the stale ones unless `force`), with the Box3D
// library beside them when one links it.
build_headless :: proc(mode: Mode, force := false) -> (built: int) {
	builds := start_headless(mode, force = force)
	return finish_headless(&builds)
}

Headless_Builds :: struct {
	running: [dynamic]Headless_Build,
}

Headless_Build :: struct {
	headless: Headless,
	build:    Build,
	child:    Proc,
}

// Starts building the headless binaries (`only`: the one of that name; "": every one) without waiting, so other
// builds can run beside them; `finish_headless` waits for them. Only the stale ones unless `force`.
start_headless :: proc(mode: Mode, only := "", force := false) -> Headless_Builds {
	ensure_deps_for_headless()
	builds: Headless_Builds
	for headless in headless_packages() {
		if only != "" && headless.name != only do continue
		build := headless_build(headless, mode)
		if headless.box3d {
			stage_box3d(os.dir(build.out), debug = mode == .debug)
		}
		if force || stale(build) {
			append(&builds.running, Headless_Build{headless, build, start_build(build)})
		}
	}
	return builds
}

// Waits for the builds `start_headless` started; a failure stops the command. How many were built.
finish_headless :: proc(builds: ^Headless_Builds) -> (built: int) {
	failed: [dynamic]string
	for &running in builds.running {
		if ran := finish_build(running.build, &running.child); !ran.ok {
			append(&failed, running.headless.name)
		}
	}
	if len(failed) > 0 {
		fatal("building %s failed", strings.join(failed[:], ", "))
	}
	return len(builds.running)
}

// The build of one headless binary for `mode`: its package, output path (headless_path) and flags.
headless_build :: proc(headless: Headless, mode: Mode) -> Build {
	flags: [dynamic]string
	append(&flags, ..mode_flags(mode))
	append(&flags, ..box3d_defines(mode, headless.box3d))
	return {
		pkg   = headless.pkg,
		out   = headless_path(headless.name, mode),
		flags = flags[:],
	}
}

// Box3D when any headless binary or test may link it (this repo's tests always do).
@(private)
ensure_deps_for_headless :: proc() {
	if project_uses_box3d() {
		ensure_box3d()
	}
}

// The commit, with +dirty when the tree has changes ("" outside a git checkout).
git_commit :: proc(dir := "") -> string {
	repo_dir := dir != "" ? dir : state.project.root
	head := run_proc({
		cmd     = {git(), "-C", repo_dir, "rev-parse", "HEAD"},
		capture = true,
		quiet   = true,
	})
	if !head.ok {
		return ""
	}
	status := run_proc({
		cmd     = {git(), "-C", repo_dir, "status", "--porcelain"},
		capture = true,
		quiet   = true,
	})
	return aprintf("%s%s", strings.trim_space(head.stdout), strings.trim_space(status.stdout) != "" ? "+dirty" : "")
}

// Seconds since a tick, for the times commands and suites report.
seconds_since :: proc(tick: time.Tick) -> f64 {
	return time.duration_seconds(time.tick_since(tick))
}
