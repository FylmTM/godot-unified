package cli

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:time"

// build, vet, fmt and the odin test suite.

@(private)
Build_Opts :: struct {
	game: string `args:"pos=0" usage:"a game (default: every game; in this repo also toy, which has no extension)"`,
	mode: Mode `usage:"dev (default), release or debug"`,
}

@(private)
cmd_build :: proc(args: []string) -> Result {
	opts: Build_Opts
	parse(&opts, args)
	start := time.tick_now()
	games: []Game
	if opts.game != "toy" || !is_unified_repo() {
		games = games_or_all(opts.game) // the name is checked before anything builds
	}
	// the headless binaries build beside the extensions (each extension's build waits for the one before)
	headless := start_headless(opts.mode, only = opts.game, force = true)
	libs: [dynamic]string
	for game in games {
		if has_extension(game) {
			append(&libs, rel(ensure_extension(game, opts.mode, force = true)))
		}
	}
	built := finish_headless(&headless)
	return {
		ok      = true,
		summary = tprint(
			"built %d headless %s and %d %s (%v) in %.1fs",
			built,
			built == 1 ? "binary" : "binaries",
			len(libs),
			len(libs) == 1 ? "extension" : "extensions",
			opts.mode,
			seconds_since(start),
		),
		data    = box(libs[:]),
	}
}

// --- headless ---------------------------------------------------------------------------------------------------

@(private)
Headless_Opts :: struct {
	game:     string `args:"pos=0" usage:"the game (default: the only one; in this repo also toy)"`,
	mode:     Mode `usage:"the build: dev (default), release or debug"`,
	overflow: [dynamic]string `usage:"after --: the headless mode and its options (sim, synctest, session, bench, ...)"`,
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
			summary = tprint("headless %s %s: exit %d", headless.name, opts.overflow[0], ran.exit_code),
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
			// godot_host without the dev UI must keep compiling
			append(&jobs, Job{vet_pkg, VET_TARGETS[0], "-define:UNIFIED_DEVUI=false"})
		}
	}
	template := vet_template()
	for vet_pkg in template {
		append(&jobs, Job{vet_pkg, VET_TARGETS[0], ""})
	}
	// the suites as record-reference builds them (unified:headless/scenarios writes reference runs)
	// and as `test --long` builds them
	if uses_scenarios() {
		append(&jobs, Job{Vet_Package{pkg = test_root()}, VET_TARGETS[0], "-define:UNIFIED_REGEN=true"})
		append(&jobs, Job{Vet_Package{pkg = test_root()}, VET_TARGETS[0], "-define:UNIFIED_LONG_TESTS=true"})
	}
	runs := make([]Run, len(jobs))
	for job, i in jobs {
		cmd: [dynamic]string
		append(&cmd, odin(), "check", job.pkg.pkg, tprint("-target:%s", job.target))
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
	// Each command's help against what it accepts (usage_problems): the public commands and this project's own.
	for command in state.commands {
		for problem in usage_problems(command) {
			append(&failed, tprint("uni %s's help", command.name))
			log("vet: %s", problem)
		}
	}
	for result, i in run_all(runs) {
		if !result.ok {
			job := jobs[i]
			append(&failed, tprint("%s %s %s", rel(job.pkg.pkg), job.target, job.define))
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
			summary = tprint("vet failed: %s", strings.join(failed[:], ", ")),
			data    = box(failed[:]),
		}
	}
	names := make([]string, len(pkgs))
	for vet_pkg, i in pkgs {
		names[i] = rel(vet_pkg.pkg)
	}
	return {
		ok      = true,
		summary = tprint(
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
	check:    bool `usage:"change nothing; fail when a file needs formatting or has the wrong line endings"`,
	hook:     bool `usage:"format the one file a Claude Code edit names (the hook's JSON on stdin)"`,
	overflow: [dynamic]string `usage:"files or directories (default: the project: every Odin source, every text file's line endings)"`,
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
	eol_listing := eol_start(opts.overflow[:]) // line endings, every text file: while odinfmt runs
	changed := fmt_files(exe, srcs[:], opts.check)
	bad_eol := eol_wait(&eol_listing)
	for file in bad_eol {
		if opts.check {
			log("fmt: %s: %s", file.path, file.problem)
		} else {
			eol_fix(file)
			log("fmt: %s: %s, fixed", file.path, file.problem)
		}
	}
	if opts.check && len(changed) > 0 {
		for path in changed {
			log("fmt: needs formatting: %s", path)
		}
	}
	if opts.check && len(changed) + len(bad_eol) > 0 {
		return {
			ok      = false,
			summary = tprint(
				"%d file(s) need formatting, %d have wrong line endings: run uni fmt",
				len(changed),
				len(bad_eol),
			),
			data    = box(changed),
		}
	}
	return {
		ok      = true,
		summary = tprint(
			"fmt %s: %d of %d file(s) %s, %d line ending fix(es) in %.2fs",
			opts.check ? "check ok" : "done",
			len(changed),
			len(srcs),
			opts.check ? "to change" : "changed",
			len(bad_eol),
			seconds_since(start),
		),
		data    = box(changed),
	}
}

// Formats copies of the files in size-balanced chunk folders (one odinfmt run each, all at once), then compares:
// only changed files are written back. Returns the changed ones.
@(private)
fmt_files :: proc(exe: string, srcs: []string, check: bool) -> []string {
	if len(srcs) == 0 {
		return nil
	}
	tmp := join(state.project.out, "tmp", tprint("fmt-%d", os.get_pid()))
	remove_tree(tmp)
	defer remove_tree(tmp)
	runs := max(1, min(os.get_processor_core_count(), len(srcs) / FMT_FILES_PER_RUN))
	load := make([]i64, runs)
	scratch := make([]string, len(srcs))
	sizes := make([]i64, len(srcs))
	order := make([]int, len(srcs))
	for src, i in srcs {
		info, _ := os.stat(src, context.temp_allocator)
		sizes[i] = info.size
		order[i] = i
	}
	sort_by_size :: proc(order: []int, sizes: []i64) {
		for i in 1 ..< len(order) {
			for j := i; j > 0 && sizes[order[j]] > sizes[order[j - 1]]; j -= 1 {
				order[j], order[j - 1] = order[j - 1], order[j]
			}
		}
	}
	sort_by_size(order, sizes)
	for i in order {
		k := 0
		for bucket, index in load {
			if bucket < load[k] {
				k = index
			}
		}
		load[k] += sizes[i]
		scratch[i] = join(tmp, tprint("%d", k), tprint("%d-%s", i, os.base(srcs[i])))
		copy_file(scratch[i], srcs[i])
	}
	config := tprint("-config:%s", join(state.project.unified, "odinfmt.json"))
	fmt_runs: [dynamic]Run
	for k in 0 ..< runs {
		if load[k] > 0 {
			append(&fmt_runs, Run {
				cmd     = strs(exe, config, "-w", join(tmp, tprint("%d", k))),
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
// in the hook's JSON on stdin. Never blocks the agent: anything unexpected (not Odin, outside the formatted
// directories, a file that doesn't parse yet) is skipped quietly; `fmt --check` in CI is the gate.
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
	inside := false
	for dir in fmt_dirs() {
		if strings.has_prefix(path, tprint("%s/", dir)) {
			inside = true
		}
	}
	if !inside || !os.is_file(path) {
		os.exit(0)
	}
	exe := join(state.project.out, "odinfmt", tprint("odinfmt%s", EXE))
	if !os.is_file(exe) {
		os.exit(0)
	}
	tmp := join(state.project.out, "tmp", tprint("hook-%d", os.get_pid()), os.base(path))
	copy_file(tmp, path)
	result := run_proc({
		cmd     = {exe, tprint("-config:%s", join(state.project.unified, "odinfmt.json")), "-w", tmp},
		capture = true,
		quiet   = true,
	})
	if result.ok {
		old_text, _ := read_text(path)
		new_text, _ := read_text(tmp)
		if old_text != new_text {
			write_text(path, new_text)
		}
	}
	remove_tree(os.dir(tmp))
	os.exit(0)
}

// --- the odin test suite ----------------------------------------------------------------------------------------

// Whether the tests build unified:headless/scenarios, which declares UNIFIED_REGEN and UNIFIED_LONG_TESTS (odin
// rejects a -define nothing declares).
@(private)
uses_scenarios :: proc() -> bool {
	return is_unified_repo() || sources_import(test_root(), `"unified:headless/scenarios"`)
}

// Every test package in one compile: unit tests, the library's black-box tests, the end-to-end suites with their
// reference-run replays, the Box3D golden trace, the determinism and import lint.
@(private)
suite_odin :: proc(games: []Game, opts: Test_Options) -> bool {
	ensure_deps_for_headless()
	ensure_bindings()
	// --box3d-debug builds in a folder of its own: the debug library has the release one's file name.
	out := join(state.project.out, opts.box3d_debug ? "test-box3d-debug" : "test", tprint("unified_tests%s", EXE))
	make_dirs(os.dir(out))
	uses_box3d := project_uses_box3d()
	if uses_box3d {
		stage_box3d(os.dir(out), debug = opts.box3d_debug)
	}
	cmd: [dynamic]string
	append(&cmd, odin(), "build", test_root(), tprint("-out:%s", out))
	append(&cmd, ..collection())
	if is_unified_repo() {
		append(&cmd, "-all-packages") // tests/ is a root that pulls in every test package; a game's tests are one
	}
	append(&cmd, ..TEST_RUN_FLAGS)
	append(&cmd, ..TEST_FLAGS)
	append(&cmd, ..VET)
	if opts.long && uses_scenarios() {
		append(&cmd, "-define:UNIFIED_LONG_TESTS=true")
	}
	if opts.crash {
		append(&cmd, "-define:UNIFIED_TEST_CRASH=true")
	}
	append(&cmd, ..box3d_defines(opts.box3d_debug ? .debug : .dev, uses_box3d))
	if len(opts.only) > 0 {
		append(&cmd, tprint("-define:ODIN_TEST_NAMES=%s", strings.join(opts.only, ",")))
	}
	if !run_proc({cmd = cmd[:]}).ok {
		return false
	}
	return run_test_binary(out, suite_timeout("odin", opts))
}
