package cli

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:time"

// build, vet, fmt and the odin test suite.

@(private)
cmd_build :: proc(args: []string) -> Result {
	Opts :: struct {
		game: string `args:"pos=0" usage:"a game (default: every game)"`,
		mode: Mode `usage:"dev (default), release or debug"`,
	}
	opts: Opts
	parse(&opts, args)
	start := time.tick_now()
	built := build_headless(opts.mode, force = true)
	libs: [dynamic]string
	for g in games_or_all(opts.game) {
		if has_extension(g) {
			append(&libs, rel(ensure_extension(g, opts.mode, force = true)))
		}
	}
	return {
		ok = true,
		summary = tprint(
			"built %d headless binaries and %d extensions (%v) in %.1fs",
			built,
			len(libs),
			opts.mode,
			seconds_since(start),
		),
		data = box(libs[:]),
	}
}

// --- vet --------------------------------------------------------------------------------------------------------

@(private)
cmd_vet :: proc(args: []string) -> Result {
	Opts :: struct {}
	opts: Opts
	parse(&opts, args)
	ensure_bindings()
	start := time.tick_now()
	Job :: struct {
		pkg:    Vet_Package,
		target: string,
		define: string,
	}
	jobs: [dynamic]Job
	pkgs := vet_packages()
	for t in VET_TARGETS {
		for p in pkgs {
			append(&jobs, Job{p, t, ""})
		}
	}
	for p in pkgs {
		if p.ext {
			// godot_host without the dev UI must keep compiling
			append(&jobs, Job{p, VET_TARGETS[0], "-define:UNIFIED_DEVUI=false"})
		}
	}
	// the suites as record-reference builds them (unified:headless/scenarios writes reference runs)
	if sources_import(test_root(), `"unified:headless/scenarios"`) || is_unified_repo() {
		append(&jobs, Job{Vet_Package{pkg = test_root()}, VET_TARGETS[0], "-define:UNIFIED_REGEN=true"})
	}
	runs := make([]Run, len(jobs))
	for j, i in jobs {
		cmd: [dynamic]string
		append(&cmd, odin(), "check", j.pkg.pkg, tprint("-target:%s", j.target), collection())
		if !j.pkg.entry {
			append(&cmd, "-no-entry-point")
		}
		if j.define != "" {
			append(&cmd, j.define)
		}
		append(&cmd, ..VET)
		runs[i] = {
			cmd     = cmd[:],
			capture = true,
			quiet   = true,
		}
	}
	failed: [dynamic]string
	for r, i in run_all(runs) {
		if !r.ok {
			j := jobs[i]
			append(&failed, tprint("%s %s %s", rel(j.pkg.pkg), j.target, j.define))
			log("vet: %s -target:%s %s FAILED\n%s%s", rel(j.pkg.pkg), j.target, j.define, r.stdout, r.stderr)
		}
	}
	if len(failed) > 0 {
		return {ok = false, summary = tprint("vet failed: %s", strings.join(failed[:], ", ")), data = box(failed[:])}
	}
	names := make([]string, len(pkgs))
	for p, i in pkgs {
		names[i] = rel(p.pkg)
	}
	return {
		ok = true,
		summary = tprint(
			"vet ok: %d packages x %d targets in %.2fs",
			len(pkgs),
			len(VET_TARGETS),
			seconds_since(start),
		),
		data = box(names),
	}
}

// --- fmt --------------------------------------------------------------------------------------------------------

// odinfmt works through one path on one thread: the files are split over this many per run, all runs at once.
FMT_FILES_PER_RUN :: 8

@(private)
cmd_fmt :: proc(args: []string) -> Result {
	Opts :: struct {
		check:    bool `usage:"change nothing; fail when a file needs formatting"`,
		hook:     bool `usage:"format the one file a Claude Code edit names (the hook's JSON on stdin)"`,
		overflow: [dynamic]string `usage:"files or directories (default: every Odin source of the project)"`,
	}
	opts: Opts
	parse(&opts, args)
	if opts.hook {
		fmt_hook()
	}
	exe := ensure_odinfmt()
	start := time.tick_now()
	srcs: [dynamic]string
	roots := len(opts.overflow) > 0 ? opts.overflow[:] : fmt_dirs()
	for r in roots {
		abs, _ := os.get_absolute_path(r, context.allocator)
		if os.is_file(abs) {
			append(&srcs, abs)
			continue
		}
		for f in find_files(abs, ".odin") {
			if !strings.has_suffix(f, ".gen.odin") {
				append(&srcs, f)
			}
		}
	}
	changed := fmt_files(exe, srcs[:], opts.check)
	if opts.check && len(changed) > 0 {
		for c in changed {
			log("fmt: needs formatting: %s", c)
		}
		return {
			ok = false,
			summary = tprint("%d file(s) need formatting: run uni fmt", len(changed)),
			data = box(changed),
		}
	}
	return {
		ok = true,
		summary = tprint(
			"fmt %s: %d of %d file(s) %s in %.2fs",
			opts.check ? "check ok" : "done",
			len(changed),
			len(srcs),
			opts.check ? "to change" : "changed",
			seconds_since(start),
		),
		data = box(changed),
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
	for s, i in srcs {
		fi, _ := os.stat(s, context.temp_allocator)
		sizes[i] = fi.size
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
		for l, n in load {
			if l < load[k] {
				k = n
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
			append(
				&fmt_runs,
				Run{cmd = strs(exe, config, "-w", join(tmp, tprint("%d", k))), capture = true, quiet = true},
			)
		}
	}
	for r in run_all(fmt_runs[:]) {
		if !r.ok {
			fatal("odinfmt failed:\n%s%s", r.stdout, r.stderr)
		}
	}
	changed: [dynamic]string
	for s, i in srcs {
		a, _ := read_text(s)
		b, _ := read_text(scratch[i])
		if a != b {
			append(&changed, rel(s))
			if !check {
				write_text(s, b)
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
	h: Hook
	if json.unmarshal(data, &h) != nil ||
	   !strings.has_suffix(h.tool_input.file_path, ".odin") ||
	   strings.has_suffix(h.tool_input.file_path, ".gen.odin") {
		os.exit(0)
	}
	path, _ := os.get_absolute_path(h.tool_input.file_path, context.allocator)
	inside := false
	for d in fmt_dirs() {
		if strings.has_prefix(path, tprint("%s/", d)) {
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
	r := run_proc(
		{
			cmd = {exe, tprint("-config:%s", join(state.project.unified, "odinfmt.json")), "-w", tmp},
			capture = true,
			quiet = true,
		},
	)
	if r.ok {
		a, _ := read_text(path)
		b, _ := read_text(tmp)
		if a != b {
			write_text(path, b)
		}
	}
	remove_tree(os.dir(tmp))
	os.exit(0)
}

// --- the odin test suite ----------------------------------------------------------------------------------------

// Every test package in one compile: unit tests, the library's black-box tests, the end-to-end suites with their
// reference-run replays, the Box3D golden trace, the determinism and import lint.
@(private)
suite_odin :: proc(games: []Game, only: []string) -> bool {
	ensure_deps_for_headless()
	ensure_bindings()
	out := join(state.project.out, "test", tprint("unified_tests%s", EXE))
	make_dirs(os.dir(out))
	cmd: [dynamic]string
	append(&cmd, odin(), "test", test_root(), collection(), tprint("-out:%s", out))
	if is_unified_repo() {
		append(&cmd, "-all-packages") // tests/ is a root that pulls in every test package; a game's tests are one
	}
	append(&cmd, ..TEST_FLAGS)
	append(&cmd, ..VET)
	if len(only) > 0 {
		append(&cmd, tprint("-define:ODIN_TEST_NAMES=%s", strings.join(only, ",")))
	}
	return run_proc({cmd = cmd[:]}).ok
}
