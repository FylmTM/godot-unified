package cli

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// bench, record-reference, setup, clean.

// A forward step plus a re-sim at the prediction cap (14 ticks at 64 Hz) must fit here (unified's target; each
// game owns its benchmark's setup).
BENCH_TARGET_US :: 6000.0

@(private)
Bench_Opts :: struct {
	overflow: [dynamic]string `usage:"games (default: every game with a headless binary)"`,
}

@(private)
cmd_bench :: proc(args: []string) -> Result {
	opts: Bench_Opts
	parse(&opts, args)
	games: [dynamic]Game
	if len(opts.overflow) == 0 {
		for game in state.project.games {
			if os.is_directory(join(game.dir, "simulation", "headless")) {
				append(&games, game)
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
		resim_final_us:     f64, // the same re-sim of final ticks, saving only the last (a catch-up burst)
		checksum_us:        f64, // sim.checksum of a tick peers don't compare
		checksum_deep_us:   f64, // ... and of one they do (every 16th: every extra's whole state)
		window:             int,
		step_plus_resim_us: f64,
		snapshot_bytes:     int,
		within_target:      bool,
		mismatches:         int,
	}
	// The netcode's cost (the headless `net-bench` mode): a game's session on the virtual clock under `bad`, 4 clients.
	Net_Line :: struct {
		wall_ms:            f64,
		rollbacks:          int,
		rollback_depth_avg: f64,
		stall_ticks:        int,
		replaced_inputs:    int,
		resim_us:           int,
		relay_bytes_per_s:  f64,
		client_bytes_per_s: f64,
		resends:            int,
	}
	// The sim's sparse-table walk (the headless `table-bench` mode, game-independent): reported, no target.
	Table_Line :: struct {
		capacity:       int,
		live:           int,
		sparse_mean_us: f64,
		sparse_p99_us:  f64,
		dense_mean_us:  f64,
	}
	Summary :: struct {
		platform:   string,
		commit:     string,
		target_us:  f64,
		benchmarks: map[string]Bench_Line,
		net:        map[string]Net_Line,
		table:      Table_Line,
	}
	summary := new(Summary)
	summary^ = {
		platform  = PLATFORM,
		commit    = git_commit(),
		target_us = BENCH_TARGET_US,
	}
	failed: [dynamic]string
	for game in games {
		// alone: nothing else runs meanwhile, so the timings are clean
		result := run_proc({
			cmd     = strs(headless_path(game.name, .release), "bench"),
			capture = true,
			quiet   = true,
			timeout = 900 * time.Second,
			log_to  = join(work, game.name),
		})
		obj, ok := last_json_object(result.stdout)
		if !result.ok || !ok {
			log("uni: bench %s failed (exit %d):\n%s", game.name, result.exit_code, tail(result.stderr, 2000))
			append(&failed, game.name)
			continue
		}
		stat :: proc(object: json.Object, key, field: string) -> f64 {
			section, _ := object[key].(json.Object)
			return json_f64(section[field])
		}
		bench := Bench_Line {
			what             = json_string(obj["what"]),
			step_mean_us     = stat(obj, "step_us", "mean"),
			step_p99_us      = stat(obj, "step_us", "p99"),
			save_mean_us     = stat(obj, "save_us", "mean"),
			restore_mean_us  = stat(obj, "restore_us", "mean"),
			resim_mean_us    = stat(obj, "resim_us", "mean"),
			resim_p99_us     = stat(obj, "resim_us", "p99"),
			resim_final_us   = stat(obj, "resim_final_us", "mean"),
			checksum_us      = stat(obj, "checksum_us", "mean"),
			checksum_deep_us = stat(obj, "checksum_deep_us", "mean"),
			window           = json_int(obj["window"]),
			snapshot_bytes   = json_int(obj["snapshot_bytes"]),
			mismatches       = json_int(obj["mismatches"]),
		}
		bench.step_plus_resim_us = bench.step_mean_us + bench.resim_mean_us
		bench.within_target = bench.step_plus_resim_us <= BENCH_TARGET_US
		summary.benchmarks[game.name] = bench
		log(
			"%-12s step %5.0f us + %d-tick re-sim %5.0f us = %5.2f ms (target <= %.0f ms: %s); final ticks %.0f us; save %.0f us, restore %.0f us, checksum %.1f us (deep %.1f us), snapshot %d bytes",
			game.name,
			bench.step_mean_us,
			bench.window,
			bench.resim_mean_us,
			bench.step_plus_resim_us / 1000,
			BENCH_TARGET_US / 1000,
			bench.within_target ? "yes" : "NO",
			bench.resim_final_us,
			bench.save_mean_us,
			bench.restore_mean_us,
			bench.checksum_us,
			bench.checksum_deep_us,
			bench.snapshot_bytes,
		)
		if bench.mismatches > 0 {
			append(&failed, game.name) // a re-sim that disagrees is a bug, whatever the timing
		}
		net_result := run_proc({
			cmd     = strs(headless_path(game.name, .release), "net-bench"),
			capture = true,
			quiet   = true,
			timeout = 300 * time.Second,
			log_to  = join(work, aprintf("%s-net", game.name)),
		})
		net_obj, net_ok := last_json_object(net_result.stdout)
		if !net_result.ok || !net_ok {
			log(
				"uni: net-bench %s failed (exit %d):\n%s",
				game.name,
				net_result.exit_code,
				tail(net_result.stderr, 2000),
			)
			append(&failed, aprintf("%s net-bench", game.name))
			continue
		}
		steps_us, _ := net_obj["step_us"].(json.Object)
		net := Net_Line {
			wall_ms            = json_f64(net_obj["wall_ms"]),
			rollbacks          = json_int(net_obj["rollbacks"]),
			rollback_depth_avg = json_f64(net_obj["rollback_depth_avg"]),
			stall_ticks        = json_int(net_obj["stall_ticks"]),
			replaced_inputs    = json_int(net_obj["replaced_inputs"]),
			resim_us           = json_int(steps_us["resim"]),
			relay_bytes_per_s  = json_f64(net_obj["relay_bytes_per_s"]),
			client_bytes_per_s = json_f64(net_obj["client_bytes_per_s"]),
			resends            = json_int(net_obj["resends"]),
		}
		summary.net[game.name] = net
		log(
			"%-12s session (4 clients, bad, virtual clock) %.0f ms: %d rollbacks (depth %.1f, re-sim %.0f ms), %d stalls, %d inputs replaced; relay %.0f kB/s, client %.1f kB/s, %d resends",
			"",
			net.wall_ms,
			net.rollbacks,
			net.rollback_depth_avg,
			f64(net.resim_us) / 1000,
			net.stall_ticks,
			net.replaced_inputs,
			net.relay_bytes_per_s / 1000,
			net.client_bytes_per_s / 1000,
			net.resends,
		)
	}
	if len(games) > 0 {
		// any game's binary runs it; once is enough
		result := run_proc({
				cmd     = strs(headless_path(games[0].name, .release), "table-bench"),
				capture = true,
				quiet   = true,
				timeout = 120 * time.Second,
				log_to  = join(work, "table"),
			})
		obj, ok := last_json_object(result.stdout)
		if result.ok && ok {
			section :: proc(object: json.Object, key, field: string) -> f64 {
				inner, _ := object[key].(json.Object)
				return json_f64(inner[field])
			}
			summary.table = {
				capacity       = json_int(obj["capacity"]),
				live           = json_int(obj["live"]),
				sparse_mean_us = section(obj, "sparse_us", "mean"),
				sparse_p99_us  = section(obj, "sparse_us", "p99"),
				dense_mean_us  = section(obj, "dense_us", "mean"),
			}
			log(
				"%-12s walk of a %d-slot table holding %d: %.1f us (p99 %.1f); the same %d dense: %.1f us",
				"sim.table",
				summary.table.capacity,
				summary.table.live,
				summary.table.sparse_mean_us,
				summary.table.sparse_p99_us,
				summary.table.live,
				summary.table.dense_mean_us,
			)
		} else {
			log("uni: table-bench failed (exit %d):\n%s", result.exit_code, tail(result.stderr, 2000))
			append(&failed, "table-bench")
		}
	}
	if data, err := json.marshal(summary^, {pretty = true}); err == nil {
		write_file(join(state.project.out, "bench.json"), data)
	}
	if len(failed) > 0 {
		return {
			ok      = false,
			summary = aprintf("bench failed: %s (.out/bench/)", strings.join(failed[:], ", ")),
			data    = summary^,
		}
	}
	return {
		ok      = true,
		summary = aprintf("bench: %d game(s), sim and netcode benchmarks, reported in .out/bench.json", len(games)),
		data    = summary^,
	}
}

// A JSON number as an f64, or 0 when it is missing or not a number: reads the headless binaries' benchmark
// reports for `bench`.
json_f64 :: proc(value: json.Value) -> f64 {
	#partial switch number in value {
	case json.Float:
		return f64(number)
	case json.Integer:
		return f64(number)
	}
	return 0
}

// The last line of a text that parses as a JSON object.
last_json_object :: proc(text: string) -> (json.Object, bool) {
	lines := strings.split_lines(text)
	#reverse for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "{") {
			if value, err := json.parse_string(trimmed); err == nil {
				if object, ok := value.(json.Object); ok {
					return object, true
				}
			}
		}
	}
	return nil, false
}

// --- record-reference -------------------------------------------------------------------------------------------

@(private)
Record_Reference_Opts :: struct {
	game: string `args:"pos=0,required" usage:"the game (in this repo also toy: tests/scenarios)"`,
}

// Builds the game's end-to-end suite with -define:UNIFIED_REGEN=true and runs it: its reference test writes a new
// reference run (ref.log, ref.trace, the snapshot, ref.json saying where it was made), checks it, and the files show
// up in `git status`. Commit them with the change that made them necessary (the sim-change skill).
@(private)
cmd_record_reference :: proc(args: []string) -> Result {
	opts: Record_Reference_Opts
	parse(&opts, args)
	pkg: string
	needs_box3d: bool
	if opts.game == "toy" && is_unified_repo() {
		pkg = join(state.project.root, "tests", "scenarios")
		needs_box3d = true
	} else {
		selected := game(opts.game)
		pkg = join(selected.dir, "simulation", "tests")
		needs_box3d = game_uses_box3d(selected)
	}
	if !os.is_file(join(pkg, "suite_test.odin")) {
		usage("%s has no end-to-end suite (suite_test.odin)", rel(pkg))
	}
	exe := join(state.project.out, "record-reference", aprintf("%s_suite%s", opts.game, EXE))
	make_dirs(os.dir(exe))
	if needs_box3d {
		ensure_box3d()
		stage_box3d(os.dir(exe))
	}
	commit := git_commit()
	cmd: [dynamic]string
	append(&cmd, odin(), "build", pkg, aprintf("-out:%s", exe), "-define:UNIFIED_REGEN=true")
	append(&cmd, ..collection())
	append(&cmd, aprintf("-define:UNIFIED_REGEN_COMMIT=%s", commit != "" ? commit : "unknown"))
	append(&cmd, ..TEST_RUN_FLAGS)
	append(&cmd, ..TEST_FLAGS)
	append(&cmd, ..VET)
	must_run({cmd = cmd[:]}, aprintf("record-reference %s: the build", opts.game))
	if !run_test_binary(exe, time.Duration(state.command.budget * CI_BUDGET_SCALE * f64(time.Second))) {
		fatal("record-reference %s: the suite failed", opts.game)
	}
	data := join(pkg, "testdata")
	status := run_proc({
		cmd     = strs(git(), "-C", state.project.root, "status", "--short", "--", data),
		capture = true,
		quiet   = true,
	})
	changed := strings.trim_space(status.stdout)
	if changed == "" {
		return {
			ok      = true,
			summary = aprintf("record-reference %s: reproduced byte for byte, nothing changed", opts.game),
		}
	}
	log("%s", changed)
	return {
		ok      = true,
		summary = aprintf("record-reference %s -> %s (commit the files above with the change)", opts.game, rel(data)),
	}
}

// --- setup ------------------------------------------------------------------------------------------------------

@(private)
Setup_Opts :: struct {
	check: bool `usage:"report only: fetch and build nothing"`,
}

// Fetches and builds everything the project needs, and reports each dependency's version and where it came from.
@(private)
cmd_setup :: proc(args: []string) -> Result {
	opts: Setup_Opts
	parse(&opts, args)
	Dep :: struct {
		name:    string,
		version: string,
		source:  string,
		ready:   bool,
	}
	deps: [dynamic]Dep
	uses_box3d, uses_eos := is_unified_repo(), is_unified_repo()
	for game in state.project.games {
		uses_box3d = uses_box3d || game_uses_box3d(game)
		uses_eos = uses_eos || extension_uses_eos(game)
	}
	append(&deps, Dep{"odin", aprintf("%s (%s)", ODIN_VERSION, ODIN_VERSION_HASH), which("odin"), true})
	if !opts.check {
		ensure_odinfmt()
		ensure_bindings()
		if uses_box3d {
			ensure_box3d(build = true)
		}
		godot()
	}
	odinfmt := join(state.project.out, "odinfmt", aprintf("odinfmt%s", EXE))
	append(
		&deps,
		Dep{"odinfmt", aprintf("OLS %s", pin("odinfmt", "commit")[:10]), "built from the pin", os.is_file(odinfmt)},
	)
	if uses_box3d {
		version, src :=
			pin("box3d", "tag"), aprintf("pinned release (.out/unified-box3d; the zip in %s/downloads)", user_cache())
		if local := box3d_local(); local != "" {
			version = "local"
			src = aprintf("UNIFIED_BOX3D (%s): %s, built by its b3", env_source("UNIFIED_BOX3D"), local)
		}
		append(&deps, Dep{"box3d", version, src, box3d_ready()})
	}
	godot_dir, godot_exe, _, _ := godot_download()
	godot_source := aprintf("pinned download, shared by every checkout (%s)", godot_dir)
	if os.get_env("UNIFIED_GODOT", context.temp_allocator) != "" {
		godot_source = aprintf("UNIFIED_GODOT (%s)", env_source("UNIFIED_GODOT"))
	}
	if env := os.get_env("UNIFIED_GODOT", context.temp_allocator); env != "" {
		godot_exe = env
	}
	append(&deps, Dep{"godot", pin("godot", "version"), godot_source, os.is_file(godot_exe)})
	if uses_eos {
		// never fetched (Epic's licence): online play only, so a missing SDK is reported, not a failure
		src := aprintf("UNIFIED_EOS_SDK (%s)", env_source("UNIFIED_EOS_SDK"))
		if problem := eos_problem(); problem != "" {
			src = aprintf("optional, for online play: %s", problem)
		}
		append(&deps, Dep{"eos_sdk", pin("eos_sdk", "version"), src, true})
	}
	all_ready := true
	for dep in deps {
		log("  %-8s %-24s %s%s", dep.name, dep.version, dep.source, dep.ready ? "" : "  (missing)")
		all_ready = all_ready && dep.ready
	}
	return {
		ok      = opts.check || all_ready,
		summary = aprintf("setup: %s", all_ready ? "everything is in place" : "some dependencies are missing"),
		data    = box(deps[:]),
	}
}

// Where a variable's value comes from: .env or the environment.
@(private)
env_source :: proc(key: string) -> string {
	for env_key in state.env_keys {
		if env_key == key {
			return ".env"
		}
	}
	return "environment"
}

// --- clean ------------------------------------------------------------------------------------------------------

@(private)
Clean_Opts :: struct {
	check: bool `usage:"report only: list what would be removed, remove nothing"`,
	cache: bool `usage:"also the per-user cache's Godot and unified-box3d downloads, shared by every checkout (the shims' Odin stays)"`,
}

// Removes what the CLI built or fetched: every .out/ and .godot/ in the project (outside hidden directories, so not
// another checkout's under .claude/), and the generated Godot bindings. The running
// CLI stays, with its manifest and `current` (Windows can't delete a running .exe; the next command needs no
// bootstrap). What every checkout shares stays: the per-user cache (Godot, the unified-box3d zip; `--cache` clears
// them) and Godot's export templates (Godot's user directory).
@(private)
cmd_clean :: proc(args: []string) -> Result {
	opts: Clean_Opts
	parse(&opts, args)
	project := state.project
	gdext := join(project.unified, "src", "gdext")
	targets: [dynamic]string
	append(&targets, join(gdext, "api.gen.odin"), join(gdext, "gdi"))
	// The root's .out/ but the running CLI.
	exe, _ := os.get_executable_path(context.allocator)
	cli_dir := join(project.out, "cli")
	keep := []string{os.base(exe), aprintf("%s.inputs", os.base(exe)), "current"}
	if entries, err := os.read_all_directory_by_path(project.out, context.allocator); err == nil {
		for entry in entries {
			if entry.name != "cli" {
				append(&targets, entry.fullpath)
			}
		}
	}
	if entries, err := os.read_all_directory_by_path(cli_dir, context.allocator); err == nil {
		for entry in entries {
			if !slice.contains(keep, entry.name) {
				append(&targets, entry.fullpath)
			}
		}
	}
	if opts.cache {
		append(&targets, ..user_cache_cleanable())
	}
	// Every other .out/ and .godot/: a game's, a Godot test project's.
	walker := os.walker_create(project.root)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Directory {
			continue
		}
		if info.name == ".out" || info.name == ".godot" {
			if !same_path(info.fullpath, project.out) {
				append(&targets, strings.clone(info.fullpath))
			}
			os.walker_skip_dir(&walker)
		} else if strings.has_prefix(info.name, ".") {
			os.walker_skip_dir(&walker) // .git, .claude (other checkouts), .toolchains
		}
	}
	removed: [dynamic]string
	failed := 0
	for target in targets {
		if !os.exists(target) {
			continue
		}
		name, _ := strings.replace_all(rel(target), "\\", "/")
		append(&removed, name)
		if opts.check {
			log("  %s", name)
			continue
		}
		// remove_all can return no error and leave files a running process holds (Windows: a Godot this project
		// started, its loaded extension, an older uni still running), so what is left decides.
		err := os.remove_all(target)
		if os.exists(target) {
			log(
				"  %s: not removed%s: in use? (close Godot and other uni commands, then run clean again)",
				name,
				err != nil ? aprintf(" (%v)", err) : "",
			)
			failed += 1
		} else {
			log("  %s", name)
		}
	}
	if !opts.cache {
		log("  kept: the per-user cache %s, shared by every checkout (--cache clears its downloads)", user_cache())
	}
	summary: string
	switch {
	case len(removed) == 0:
		summary = "clean: nothing to remove"
	case opts.check:
		summary = aprintf("clean: %d paths would go (nothing removed)", len(removed))
	case failed > 0:
		summary = aprintf("clean: %d of %d paths could not be removed (above)", failed, len(removed))
	case:
		summary = aprintf("clean: removed %d paths (uni setup fetches and builds them again)", len(removed))
	}
	return {
		ok      = failed == 0,
		summary = summary,
		data    = box(removed[:]),
	}
}

// Whether two paths name the same place (slashes and, on Windows, case aside).
@(private)
same_path :: proc(first, second: string) -> bool {
	norm :: proc(path: string) -> string {
		slashed, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
		slashed = strings.trim_right(slashed, "/")
		return ODIN_OS == .Windows ? strings.to_lower(slashed, context.temp_allocator) : slashed
	}
	return norm(first) == norm(second)
}
