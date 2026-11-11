package cli

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// bench, record-reference, setup, clean.

// A forward step plus an 8-tick re-sim must fit here (unified's target; each game owns its benchmark's setup).
BENCH_TARGET_US :: 6000.0

@(private)
cmd_bench :: proc(args: []string) -> Result {
	Opts :: struct {
		overflow: [dynamic]string `usage:"games (default: every game with a headless binary)"`,
	}
	opts: Opts
	parse(&opts, args)
	games: [dynamic]Game
	if len(opts.overflow) == 0 {
		for g in state.project.games {
			if os.is_directory(join(g.dir, "simulation", "headless")) {
				append(&games, g)
			}
		}
	} else {
		for name in opts.overflow {
			append(&games, game(name))
		}
	}
	build_headless(.release)
	work := join(state.project.out, "bench")
	remove_tree(work)
	make_dirs(work)
	Bench_Line :: struct {
		what:               string,
		step_mean_us:       f64,
		step_p99_us:        f64,
		save_mean_us:       f64,
		restore_mean_us:    f64,
		resim_mean_us:      f64,
		resim_p99_us:       f64,
		step_plus_resim_us: f64,
		snapshot_bytes:     int,
		within_target:      bool,
		mismatches:         int,
	}
	Summary :: struct {
		platform:   string,
		commit:     string,
		target_us:  f64,
		benchmarks: map[string]Bench_Line,
	}
	summary := new(Summary)
	summary^ = {
		platform  = PLATFORM,
		commit    = git_commit(),
		target_us = BENCH_TARGET_US,
	}
	failed: [dynamic]string
	for g in games {
		// alone: nothing else runs meanwhile, so the timings are clean
		r := run_proc(
			{
				cmd = strs(headless_path(g.name, .release), "bench"),
				capture = true,
				quiet = true,
				timeout = 900 * time.Second,
				log_to = join(work, g.name),
			},
		)
		obj, ok := last_json_object(r.stdout)
		if !r.ok || !ok {
			log("uni: bench %s failed (exit %d):\n%s", g.name, r.exit_code, tail(r.stderr, 2000))
			append(&failed, g.name)
			continue
		}
		stat :: proc(o: json.Object, key, field: string) -> f64 {
			s, _ := o[key].(json.Object)
			return json_f64(s[field])
		}
		b := Bench_Line {
			what            = json_string(obj["what"]),
			step_mean_us    = stat(obj, "step_us", "mean"),
			step_p99_us     = stat(obj, "step_us", "p99"),
			save_mean_us    = stat(obj, "save_us", "mean"),
			restore_mean_us = stat(obj, "restore_us", "mean"),
			resim_mean_us   = stat(obj, "resim_us", "mean"),
			resim_p99_us    = stat(obj, "resim_us", "p99"),
			snapshot_bytes  = json_int(obj["snapshot_bytes"]),
			mismatches      = json_int(obj["mismatches"]),
		}
		b.step_plus_resim_us = b.step_mean_us + b.resim_mean_us
		b.within_target = b.step_plus_resim_us <= BENCH_TARGET_US
		summary.benchmarks[g.name] = b
		log(
			"%-12s step %5.0f us + re-sim %5.0f us = %5.2f ms (target <= %.0f ms: %s); save %.0f us, restore %.0f us, snapshot %d bytes",
			g.name,
			b.step_mean_us,
			b.resim_mean_us,
			b.step_plus_resim_us / 1000,
			BENCH_TARGET_US / 1000,
			b.within_target ? "yes" : "NO",
			b.save_mean_us,
			b.restore_mean_us,
			b.snapshot_bytes,
		)
		if b.mismatches > 0 {
			append(&failed, g.name) // a re-sim that disagrees is a bug, whatever the timing
		}
	}
	if data, err := json.marshal(summary^, {pretty = true}); err == nil {
		write_file(join(state.project.out, "bench.json"), data)
	}
	if len(failed) > 0 {
		return {
			ok = false,
			summary = tprint("bench failed: %s (.out/bench/)", strings.join(failed[:], ", ")),
			data = summary^,
		}
	}
	return {
		ok = true,
		summary = tprint("bench: %d benchmark(s), reported in .out/bench.json", len(games)),
		data = summary^,
	}
}

json_f64 :: proc(v: json.Value) -> f64 {
	#partial switch x in v {
	case json.Float:
		return f64(x)
	case json.Integer:
		return f64(x)
	}
	return 0
}

// The last line of a text that parses as a JSON object.
last_json_object :: proc(text: string) -> (json.Object, bool) {
	lines := strings.split_lines(text)
	#reverse for line in lines {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "{") {
			if v, err := json.parse_string(l); err == nil {
				if o, ok := v.(json.Object); ok {
					return o, true
				}
			}
		}
	}
	return nil, false
}

// --- record-reference -------------------------------------------------------------------------------------------

// Builds the game's end-to-end suite with -define:UNIFIED_REGEN=true and runs it: its reference test writes a new
// reference run (ref.log, ref.trace, the snapshot, ref.json saying where it was made), checks it, and the files show
// up in `git status`. Commit them with the change that made them necessary (the sim-change skill).
@(private)
cmd_record_reference :: proc(args: []string) -> Result {
	Opts :: struct {
		game: string `args:"pos=0,required" usage:"the game (in this repo also toy: tests/scenarios)"`,
	}
	opts: Opts
	parse(&opts, args)
	pkg: string
	needs_box3d: bool
	if opts.game == "toy" && is_unified_repo() {
		pkg = join(state.project.root, "tests", "scenarios")
		needs_box3d = true
	} else {
		g := game(opts.game)
		pkg = join(g.dir, "simulation", "tests")
		needs_box3d = game_uses_box3d(g)
	}
	if !os.is_file(join(pkg, "suite_test.odin")) {
		usage("%s has no end-to-end suite (suite_test.odin)", rel(pkg))
	}
	exe := join(state.project.out, "record-reference", tprint("%s_suite%s", opts.game, EXE))
	make_dirs(os.dir(exe))
	if needs_box3d {
		ensure_box3d()
		stage_box3d(os.dir(exe))
	}
	commit := git_commit()
	cmd: [dynamic]string
	append(&cmd, odin(), "test", pkg, tprint("-out:%s", exe), "-define:UNIFIED_REGEN=true")
	append(&cmd, ..collection())
	append(&cmd, tprint("-define:UNIFIED_REGEN_COMMIT=%s", commit != "" ? commit : "unknown"))
	append(&cmd, ..TEST_FLAGS)
	append(&cmd, ..VET)
	must_run({cmd = cmd[:]}, tprint("record-reference %s", opts.game))
	data := join(pkg, "testdata")
	st := run_proc(
		{cmd = strs(git(), "-C", state.project.root, "status", "--short", "--", data), capture = true, quiet = true},
	)
	changed := strings.trim_space(st.stdout)
	if changed == "" {
		return {
			ok = true,
			summary = tprint("record-reference %s: reproduced byte for byte, nothing changed", opts.game),
		}
	}
	log("%s", changed)
	return {
		ok = true,
		summary = tprint("record-reference %s -> %s (commit the files above with the change)", opts.game, rel(data)),
	}
}

// --- setup ------------------------------------------------------------------------------------------------------

// Fetches and builds everything the project needs, and reports each dependency's version and where it came from.
@(private)
cmd_setup :: proc(args: []string) -> Result {
	Opts :: struct {
		check: bool `usage:"report only: fetch and build nothing"`,
	}
	opts: Opts
	parse(&opts, args)
	Dep :: struct {
		name:    string,
		version: string,
		source:  string,
		ready:   bool,
	}
	deps: [dynamic]Dep
	uses_box3d, uses_ext, uses_eos := is_unified_repo(), is_unified_repo(), is_unified_repo()
	for g in state.project.games {
		uses_box3d = uses_box3d || game_uses_box3d(g)
		uses_ext = uses_ext || has_extension(g)
		uses_eos = uses_eos || extension_uses_eos(g)
	}
	t := c_toolchain()
	append(&deps, Dep{"odin", tprint("%s (%s)", ODIN_VERSION, ODIN_VERSION_HASH), which("odin"), true})
	append(&deps, Dep{"clang", "", t.cc, true})
	if !opts.check {
		ensure_odinfmt()
		ensure_bindings()
		if uses_box3d {
			ensure_box3d(build = true)
		}
		if uses_ext {
			ensure_imgui()
		}
		godot()
	}
	odinfmt := join(state.project.out, "odinfmt", tprint("odinfmt%s", EXE))
	append(
		&deps,
		Dep{"odinfmt", tprint("OLS %s", pin("odinfmt", "commit")[:10]), "built from the pin", os.is_file(odinfmt)},
	)
	if uses_box3d {
		version, src := pin("box3d", "tag"), "pinned release (.out/unified-box3d)"
		if local := box3d_local(); local != "" {
			version = "local"
			src = tprint("UNIFIED_BOX3D (%s): %s, built by its b3", env_source("UNIFIED_BOX3D"), local)
		}
		append(&deps, Dep{"box3d", version, src, box3d_ready()})
	}
	if uses_ext {
		lib := join(
			state.project.unified,
			"third_party",
			"imgui",
			"build",
			PLATFORM,
			ODIN_OS == .Windows ? "imgui.lib" : "libimgui.a",
		)
		append(&deps, Dep{"imgui", pin("imgui", "tag"), "built from the pin", os.is_file(lib)})
	}
	gsrc := "pinned download (.out/godot)"
	if os.get_env("UNIFIED_GODOT", context.temp_allocator) != "" {
		gsrc = tprint("UNIFIED_GODOT (%s)", env_source("UNIFIED_GODOT"))
	}
	gexe, _, _ := godot_download()
	if env := os.get_env("UNIFIED_GODOT", context.temp_allocator); env != "" {
		gexe = env
	}
	append(&deps, Dep{"godot", pin("godot", "version"), gsrc, os.is_file(gexe)})
	if uses_eos {
		problem := opts.check ? "" : ensure_eos()
		src :=
			os.get_env("UNIFIED_EOS_SDK", context.temp_allocator) != "" ? tprint("UNIFIED_EOS_SDK (%s)", env_source("UNIFIED_EOS_SDK")) : "draft release (gh)"
		if problem != "" {
			src = tprint("%s: %s", src, problem)
		}
		append(&deps, Dep{"eos_sdk", pin("eos_sdk", "version"), src, eos_ready()})
	}
	all_ready := true
	for d in deps {
		log("  %-8s %-24s %s%s", d.name, d.version, d.source, d.ready ? "" : "  (missing)")
		all_ready = all_ready && d.ready
	}
	return {
		ok = opts.check || all_ready,
		summary = tprint("setup: %s", all_ready ? "everything is in place" : "some dependencies are missing"),
		data = box(deps[:]),
	}
}

// Where a variable's value comes from: .env or the environment.
@(private)
env_source :: proc(key: string) -> string {
	for k in state.env_keys {
		if k == key {
			return ".env"
		}
	}
	return "environment"
}

// --- clean ------------------------------------------------------------------------------------------------------

// Removes what the CLI built or fetched: every .out/ and .godot/ in the project (outside hidden directories, so not
// another checkout's under .claude/), the dependencies in third_party/ and the generated Godot bindings. The running
// CLI stays, with its manifest and `current` (Windows can't delete a running .exe; the next command needs no
// bootstrap). Godot's export templates stay: they live in Godot's user directory, shared by every project.
@(private)
cmd_clean :: proc(args: []string) -> Result {
	Opts :: struct {
		check: bool `usage:"report only: list what would be removed, remove nothing"`,
	}
	opts: Opts
	parse(&opts, args)
	p := state.project
	deps := []string{join(p.unified, "third_party", "imgui"), join(p.unified, "third_party", "eos")}
	gdext := join(p.unified, "src", "gdext")
	targets: [dynamic]string
	for d in deps {
		append(&targets, d)
	}
	append(&targets, join(gdext, "api.gen.odin"), join(gdext, "gdi"))
	// The root's .out/ but the running CLI.
	exe, _ := os.get_executable_path(context.allocator)
	cli_dir := join(p.out, "cli")
	keep := []string{os.base(exe), tprint("%s.inputs", os.base(exe)), "current"}
	if entries, err := os.read_all_directory_by_path(p.out, context.allocator); err == nil {
		for e in entries {
			if e.name != "cli" {
				append(&targets, e.fullpath)
			}
		}
	}
	if entries, err := os.read_all_directory_by_path(cli_dir, context.allocator); err == nil {
		for e in entries {
			if !slice.contains(keep, e.name) {
				append(&targets, e.fullpath)
			}
		}
	}
	// Every other .out/ and .godot/: a game's, a Godot test project's.
	w := os.walker_create(p.root)
	defer os.walker_destroy(&w)
	for fi in os.walker_walk(&w) {
		if fi.type != .Directory {
			continue
		}
		if fi.name == ".out" || fi.name == ".godot" {
			if !same_path(fi.fullpath, p.out) {
				append(&targets, strings.clone(fi.fullpath))
			}
			os.walker_skip_dir(&w)
		} else if strings.has_prefix(fi.name, ".") {
			os.walker_skip_dir(&w) // .git, .claude (other checkouts), .toolchains
		} else {
			for d in deps {
				if same_path(fi.fullpath, d) {
					os.walker_skip_dir(&w) // removed whole above
				}
			}
		}
	}
	removed: [dynamic]string
	failed := 0
	for t in targets {
		if !os.exists(t) {
			continue
		}
		name, _ := strings.replace_all(rel(t), "\\", "/")
		append(&removed, name)
		if opts.check {
			log("  %s", name)
			continue
		}
		// remove_all can return no error and leave files a running process holds (Windows: a Godot this project
		// started, its loaded extension, an older uni still running), so what is left decides.
		err := os.remove_all(t)
		if os.exists(t) {
			log(
				"  %s: not removed%s: in use? (close Godot and other uni commands, then run clean again)",
				name,
				err != nil ? tprint(" (%v)", err) : "",
			)
			failed += 1
		} else {
			log("  %s", name)
		}
	}
	summary: string
	switch {
	case len(removed) == 0:
		summary = "clean: nothing to remove"
	case opts.check:
		summary = tprint("clean: %d paths would go (nothing removed)", len(removed))
	case failed > 0:
		summary = tprint("clean: %d of %d paths could not be removed (above)", failed, len(removed))
	case:
		summary = tprint("clean: removed %d paths (uni setup fetches and builds them again)", len(removed))
	}
	return {ok = failed == 0, summary = summary, data = box(removed[:])}
}

// Whether two paths name the same place (slashes and, on Windows, case aside).
@(private)
same_path :: proc(a, b: string) -> bool {
	norm :: proc(s: string) -> string {
		slashed, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
		slashed = strings.trim_right(slashed, "/")
		return ODIN_OS == .Windows ? strings.to_lower(slashed, context.temp_allocator) : slashed
	}
	return norm(a) == norm(b)
}
