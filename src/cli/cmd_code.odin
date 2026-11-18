package cli

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// build, vet, fmt and the odin test suite.

@(private)
Build_Opts :: struct {
	game:  string `args:"pos=0" usage:"a game (default: every game; also a headless binary of the project's own, which has no extension)"`,
	mode:  Mode `usage:"dev (default), release or debug"`,
	force: bool `usage:"build every one, current or not (and the Godot bindings): when the build manifests can't be trusted"`,
}

// Builds what is stale (by the build manifests every command trusts), the extensions and the headless binaries all
// at once.
@(private)
cmd_build :: proc(args: []string) -> Result {
	opts: Build_Opts
	parse(&opts, args)
	start := time.tick_now()
	games: []Game
	if !is_extra_headless(opts.game) {
		games = games_or_all(opts.game) // the name is checked before anything builds
	}
	if opts.force {
		ensure_bindings(force = true)
	}
	headless := start_headless(opts.mode, only = opts.game, force = opts.force)
	extensions: [dynamic]Extension_Build
	current := headless.current
	for game in games {
		if !has_extension(game) do continue
		if running, started := start_extension(game, opts.mode, force = opts.force).?; started {
			append(&extensions, running)
		} else {
			current += 1
		}
	}
	built := finish_headless(&headless)
	libs: [dynamic]string
	failed: [dynamic]string
	for &running in extensions {
		lib, ok := finish_extension(&running)
		if ok {
			append(&libs, rel(lib))
		} else {
			append(&failed, aprintf("%s's extension", running.game.name))
		}
	}
	if len(failed) > 0 {
		fatal("building %s failed", strings.join(failed[:], ", "))
	}
	return {
		ok      = true,
		summary = aprintf(
			"build (%v): %d headless %s and %d %s built, %d current, in %.1fs",
			opts.mode,
			built,
			built == 1 ? "binary" : "binaries",
			len(libs),
			len(libs) == 1 ? "extension" : "extensions",
			current,
			seconds_since(start),
		),
		data    = box(libs[:]),
	}
}

// --- headless ---------------------------------------------------------------------------------------------------

@(private)
Headless_Opts :: struct {
	game:     string `args:"pos=0" usage:"the game (default: the only one; also a headless binary of the project's own)"`,
	mode:     Mode `usage:"the build: dev (default), release or debug"`,
	overflow: [dynamic]string `hint:"-- <mode> [options]" usage:"after --: the headless mode and its options (sim, synctest, session, bench, ...)"`,
}

// The game's headless binary (src/headless/SPEC.md: offline runs, sync-tests, replays, sessions, the relay and
// clients, benchmarks), built when stale and run with our stdin, stdout and stderr: its JSON is this command's
// stdout.
@(private)
cmd_headless :: proc(args: []string) -> Result {
	opts: Headless_Opts
	parse(&opts, args)
	if len(opts.overflow) == 0 {
		usage("name a headless mode after --, e.g. uni headless -- sim --ticks 600 (-- help: every mode)")
	}
	headless := headless_package(opts.game)
	cmd: [dynamic]string
	append(&cmd, ensure_headless(headless, opts.mode))
	append(&cmd, ..opts.overflow[:])
	ran := run_proc({cmd = cmd[:], interactive = true})
	if !ran.ok {
		return {
			ok      = false,
			summary = aprintf("headless %s %s: exit %d", headless.name, opts.overflow[0], ran.exit_code),
		}
	}
	return {ok = true}
}

// --- vet --------------------------------------------------------------------------------------------------------

@(private)
Vet_Opts :: struct {}

@(private)
cmd_vet :: proc(args: []string) -> Result {
	opts: Vet_Opts
	parse(&opts, args)
	ensure_bindings()
	ensure_deps_for_headless() // the Box3D bindings
	start := time.tick_now()
	Job :: struct {
		pkg:    Vet_Package,
		target: string,
		define: string,
	}
	jobs: [dynamic]Job
	pkgs := vet_packages()
	for target in VET_TARGETS {
		for vet_pkg in pkgs {
			append(&jobs, Job{vet_pkg, target, ""})
		}
	}
	for vet_pkg in pkgs {
		if vet_pkg.ext {
			// unified:godot without the dev UI must keep compiling
			append(&jobs, Job{vet_pkg, VET_TARGETS[0], "-define:UNIFIED_DEVUI=false"})
		}
	}
	template := vet_template()
	for vet_pkg in template {
		append(&jobs, Job{vet_pkg, VET_TARGETS[0], ""})
	}
	// the suites as `test --long` builds them
	if uses_scenarios(test_root()) {
		append(&jobs, Job{Vet_Package{pkg = test_root()}, VET_TARGETS[0], "-define:UNIFIED_LONG_TESTS=true"})
	}
	runs := make([]Run, len(jobs))
	for job, i in jobs {
		cmd: [dynamic]string
		append(&cmd, odin(), "check", job.pkg.pkg, aprintf("-target:%s", job.target))
		append(&cmd, ..collection())
		if !job.pkg.entry {
			append(&cmd, "-no-entry-point")
		}
		if job.define != "" {
			append(&cmd, job.define)
		}
		append(&cmd, ..VET)
		runs[i] = {
			cmd     = cmd[:],
			capture = true,
			quiet   = true,
		}
	}
	failed: [dynamic]string
	for result, i in run_all(runs) {
		if !result.ok {
			job := jobs[i]
			append(&failed, aprintf("%s %s %s", rel(job.pkg.pkg), job.target, job.define))
			log(
				"vet: %s -target:%s %s FAILED\n%s%s",
				rel(job.pkg.pkg),
				job.target,
				job.define,
				result.stdout,
				result.stderr,
			)
		}
	}
	if len(failed) > 0 {
		return {
			ok      = false,
			summary = aprintf("vet failed: %s", strings.join(failed[:], ", ")),
			data    = box(failed[:]),
		}
	}
	names := make([]string, len(pkgs))
	for vet_pkg, i in pkgs {
		names[i] = rel(vet_pkg.pkg)
	}
	return {
		ok      = true,
		summary = aprintf(
			"vet ok: %d packages x %d targets%s, in %.2fs",
			len(pkgs),
			len(VET_TARGETS),
			len(template) > 0 ? " + uni init's template" : "",
			seconds_since(start),
		),
		data    = box(names),
	}
}

// --- fmt --------------------------------------------------------------------------------------------------------

// odinfmt works through one path on one thread: the files are split over this many per run, all runs at once.
FMT_FILES_PER_RUN :: 8

@(private)
Fmt_Opts :: struct {
	check:    bool `usage:"change nothing; fail when a file needs formatting"`,
	hook:     bool `usage:"format the one file a Claude Code edit names (the hook's JSON on stdin)"`,
	overflow: [dynamic]string `hint:"[path...]" usage:"files or directories (default: every Odin source of the project)"`,
}

@(private)
cmd_fmt :: proc(args: []string) -> Result {
	opts: Fmt_Opts
	parse(&opts, args)
	if opts.hook {
		fmt_hook()
	}
	exe := ensure_odinfmt()
	start := time.tick_now()
	srcs: [dynamic]string
	roots := len(opts.overflow) > 0 ? opts.overflow[:] : fmt_dirs()
	for root in roots {
		abs, _ := os.get_absolute_path(root, context.allocator)
		if os.is_file(abs) {
			append(&srcs, abs)
			continue
		}
		for file in find_files(abs, ".odin") {
			if !strings.has_suffix(file, ".gen.odin") {
				append(&srcs, file)
			}
		}
	}
	changed := fmt_files(exe, srcs[:], opts.check)
	if opts.check && len(changed) > 0 {
		for path in changed {
			log("fmt: needs formatting: %s", path)
		}
		return {
			ok      = false,
			summary = aprintf("%d file(s) need formatting: run uni fmt", len(changed)),
			data    = box(changed),
		}
	}
	return {
		ok      = true,
		summary = aprintf(
			"fmt %s: %d of %d file(s) %s in %.2fs",
			opts.check ? "check ok" : "done",
			len(changed),
			len(srcs),
			opts.check ? "to change" : "changed",
			seconds_since(start),
		),
		data    = box(changed),
	}
}

/// Formats copies of the files in size-balanced chunk folders (one odinfmt run each, all at once), then compares:
// only changed files are written back. Returns the changed ones. `config`: the odinfmt.json to use (default: this
// project's).
@(private)
fmt_files :: proc(exe: string, srcs: []string, check: bool, config := "") -> []string {
	if len(srcs) == 0 {
		return nil
	}
	tmp := join(state.project.out, "tmp", aprintf("fmt-%d", os.get_pid()))
	remove_tree(tmp)
	defer remove_tree(tmp)
	runs := max(1, min(os.get_processor_core_count(), len(srcs) / FMT_FILES_PER_RUN))
	load := make([]i64, runs)
	scratch := make([]string, len(srcs))
	Sized :: struct {
		index: int,
		size:  i64,
	}
	order := make([]Sized, len(srcs))
	for src, i in srcs {
		info, _ := os.stat(src, context.temp_allocator)
		order[i] = {i, info.size}
	}
	// the largest first, each into the lightest folder so far
	slice.sort_by(order, proc(first, second: Sized) -> bool {return first.size > second.size})
	for item in order {
		i := item.index
		lightest := 0
		for bucket, index in load {
			if bucket < load[lightest] {
				lightest = index
			}
		}
		load[lightest] += item.size
		scratch[i] = join(tmp, aprintf("%d", lightest), aprintf("%d-%s", i, os.base(srcs[i])))
		copy_file(scratch[i], srcs[i])
	}
	config_flag := aprintf("-config:%s", config != "" ? config : join(state.project.unified, "odinfmt.json"))
	fmt_runs: [dynamic]Run
	for bucket in 0 ..< runs {
		if load[bucket] > 0 {
			append(&fmt_runs, Run {
				cmd     = strs(exe, config_flag, "-w", join(tmp, aprintf("%d", bucket))),
				capture = true,
				quiet   = true,
			})
		}
	}
	for result in run_all(fmt_runs[:]) {
		if !result.ok {
			fatal("odinfmt failed:\n%s%s", result.stdout, result.stderr)
		}
	}
	changed: [dynamic]string
	for src, i in srcs {
		old_text, _ := read_text(src)
		new_text, _ := read_text(scratch[i])
		if old_text != new_text {
			append(&changed, rel(src))
			if !check {
				write_text(src, new_text)
			}
		}
	}
	return changed[:]
}

// Claude Code's PostToolUse hook (.claude/settings.json): formats the one .odin file an Edit or Write touched, named
// in the hook's JSON on stdin. The file's own project is the nearest directory above it with a `uni` shim, so an edit
// in a git worktree of this checkout (.claude/worktrees/<name>/) is formatted too, with its own odinfmt.json. Never
// blocks the agent: anything unexpected (not Odin, outside the formatted directories, a file that doesn't parse yet)
// is skipped quietly; `fmt --check` in `verify` and CI is the gate.
@(private)
fmt_hook :: proc() -> ! {
	data, err := os.read_entire_file(os.stdin, context.allocator)
	if err != nil {
		os.exit(0)
	}
	Hook :: struct {
		tool_input: struct {
			file_path: string,
		},
	}
	hook: Hook
	if json.unmarshal(data, &hook) != nil ||
	   !strings.has_suffix(hook.tool_input.file_path, ".odin") ||
	   strings.has_suffix(hook.tool_input.file_path, ".gen.odin") {
		os.exit(0)
	}
	path, _ := os.get_absolute_path(hook.tool_input.file_path, context.allocator)
	path, _ = strings.replace_all(path, "\\", "/")
	root := os.dir(path)
	for !os.is_file(join(root, "uni")) {
		parent := os.dir(root)
		if parent == root || parent == "" || parent == "." {
			os.exit(0)
		}
		root = parent
	}
	inside := false
	for dir in fmt_dirs(root) {
		slashed, _ := strings.replace_all(dir, "\\", "/")
		inside ||= strings.has_prefix(path, aprintf("%s/", slashed))
	}
	exe := join(state.project.out, "odinfmt", aprintf("odinfmt%s", EXE))
	if !inside || !os.is_file(path) || !os.is_file(exe) {
		os.exit(0)
	}
	config := join(root, "odinfmt.json")
	if !os.is_file(config) {
		config = join(root, "unified", "odinfmt.json") // a game repo: the submodule's
	}
	fmt_files(exe, {path}, false, config)
	os.exit(0)
}

// --- the odin test suite ----------------------------------------------------------------------------------------

// Whether the tests under `root` build unified:headless/scenarios, which declares UNIFIED_LONG_TESTS (odin rejects a
// -define nothing declares).
@(private)
uses_scenarios :: proc(root: string) -> bool {
	return sources_import(root, `"unified:headless/scenarios"`)
}

// The odin suite's build: every test package under the project's test root in one compile (Project_Config.tests,
// with -all-packages), or one game's simulation/tests (`test <game>`, and a game repo's). Built through its manifest
// like every other build, so an unchanged tree skips the compile.
@(private)
test_build :: proc(opts: Test_Options) -> Build {
	root := test_root(opts.game)
	name := opts.game
	if name == "" {
		name = state.config.tests != "" ? "unified" : state.project.games[0].name
	}
	flags: [dynamic]string
	if opts.game == "" && state.config.tests != "" {
		append(&flags, "-all-packages") // the test root pulls in every test package; a game's tests are one
	}
	append(&flags, ..TEST_RUN_FLAGS)
	append(&flags, ..mode_flags(.dev))
	if opts.long && uses_scenarios(root) {
		append(&flags, "-define:UNIFIED_LONG_TESTS=true")
	}
	if len(opts.only) > 0 {
		append(&flags, aprintf("-define:ODIN_TEST_NAMES=%s", strings.join(opts.only, ",")))
	}
	return {
		pkg   = root,
		out   = join(state.project.out, "test", aprintf("%s_tests%s", name, EXE)),
		flags = flags[:],
		own   = true,
	}
}

// Whether the tests `test` compiles link Box3D.
@(private)
tests_use_box3d :: proc(opts: Test_Options) -> bool {
	return opts.game != "" ? game_uses_box3d(game(opts.game)) : project_uses_box3d()
}

// Makes the odin suite's test binary current, with the Box3D library beside it; false when the compile failed (the
// compiler's errors are on the terminal).
@(private)
ensure_test_binary :: proc(opts: Test_Options) -> (exe: string, ok: bool) {
	ensure_deps_for_headless()
	ensure_bindings()
	build := test_build(opts)
	make_dirs(os.dir(build.out))
	if tests_use_box3d(opts) {
		stage_box3d(os.dir(build.out))
	}
	if stale(build) {
		child := start_build(build)
		if !finish_build(build, &child).ok {
			return build.out, false
		}
	}
	return build.out, true
}

// Every test package in one compile: unit tests, the library's black-box tests, the end-to-end suites with their
// reference-run replays, the Box3D golden trace, the determinism and import lint. With a game named, that game's
// tests only (no import lint: it lives in the project's test root).
@(private)
suite_odin :: proc(games: []Game, opts: Test_Options) -> bool {
	exe, ok := ensure_test_binary(opts)
	return ok && run_test_binary(exe, suite_timeout("odin", opts))
}

// The odin suite's binary again, next to Box3D's debug library in a folder of its own (the debug library has the
// release one's file name and ABI: unified-box3d builds both from the same sources): its asserts trap what the
// release library lets through (a stale id destroying another body). The same build as the odin suite's, so it only
// copies a current binary. Its physics is unoptimised: the run takes about three times the release one's.
@(private)
suite_box3d_debug :: proc(games: []Game, opts: Test_Options) -> bool {
	if !tests_use_box3d(opts) {
		if state.verbose do log("uni: box3d-debug: skipped: nothing links Box3D")
		return true
	}
	exe, ok := ensure_test_binary(opts)
	if !ok {
		return false
	}
	dir := join(state.project.out, "test-box3d-debug")
	make_dirs(dir)
	stage_box3d(dir, debug = true)
	debug_exe := join(dir, os.base(exe))
	copy_file(debug_exe, exe)
	return run_test_binary(debug_exe, suite_timeout("box3d-debug", opts))
}
