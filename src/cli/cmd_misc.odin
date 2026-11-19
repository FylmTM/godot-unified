// The commands bench, setup and clean.
package cli

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// A client's worst frame must fit here: a forward step, a restore, a re-sim at the prediction cap (14 ticks at 64 Hz)
// and a deep checksum (a checksum tick inside the re-sim), each at its p99 (unified's target, the frame budget's bad
// frames; each game owns its benchmark's setup). The sessions time whole client steps against it too.
BENCH_TARGET_US :: 6000.0

@(private)
Bench_Opts :: struct {
	overflow: [dynamic]string `hint:"[game...]" usage:"games (default: every game with a headless binary)"`,
}

// `bench -h`: how a benchmark measures, and what is checked.
@(private)
bench_details :: proc() -> string {
	return aprintf(
		"A game's benchmark (its headless `bench` mode) steps its standard setup and, every tick, rolls back to the\n" +
		"prediction cap and re-simulates (the worst case the netcode makes: a bound, not a typical frame); the first\n" +
		"window + 64 ticks run untimed. The target: a step, a restore, that re-sim and a deep checksum within %.0f ms at\n" +
		"their p99. A re-sim whose checksum differs fails the run. Then its `session` on the virtual clock, 4 clients:\n" +
		"on the game's own script for the bytes a session moves, under `bad` (the stress case) and under `wan` (the\n" +
		"common case) with the 4th connecting halfway and joining as a player does (the join: Hello to playing, the\n" +
		"bytes it took, the snapshot's transfer and the joiner's catch-up step); then a shorter one under `bad` whose\n" +
		"inputs change every tick (--script churn: rollbacks on most ticks, a bound from above) for the rollbacks, the\n" +
		"stalls and every client step that stepped the sim (p99, worst): the measure the target models. Then the\n" +
		"project's own rows. Reported in .out/bench.json, not gated by time.",
		BENCH_TARGET_US / 1000,
	)
}

// Timing samples as the headless modes report them, in microseconds.
Bench_Stat :: struct {
	mean, p99: f64,
}

// A game's `bench` report (the headless mode's JSON line), with the target check added.
Bench_Report :: struct {
	skipped:            bool, // the game has no standard benchmark
	what:               string,
	entities:           int,
	window:             int,
	ticks:              int,
	warmup:             int,
	step_us:            Bench_Stat,
	save_us:            Bench_Stat,
	restore_us:         Bench_Stat,
	resim_us:           Bench_Stat,
	resim_final_us:     Bench_Stat, // the same re-sim of final ticks, saving only the last (a catch-up burst)
	checksum_us:        Bench_Stat, // sim.checksum of a tick peers don't compare
	checksum_deep_us:   Bench_Stat, // ... and of one they do (every 16th: every extra's whole state)
	snapshot_encode_us: Bench_Stat, // a portable snapshot of a checksum tick (a joiner's, a desync report's)
	snapshot_keep_us:   Bench_Stat, // a checksum tick kept for a desync report (every checksum tick, every client)
	snapshot_bytes:     int,
	save_bytes:         int, // what each tick's save copies (the block and the extras' saves)
	mismatches:         int,
	frame_p99_us:       f64, // the target's measure: step + restore + re-sim + deep checksum, each at its p99
	within_target:      bool,
}

// A game's `session` report: clients on the virtual clock under a network profile.
Net_Report :: struct {
	clients:             int,
	wall_ms:             f64,
	rollbacks:           int,
	rollback_depth_avg:  f64,
	resim_ticks:         int,
	stall_ticks:         int,
	replaced_inputs:     int,
	desyncs:             int,
	step_us:             struct {
		verified, resim, predicted: i64,
	},
	relay_bytes_per_s:   f64,
	client_bytes_per_s:  f64,
	resends:             int,
	client_step_us:      struct {
		p99, max: f64, // every client step that stepped the sim, every client's: its real time
	},
	late_join:           int, // the tick the last client joined at (0: none)
	join_ms:             f64, // its Hello to playing (snapshot restored and checked), virtual ms
	join_bytes:          int, // the bytes it received by then
	join_snapshot_bytes: int, // its snapshot
	join_transfer_ms:    f64, // the snapshot's Snap_Begin to its last chunk, virtual ms
	join_step_max_us:    f64, // the joiner's worst client step (its catch-up after the check)
}

// A game's sessions: on its own script the stress case and the common one with a late joiner (their bytes, the join),
// and a shorter stress case whose inputs change every tick (its rollbacks, stalls and client steps).
Net_Rows :: struct {
	bad:   Net_Report,
	wan:   Net_Report,
	churn: Net_Report,
}

// The churn session's length: its rollbacks, stalls and client steps settle well within it.
@(private)
BENCH_CHURN_TICKS :: "600"

// .out/bench.json.
Bench_Summary :: struct {
	platform:   string,
	commit:     string,
	target_us:  f64,
	benchmarks: map[string]Bench_Report,
	net:        map[string]Net_Rows,
	rows:       map[string]json.Value, // the project's own (Project_Config.bench: this repo's physics), as JSON
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
	summary := new(Bench_Summary)
	summary^ = {
		platform  = PLATFORM,
		commit    = git_commit(),
		target_us = BENCH_TARGET_US,
	}
	failed: [dynamic]string
	for game in games {
		// alone: nothing else runs meanwhile, so the timings are clean
		bench: Bench_Report
		if !run_report(headless_path(game.name, .release), {"bench"}, join(work, game.name), 900, &bench) {
			append(&failed, game.name)
			continue
		}
		if bench.skipped {
			continue // no standard benchmark (Headless.bench): nothing to measure
		}
		bench.frame_p99_us = bench.step_us.p99 + bench.restore_us.p99 + bench.resim_us.p99 + bench.checksum_deep_us.p99
		bench.within_target = bench.frame_p99_us <= BENCH_TARGET_US
		summary.benchmarks[game.name] = bench
		log(
			"%-12s step %5.0f us + restore %3.0f us + %d-tick re-sim %5.0f us + deep checksum %3.0f us = %5.2f ms at p99 (target <= %.0f ms: %s; means %.0f + %.0f us); final ticks %.0f us; save %.0f us (%d bytes), restore %.0f us, checksum %.1f us (deep %.1f us), snapshot %d bytes (encode %.0f us, keep %.0f us)",
			game.name,
			bench.step_us.p99,
			bench.restore_us.p99,
			bench.window,
			bench.resim_us.p99,
			bench.checksum_deep_us.p99,
			bench.frame_p99_us / 1000,
			BENCH_TARGET_US / 1000,
			bench.within_target ? "yes" : "NO",
			bench.step_us.mean,
			bench.resim_us.mean,
			bench.resim_final_us.mean,
			bench.save_us.mean,
			bench.save_bytes,
			bench.restore_us.mean,
			bench.checksum_us.mean,
			bench.checksum_deep_us.mean,
			bench.snapshot_bytes,
			bench.snapshot_encode_us.mean,
			bench.snapshot_keep_us.mean,
		)
		if bench.mismatches > 0 {
			append(&failed, game.name) // a re-sim that disagrees is a bug, whatever the timing
		}
		rows: Net_Rows
		sessions := [3]struct {
			name: string,
			args: []string,
			out:  ^Net_Report,
		} {
			{"bad", {"session", "--profile", "bad"}, &rows.bad},
			{"wan", {"session", "--profile", "wan", "--late-join", "3@600"}, &rows.wan},
			{"churn", {"session", "--profile", "bad", "--script", "churn", "--ticks", BENCH_CHURN_TICKS}, &rows.churn},
		}
		net_ok := true
		for session in sessions {
			if !run_report(
				headless_path(game.name, .release),
				session.args,
				join(work, aprintf("%s-%s", game.name, session.name)),
				300,
				session.out,
			) {
				append(&failed, aprintf("%s session (%s)", game.name, session.name))
				net_ok = false
				continue
			}
			net := session.out^
			if session.out == &rows.churn {
				log(
					"%-12s churn (%d clients, bad, %s ticks, every input changing every tick) %.0f ms: client step p99 %.0f us, worst %.2f ms; %d rollbacks (depth %.1f, re-sim %.0f ms), %d stalls",
					"",
					net.clients,
					BENCH_CHURN_TICKS,
					net.wall_ms,
					net.client_step_us.p99,
					net.client_step_us.max / 1000,
					net.rollbacks,
					net.rollback_depth_avg,
					f64(net.step_us.resim) / 1000,
					net.stall_ticks,
				)
				continue
			}
			join_text := ""
			if net.late_join != 0 {
				join_text = aprintf(
					"; the 4th joined at tick %d in %.0f ms (%.0f kB; its %.0f kB snapshot in %.0f ms, %.0f kB/s; catch-up step %.2f ms)",
					net.late_join,
					net.join_ms,
					f64(net.join_bytes) / 1000,
					f64(net.join_snapshot_bytes) / 1000,
					net.join_transfer_ms,
					net.join_transfer_ms > 0 ? f64(net.join_snapshot_bytes) / net.join_transfer_ms : 0,
					net.join_step_max_us / 1000,
				)
			}
			log(
				"%-12s session (%d clients, %s, the game's script) %.0f ms: relay %.1f kB/s, client %.1f kB/s, %d resends, %d inputs replaced%s",
				"",
				net.clients,
				session.name,
				net.wall_ms,
				net.relay_bytes_per_s / 1000,
				net.client_bytes_per_s / 1000,
				net.resends,
				net.replaced_inputs,
				join_text,
			)
		}
		if net_ok do summary.net[game.name] = rows
	}
	for row in state.config.bench {
		data, ok := row.run(work)
		// a row's report as JSON: json.marshal refuses a map of `any`
		row_json, marshal_err := json.marshal(data)
		value, parse_err := json.parse(row_json)
		if ok && marshal_err == nil && parse_err == nil {
			summary.rows[row.name] = value
		} else {
			append(&failed, row.name)
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
		summary = aprintf(
			"bench: %d game(s), the sim and netcode benchmarks%s, reported in .out/bench.json",
			len(summary.benchmarks),
			len(state.config.bench) > 0 ? " and the project's own" : "",
		),
		data    = summary^,
	}
}

// Runs a benchmark binary with `args` and reads its last JSON line into `report` (a struct in the line's shape: what it
// names is read, the rest left). False, with its output's tail logged, when it failed or printed no such line. Its
// output goes to `log_to` (.out/bench/).
run_report :: proc(binary: string, args: []string, log_to: string, timeout_s: int, report: ^$Report) -> bool {
	cmd: [dynamic]string
	append(&cmd, binary)
	append(&cmd, ..args)
	result := run_proc({
		cmd     = cmd[:],
		capture = true,
		quiet   = true,
		timeout = time.Duration(timeout_s) * time.Second,
		log_to  = log_to,
	})
	line, found := last_json_line(result.stdout)
	if !result.ok || !found || json.unmarshal_string(line, report) != nil {
		log(
			"uni: %s %s failed (exit %d):\n%s",
			os.base(binary),
			strings.join(args, " "),
			result.exit_code,
			tail(strings.concatenate({result.stdout, result.stderr}), 2000),
		)
		return false
	}
	return true
}

// The last line of a text that parses as a JSON object.
last_json_line :: proc(text: string) -> (string, bool) {
	lines := strings.split_lines(text)
	#reverse for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "{") {
			if value, err := json.parse_string(trimmed); err == nil {
				if _, ok := value.(json.Object); ok {
					return trimmed, true
				}
			}
		}
	}
	return "", false
}

// The last line of a text that parses as a JSON object, parsed.
last_json_object :: proc(text: string) -> (object: json.Object, ok: bool) {
	line := last_json_line(text) or_return
	value, _ := json.parse_string(line)
	return value.(json.Object)
}

// --- setup ------------------------------------------------------------------------------------------------------

@(private)
Setup_Opts :: struct {}

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
	uses_box3d, uses_eos := project_uses_box3d(), false
	for game in state.project.games {
		uses_box3d = uses_box3d || game_uses_box3d(game)
		uses_eos = uses_eos || extension_uses_eos(game)
	}
	append(&deps, Dep{"odin", aprintf("%s (%s)", ODIN_VERSION, ODIN_VERSION_HASH), which("odin"), true})
	ensure_odinfmt()
	ensure_bindings()
	if uses_box3d {
		ensure_box3d(build = true)
	}
	godot()
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
		ok      = all_ready,
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
			if path_key(info.fullpath) != path_key(project.out) {
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
