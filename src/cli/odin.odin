// Building Odin code: the strict flags, the build modes, build manifests (an output rebuilds when stale), and the
// packages each command covers, by convention (README.md, Layout).
package cli

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

VET :: []string{"-vet", "-strict-style", "-vet-tabs", "-warnings-as-errors"}
VET_TARGETS :: []string{"darwin_arm64", "linux_amd64", "linux_arm64", "windows_amd64"}

// A build mode (`--mode`); its odin flags are mode_flags'.
Mode :: enum {
	dev, // optimized, the fastest to build: the everyday build, and the tests' (the sim tests take milliseconds)
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

// This repo (unified itself) rather than a game repo: where `init --in-repo` writes a game. What else this repo has
// (its tests, the toy game, the Godot test projects) it registers with `configure`.
is_unified_repo :: proc() -> bool {
	return state.project.root == state.project.unified
}

// A headless binary: each game's simulation/headless, and in this repo the toy game's.
Headless :: struct {
	name:  string,
	pkg:   string,
	box3d: bool, // links Box3D
}

// Every headless binary this project builds: each game's simulation/headless that exists, then the project's own
// (Project_Config.headless), with whether it links Box3D (an extra one: when its parent directory's code does).
headless_packages :: proc() -> []Headless {
	out: [dynamic]Headless
	for game in state.project.games {
		if pkg := join(game.dir, "simulation", "headless"); os.is_directory(pkg) {
			append(&out, Headless{game.name, pkg, game_uses_box3d(game)})
		}
	}
	for extra in state.config.headless {
		pkg := join(state.project.root, extra.pkg)
		append(&out, Headless{extra.name, pkg, sources_import(os.dir(pkg), `"unified:physics"`, `"box3d:`)})
	}
	return out[:]
}

// Whether `name` is one of the project's own headless binaries (Project_Config.headless) rather than a game.
is_extra_headless :: proc(name: string) -> bool {
	for extra in state.config.headless {
		if extra.name == name {
			return true
		}
	}
	return false
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

// The packages `test` compiles: the named game's simulation/tests; else the project's test root
// (Project_Config.tests: this repo's tests/, every package, the games' suites included), or a game repo's
// simulation/tests.
test_root :: proc(game_name := "") -> string {
	if game_name != "" {
		root := join(game(game_name).dir, "simulation", "tests")
		if !os.is_directory(root) {
			usage("%s has no simulation/tests", game_name)
		}
		return root
	}
	if state.config.tests != "" {
		root := join(state.project.root, state.config.tests)
		write_game_test_imports(root)
		return root
	}
	return join(state.project.games[0].dir, "simulation", "tests")
}

// A library test package by name: the directory `name` of the project's test root or its unoptimised one (this
// repo: tests/dmath, tests/cli) holding .odin files, and whether it is under the unoptimised root; "" when neither
// has it.
test_package :: proc(name: string) -> (dir: string, unoptimized: bool) {
	if name == "" || strings.contains_any(name, "/\\.") do return "", false
	for root, i in ([]string{state.config.tests, state.config.unoptimized_tests}) {
		if root == "" do continue
		candidate := join(state.project.root, root, name)
		entries, _ := os.read_all_directory_by_path(candidate, context.temp_allocator)
		for entry in entries {
			if entry.type == .Regular && strings.has_suffix(entry.name, ".odin") do return candidate, i == 1
		}
	}
	return "", false
}

// The odin suite's unoptimised test root (Project_Config.unoptimized_tests: this repo's tests/tooling), compiled beside
// test_root's; "" when the project has none or `test` names a game (its tests are one root).
unoptimized_test_root :: proc(game_name := "") -> string {
	if game_name != "" || state.config.unoptimized_tests == "" {
		return ""
	}
	return join(state.project.root, state.config.unoptimized_tests)
}

// The test root's imports of every in-repo game's tests (examples/<game>/simulation/tests), written to
// `<root>/games.gen.odin` when they changed: git-ignored like the other *.gen.odin, so a new game edits no file the
// other games share. A game repo's tests are its one test root and need none.
@(private)
write_game_test_imports :: proc(root: string) {
	@(static) written: bool
	if written do return
	written = true
	names: [dynamic]string
	for game in state.project.games {
		in_repo := path_key(os.dir(game.dir)) == path_key(join(state.project.root, EXAMPLES))
		if in_repo && os.is_directory(join(game.dir, "simulation", "tests")) do append(&names, game.name)
	}
	path := join(root, "games.gen.odin")
	text := game_test_imports(names[:])
	if old, ok := read_text(path); !ok || old != text do write_text(path, text)
}

// tests/games.gen.odin's text: an import of each game's tests, sorted by name.
game_test_imports :: proc(names: []string) -> string {
	sorted := slice.clone(names, context.temp_allocator)
	slice.sort(sorted)
	builder := strings.builder_make()
	strings.write_string(
		&builder,
		"// Generated by uni (src/cli/odin.odin, write_game_test_imports) before every test compile and vet: each\n" +
		"// in-repo game's tests in the optimised test compile. Never edit it; it is git-ignored.\n" +
		"package tests\n",
	)
	if len(sorted) > 0 do strings.write_byte(&builder, '\n')
	for name in sorted {
		fmt.sbprintf(&builder, "@(require) import %s_tests \"../examples/%s/simulation/tests\"\n", name, name)
	}
	return strings.to_string(builder)
}

// Everything `vet` type-checks: the headless binaries, the tests, the extensions, the CLI's own tools/.
Vet_Package :: struct {
	pkg:   string,
	entry: bool, // has an entry point (a program)
	ext:   bool, // a GDExtension (also checked without the dev UI)
}

// The packages `vet` type-checks: the headless binaries, the tests, the project's own (Project_Config.vet: this
// repo's Godot test extensions), every game's extension and the project's tools/.
vet_packages :: proc() -> []Vet_Package {
	out: [dynamic]Vet_Package
	for headless in headless_packages() {
		append(&out, Vet_Package{pkg = headless.pkg, entry = true})
	}
	append(&out, Vet_Package{pkg = test_root()})
	if root := unoptimized_test_root(); root != "" {
		append(&out, Vet_Package{pkg = root})
	}
	for pkg in state.config.vet {
		append(&out, Vet_Package{pkg = join(state.project.root, pkg)})
	}
	for game in state.project.games {
		if ext := join(game.dir, "simulation", "extension"); os.is_directory(ext) {
			append(&out, Vet_Package{pkg = ext, ext = true})
		}
	}
	append(&out, Vet_Package{pkg = join(state.project.root, "tools"), entry = true})
	return out[:]
}

// The directories `fmt` formats in the project at `root` (default: this one): the project's own
// (Project_Config.fmt), every game's simulation/ and tools/.
fmt_dirs :: proc(root := "") -> []string {
	project := root != "" ? root : state.project.root
	out: [dynamic]string
	for dir in state.config.fmt {
		append(&out, join(project, dir))
	}
	for game in (root != "" ? find_games(root) : state.project.games) {
		append(&out, join(game.dir, "simulation"))
	}
	append(&out, join(project, "tools"))
	return out[:]
}

// --- builds with manifests --------------------------------------------------------------------------------------

// One Odin build: the package, its output and flags, and where its manifest goes (`stale` reads it, finish_build
// writes it).
Build :: struct {
	pkg:      string,
	out:      string,
	flags:    []string, // mode, defines, -build-mode:dll ...
	unkeyed:  []string, // flags outside the manifest's key (an extension's build tag: it changes every build)
	dir:      string, // working directory ("": ours)
	manifest: string, // where its manifest goes ("": <out>.inputs; an extension builds to a temporary file)
}

// The full odin command line of a build.
build_cmd :: proc(build: Build, deps_file := "") -> []string {
	cmd: [dynamic]string
	append(&cmd, odin(), "build", build.pkg, aprintf("-out:%s", build.out))
	append(&cmd, ..collection())
	append(&cmd, ..build.flags)
	append(&cmd, ..build.unkeyed)
	append(&cmd, ..VET)
	if deps_file != "" {
		append(&cmd, "-export-dependencies:json", aprintf("-export-dependencies-file:%s", deps_file))
	}
	return cmd[:]
}

// The manifest key of a build: its command line without the output path and the unkeyed flags (another mode or
// define is another build).
@(private)
build_key :: proc(build: Build) -> string {
	keyed := build
	keyed.out = ""
	keyed.unkeyed = nil
	return sha256_hex(transmute([]byte)strings.join(build_cmd(keyed), "\x00", context.temp_allocator))
}

// Where a build's manifest goes.
@(private)
manifest_path :: proc(build: Build) -> string {
	return build.manifest != "" ? build.manifest : aprintf("%s.inputs", build.out)
}

// Whether `out` is missing or older than its sources (by its manifest: sizes and times of every source file and
// directory, the odin executable, the same command line).
stale :: proc(build: Build) -> bool {
	if !os.exists(build.out) {
		return true
	}
	entries, key, ok := read_manifest(manifest_path(build))
	return !ok || key != build_key(build) || !entries_current(entries)
}

// Starts a build that records its manifest when it finishes (`finish_build`).
start_build :: proc(build: Build) -> Proc {
	make_dirs(os.dir(build.out))
	return start({cmd = build_cmd(build, aprintf("%s.deps.json", build.out)), dir = build.dir})
}

// Waits for a build start_build started and, when it succeeded, writes its manifest from odin's dependency list
// so `stale` can judge it next time.
// Returns how it ran: the caller decides what a failure means.
finish_build :: proc(build: Build, child: ^Proc) -> Ran {
	ran := wait(child)
	deps := aprintf("%s.deps.json", build.out)
	if ran.ok {
		files, odin_path := read_deps(deps)
		write_manifest(manifest_path(build), build_key(build), files, odin_path)
	}
	os.remove(deps)
	return ran
}

// Builds one package now; a failure stops the command.
odin_build :: proc(build: Build, what: string) -> f64 {
	child := start_build(build)
	ran := finish_build(build, &child)
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

// The headless builds start_headless started, for finish_headless to wait for.
Headless_Builds :: struct {
	running: [dynamic]Headless_Build,
	current: int, // how many were current, not started
}

// One headless binary's build that start_headless started.
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
		} else {
			builds.current += 1
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
