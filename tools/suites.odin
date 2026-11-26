package main

import "core:encoding/json"
import "core:slice"
import "core:strings"
import "core:time"

import "unified:cli"

// This repo's own test suites: the netcode over real UDP, and the Godot bindings under headless Godot.
private_suites :: proc() -> []cli.Suite {
	return slice.clone([]cli.Suite {
		{
			name = "net",
			summary = "the toy's relay and 3 clients over real UDP on the real clock (5 s; --long: 15 s)",
			run = suite_net,
			beside = true,
			prepare = proc(_: []cli.Game, _: cli.Test_Options) {cli.build_headless(.release, only = "toy")},
		},
		{
			name = "godot-bindings",
			summary = "tests/godot and tests/godot_views (views, the level marker order, the session lifecycle, UnifiedTool, the crowd bake, the forced verified timeline) under headless Godot",
			run = suite_godot_bindings,
			beside = true,
			prepare = proc(_: []cli.Game, _: cli.Test_Options) {
				cli.godot()
				cli.ensure_bindings()
			},
		},
	})
}

// --- net --------------------------------------------------------------------------------------------------------

UDP_TICKS :: 320 // 5 s of the toy's 64 Hz clock
UDP_TICKS_LONG :: 960 // with `test --long`: 15 s
UDP_CLIENTS :: 3 // the last one under the `bad` profile

// A relay and UDP_CLIENTS client processes of the toy's binary over localhost UDP on the real clock: every client
// verifies every tick, their checksums (every 16th tick) agree, and nobody reports a desync. Each process's output
// goes to .out/net/ (a failure names it).
suite_net :: proc(games: []cli.Game, opts: cli.Test_Options) -> bool {
	cli.build_headless(.release, only = "toy")
	binary := cli.headless_path("toy", .release)
	work := cli.join(cli.state.project.out, "net")
	cli.remove_tree(work)
	cli.make_dirs(work)
	start := time.tick_now()
	detail, ok := udp_processes(binary, work, opts.long ? UDP_TICKS_LONG : UDP_TICKS)
	secs := cli.seconds_since(start)
	cli.log("udp_processes %s %6.1fs  %s", ok ? "PASS" : "FAIL", secs, detail)
	if !ok {
		cli.log("  each process's command line and output: %s", cli.rel(work))
	}
	return ok
}

@(private)
udp_processes :: proc(binary, work: string, ticks: int) -> (detail: string, ok: bool) {
	port := cli.free_udp_port()
	timeout := time.Duration(f64(ticks) / 64 * 4 + 90) * time.Second
	start :: proc(binary, work, name: string, timeout: time.Duration, args: ..string) -> cli.Proc {
		cmd: [dynamic]string
		append(&cmd, binary)
		append(&cmd, ..args)
		cli.write_text(cli.join(work, cli.aprintf("%s.cmd", name)), cli.aprintf("%s\n", strings.join(cmd[:], " ")))
		return cli.start({
			cmd     = cmd[:],
			dir     = work,
			capture = true,
			quiet   = true,
			timeout = timeout,
			log_to  = cli.join(work, name),
		})
	}
	relay := start(
		binary,
		work,
		"relay",
		timeout,
		"relay",
		"--port",
		cli.aprintf("%d", port),
		"--players",
		cli.aprintf("%d", UDP_CLIENTS),
		"--ticks",
		cli.aprintf("%d", ticks),
		"--log",
		cli.join(work, "relay.log"),
	)
	time.sleep(500 * time.Millisecond)
	clients: [UDP_CLIENTS]cli.Proc
	for i in 0 ..< UDP_CLIENTS {
		args: [dynamic]string
		append(
			&args,
			"client",
			"--connect",
			cli.aprintf("127.0.0.1:%d", port),
			"--slot",
			cli.aprintf("%d", i),
			"--ticks",
			cli.aprintf("%d", ticks),
		)
		if i == UDP_CLIENTS - 1 {
			append(&args, "--profile", "bad")
		}
		clients[i] = start(binary, work, cli.aprintf("client%d", i), timeout, ..args[:])
	}
	errors: [dynamic]string
	finish :: proc(child: ^cli.Proc, name: string, errors: ^[dynamic]string) -> json.Object {
		ran := cli.wait(child)
		if ran.timed_out {
			append(errors, cli.aprintf("%s: timed out (killed)", name))
			return nil
		}
		if ran.exit_code != 0 {
			append(
				errors,
				cli.aprintf(
					"%s: exit code %d: %s",
					name,
					ran.exit_code,
					strings.trim_space(cli.tail(ran.stderr, 400)),
				),
			)
			return nil
		}
		obj, ok := cli.last_json_object(ran.stdout)
		if !ok {
			append(errors, cli.aprintf("%s: no JSON line on stdout", name))
		}
		return obj
	}
	results: [UDP_CLIENTS]json.Object
	for i in 0 ..< UDP_CLIENTS {
		results[i] = finish(&clients[i], cli.aprintf("client%d", i), &errors)
	}
	relay_report := finish(&relay, "relay", &errors)
	if len(errors) > 0 {
		return strings.join(errors[:], "; "), false
	}
	desyncs := cli.json_int(relay_report["desyncs"])
	for report in results {
		desyncs += max(0, cli.json_int(report["desyncs"]))
	}
	if desyncs > 0 {
		return cli.aprintf("%d desync(s)", desyncs), false
	}
	ref: map[int]string
	for report, i in results {
		if cli.json_int(report["final_tick"]) != ticks {
			return cli.aprintf("client %d verified up to tick %d of %d", i, cli.json_int(report["final_tick"]), ticks),
				false
		}
		sums := cli.checksums(report["checksums"])
		if len(sums) != ticks / 16 {
			return cli.aprintf("client %d's checksums don't cover every 16th tick", i), false
		}
		if i == 0 {
			ref = sums
			continue
		}
		for tick := 16; tick <= ticks; tick += 16 {
			if sums[tick] != ref[tick] {
				return cli.aprintf(
						"client %d's checksum differs first at tick %d: %s vs %s",
						i,
						tick,
						sums[tick],
						ref[tick],
					),
					false
			}
		}
	}
	return cli.aprintf(
			"toy relay + %d client processes (one under `bad`) over UDP, %d ticks on the real clock: 0 desyncs, checksums agree",
			UDP_CLIENTS,
			ticks,
		),
		true
}

// --- godot-bindings ---------------------------------------------------------------------------------------------

// The Godot-side library tests: the gdext bindings (tests/godot), unified:godot's views and send_command's refusals,
// Unified.level_markers against the level exporter, its session lifecycle, UnifiedTool's helpers, the crowd bake and
// the dev UI's switch forcing the verified timeline (tests/godot_views),
// each an extension plus a test script under headless Godot.
// `expected`: error lines the test provokes on purpose (they must show up, and nothing else may). A passing run says
// nothing (--verbose: each PASS line); a failing one prints that Godot run's whole output.
suite_godot_bindings :: proc(games: []cli.Game, opts: cli.Test_Options) -> bool {
	Project :: struct {
		dir, pkg, stem, script, summary: string,
		expected:                        []string,
		args:                            []string, // after the script's --local-net
	}
	root := cli.state.project.root
	views := cli.join(root, "tests", "godot_views")
	fixed := []Project {
		{
			cli.join(root, "tests", "godot"),
			cli.join(root, "tests", "godot", "ext"),
			"gdext_test",
			"test.gd",
			"GDEXT TESTS",
			nil,
			nil,
		},
		{
			views,
			cli.join(views, "ext"),
			"views_test",
			"test.gd",
			"VIEWS TESTS",
			{
				"unified: send_command: ",
				"unified: CommandMark.",
				"has no `var data: ViewDecoy2d`",
				"is not a kind of the game's View union",
				"is not a thing's index",
				"unified: UnifiedSetup.from_json: ",
				"which view_root has no node at",
				"it holds at most",
				"it holds exactly",
				"unified: UnifiedInput.picks: item 0: ",
				"unified: UnifiedInput.flags: item 0: ",
			},
			nil,
		},
		{views, cli.join(views, "ext"), "views_test", "markers_check.gd", "MARKERS TESTS", nil, nil},
		{views, cli.join(views, "ext"), "views_test", "tool_check.gd", "TOOL TESTS", nil, nil},
		{views, cli.join(views, "ext"), "views_test", "crowd_test.gd", "CROWD TESTS", nil, nil},
		{
			views,
			cli.join(views, "ext"),
			"views_test",
			"verified_check.gd",
			"VERIFIED TESTS",
			nil,
			cli.strs("--verified-players"),
		},
	}
	// The session check mostly waits on purpose (goodbyes, timers), so its sections run in groups, each in a Godot
	// process of its own beside the rest, so no group outlasts views' test.gd.
	projects: [dynamic]Project
	append(&projects, ..fixed)
	for sections in SESSION_CHECK_GROUPS {
		append(&projects, Project {
			views,
			cli.join(views, "ext"),
			"views_test",
			"session_check.gd",
			"SESSION TESTS",
			nil,
			cli.strs("--sections", sections),
		})
	}
	cli.ensure_bindings()
	// The stale extensions build at once, then every Godot run goes at once; their results are read in order.
	Started :: struct {
		build: cli.Build,
		child: cli.Proc,
	}
	building: [dynamic]Started
	for project, i in projects {
		if i > 0 && project.pkg == projects[i - 1].pkg {
			continue
		}
		build := cli.project_extension_build(project.dir, project.pkg, project.stem)
		if cli.stale(build) {
			append(&building, Started{build, cli.start_build(build)})
		}
	}
	for &started in building {
		if !cli.finish_build(started.build, &started.child).ok {
			cli.fatal("building %s failed", cli.rel(started.build.pkg))
		}
	}
	// tests/godot runs unified's level exporter (mirrored as res://unified/tools_godot/, so it is imported first);
	// tests/godot_views/markers_check.gd extends it (loaded by path), and tool_check.gd and crowd_test.gd extend
	// UnifiedTool (by its class name: imported too)
	cli.ensure_imported(projects[0].dir)
	cli.ensure_imported(views)
	// One more run beside them: a script error under the debugger (-d, as `uni tool` runs headless) must end the run
	// at once through the `quit` on its stdin, with the error printed (tests/godot/debugger_error.gd).
	runs := make([]cli.Run, len(projects) + 1)
	runs[len(projects)] = {
		cmd     = cli.strs(
			cli.godot(),
			"--headless",
			"-d",
			"--path",
			projects[0].dir,
			"-s",
			"res://debugger_error.gd",
		),
		capture = true,
		timeout = DEBUGGER_ERROR_TIMEOUT,
		env     = cli.user_env(projects[0].dir),
	}
	for project, i in projects {
		cli.write_extension_list_dir(project.dir)
		// --verbose: Godot reports orphan StringNames and leaked objects at exit only then
		cmd: [dynamic]string
		append(
			&cmd,
			cli.godot(),
			"--headless",
			"--verbose",
			"--path",
			project.dir,
			"-s",
			cli.aprintf("res://%s", project.script),
			"--",
			"--local-net",
		)
		append(&cmd, ..project.args)
		runs[i] = {
			cmd     = cmd[:],
			capture = true,
			timeout = 30 * time.Second,
			env     = cli.user_env(project.dir),
		}
	}
	ok := true
	for ran, i in cli.run_all(runs) {
		if i == len(projects) {
			out := strings.concatenate({ran.stdout, ran.stderr})
			// (Godot's exit code after the prompt's `quit` is 0: a tool run fails on the error line, judge_tool)
			passed :=
				!ran.timed_out &&
				strings.contains(out, "DEBUGGER ERROR: about to fail") &&
				strings.contains(out, "SCRIPT ERROR") &&
				!strings.contains(out, "not reached")
			if !passed {
				cli.log("%s", strings.trim_right_space(out))
				cli.log(
					"uni: tests/godot debugger_error.gd: FAILED: a script error under -d must end the run within %.0fs, failing, with the error printed%s",
					time.duration_seconds(DEBUGGER_ERROR_TIMEOUT),
					ran.timed_out ? " (it timed out: the debugger prompt never quit)" : "",
				)
			} else if cli.state.verbose {
				cli.log("uni: tests/godot debugger_error.gd: ok, ended at the debugger prompt (%.1fs)", ran.seconds)
			}
			ok = ok && passed
			continue
		}
		project := projects[i]
		out := strings.concatenate({ran.stdout, ran.stderr})
		errs: [dynamic]string
		append(&errs, ..cli.godot_errors(out))
		append(&errs, ..cli.lines_with(out, "Orphan StringName", "leaked at exit"))
		if len(project.expected) > 0 {
			provoked := make([]bool, len(project.expected), context.temp_allocator)
			kept: [dynamic]string
			outer: for line in errs {
				for expected, k in project.expected {
					if strings.contains(line, expected) {
						provoked[k] = true
						continue outer
					}
				}
				append(&kept, line)
			}
			errs = kept
			for expected, k in project.expected {
				if !provoked[k] do append(&errs, cli.aprintf("no error line with %q: the test expects some", expected))
			}
		}
		passed := ran.ok && len(errs) == 0 && strings.contains(out, cli.aprintf("%s: 0 failed", project.summary))
		if !passed {
			cli.log("%s", strings.trim_right_space(out))
		} else if cli.state.verbose {
			for line in strings.split_lines(ran.stdout) {
				if strings.has_prefix(line, "PASS") || strings.has_prefix(line, project.summary) {
					cli.log("%s", line)
				}
			}
		}
		for line in errs {
			cli.log("godot: %s", line)
		}
		if !passed || cli.state.verbose {
			cli.log(
				"uni: %s %s%s%s: %s (%.1fs)",
				cli.rel(project.dir),
				project.script,
				len(project.args) > 0 ? " " : "",
				strings.join(project.args, " "),
				passed ? "ok" : "FAILED",
				ran.seconds,
			)
		}
		ok = ok && passed
	}
	return ok
}

// The session check's sections (tests/godot_views/session_check.gd) by Godot process: about as long each (3 hosts again
// on the port 2 hosted on; 7 records the session it replays, which 10 runs past the length of).
SESSION_CHECK_GROUPS :: []string{"1,9,10,15", "2,3,6,14", "4,5,8,11", "7,12,13"}

// How long the debugger-error run may take: it ends in about a second; the prompt waiting for good would hit this.
DEBUGGER_ERROR_TIMEOUT :: 15 * time.Second
