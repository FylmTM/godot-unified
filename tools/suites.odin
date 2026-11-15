package main

import "core:encoding/json"
import "core:strings"
import "core:time"

import "unified:cli"

// This repo's own test suites: the netcode over real UDP, and the Godot bindings under headless Godot.
private_suites :: proc() -> []cli.Suite {
	return cli.box_suites(
		{
			name = "net",
			summary = "the toy's relay and 3 clients over real UDP on the real clock (5 s; --long: 15 s)",
			budget = 10,
			long_budget = 25,
			run = suite_net,
			beside = true,
			prepare = proc() {cli.build_headless(.release)}, 	// .out/release/: the godot suite's binaries are there too
		},
		{
			name = "godot-bindings",
			summary = "tests/godot and tests/godot_views (views, then the session lifecycle) under headless Godot",
			budget = 5,
			run = suite_godot_bindings,
			beside = true,
			prepare = proc() {
				cli.godot()
				cli.ensure_bindings()
			},
		},
	)
}

// --- net --------------------------------------------------------------------------------------------------------

UDP_TICKS :: 320 // 5 s of the toy's 64 Hz clock
UDP_TICKS_LONG :: 960 // with `test --long`: 15 s
UDP_CLIENTS :: 3 // the last one under the `bad` profile

// A relay and UDP_CLIENTS client processes of the toy's binary over localhost UDP on the real clock: every client
// verifies every tick, their checksums (every 16th tick) agree, and nobody reports a desync. Writes .out/net.json
// (CI's job summary reads it) and each process's output to .out/net/.
suite_net :: proc(games: []cli.Game, only: []string) -> bool {
	cli.build_headless(.release)
	binary := cli.headless_path("toy", .release)
	work := cli.join(cli.state.project.out, "net")
	cli.remove_tree(work)
	cli.make_dirs(work)
	start := time.tick_now()
	detail, ok := udp_processes(binary, work, cli.state.long ? UDP_TICKS_LONG : UDP_TICKS)
	secs := cli.seconds_since(start)
	Test :: struct {
		status:  string,
		seconds: f64,
		detail:  string,
	}
	Summary :: struct {
		platform: string,
		commit:   string,
		ok:       bool,
		tests:    map[string]Test,
	}
	s := Summary {
		platform = cli.PLATFORM,
		commit   = cli.git_commit(),
		ok       = ok,
	}
	s.tests["udp_processes"] = {ok ? "pass" : "fail", cli.round2(secs), detail}
	if data, err := json.marshal(s, {pretty = true}); err == nil {
		cli.write_file(cli.join(cli.state.project.out, "net.json"), data)
	}
	cli.log("udp_processes %s %6.1fs  %s", ok ? "PASS" : "FAIL", secs, detail)
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
		cli.write_text(cli.join(work, cli.tprint("%s.cmd", name)), cli.tprint("%s\n", strings.join(cmd[:], " ")))
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
		cli.tprint("%d", port),
		"--players",
		cli.tprint("%d", UDP_CLIENTS),
		"--ticks",
		cli.tprint("%d", ticks),
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
			cli.tprint("127.0.0.1:%d", port),
			"--player",
			cli.tprint("%d", i),
			"--ticks",
			cli.tprint("%d", ticks),
		)
		if i == UDP_CLIENTS - 1 {
			append(&args, "--profile", "bad")
		}
		clients[i] = start(binary, work, cli.tprint("client%d", i), timeout, ..args[:])
	}
	errors: [dynamic]string
	finish :: proc(p: ^cli.Proc, name: string, errors: ^[dynamic]string) -> json.Object {
		r := cli.wait(p)
		if r.timed_out {
			append(errors, cli.tprint("%s: timed out (killed)", name))
			return nil
		}
		if r.exit_code != 0 {
			append(
				errors,
				cli.tprint("%s: exit code %d: %s", name, r.exit_code, strings.trim_space(cli.tail(r.stderr, 400))),
			)
			return nil
		}
		obj, ok := cli.last_json_object(r.stdout)
		if !ok {
			append(errors, cli.tprint("%s: no JSON line on stdout", name))
		}
		return obj
	}
	results: [UDP_CLIENTS]json.Object
	for i in 0 ..< UDP_CLIENTS {
		results[i] = finish(&clients[i], cli.tprint("client%d", i), &errors)
	}
	rj := finish(&relay, "relay", &errors)
	if len(errors) > 0 {
		return strings.join(errors[:], "; "), false
	}
	desyncs := cli.json_int(rj["desyncs"])
	for c in results {
		desyncs += max(0, cli.json_int(c["desyncs"]))
	}
	if desyncs > 0 {
		return cli.tprint("%d desync(s)", desyncs), false
	}
	ref: map[int]string
	for c, i in results {
		if cli.json_int(c["final_tick"]) != ticks {
			return cli.tprint("client %d verified up to tick %d of %d", i, cli.json_int(c["final_tick"]), ticks), false
		}
		cs := cli.checksums(c["checksums"])
		if len(cs) != ticks / 16 {
			return cli.tprint("client %d's checksums don't cover every 16th tick", i), false
		}
		if i == 0 {
			ref = cs
			continue
		}
		for t := 16; t <= ticks; t += 16 {
			if cs[t] != ref[t] {
				return cli.tprint("client %d's checksum differs first at tick %d: %s vs %s", i, t, cs[t], ref[t]),
					false
			}
		}
	}
	return cli.tprint(
			"toy relay + %d client processes (one under `bad`) over UDP, %d ticks on the real clock: 0 desyncs, checksums agree",
			UDP_CLIENTS,
			ticks,
		),
		true
}


// --- godot-bindings ---------------------------------------------------------------------------------------------

// The Godot-side library tests: the gdext bindings (tests/godot), godot_host's views and send_command's refusals,
// and its session lifecycle (tests/godot_views), each an extension plus a test script under headless Godot.
// `expected`: error lines the test provokes on purpose (they must show up, and nothing else may).
suite_godot_bindings :: proc(games: []cli.Game, only: []string) -> bool {
	Project :: struct {
		dir, pkg, stem, script, summary: string,
		expected:                        []string,
	}
	root := cli.state.project.root
	views := cli.join(root, "tests", "godot_views")
	projects := []Project {
		{
			cli.join(root, "tests", "godot"),
			cli.join(root, "tests", "godot", "ext"),
			"gdext_test",
			"test.gd",
			"GDEXT TESTS",
			nil,
		},
		{
			views,
			cli.join(views, "ext"),
			"views_test",
			"test.gd",
			"VIEWS TESTS",
			{"unified: send_command: ", "unified: CommandMark.", `has no property "pad_check"`},
		},
		{views, cli.join(views, "ext"), "views_test", "session_check.gd", "SESSION TESTS", nil},
	}
	cli.ensure_bindings()
	// The stale extensions build at once, then the three Godot runs go at once (the session check alone takes most
	// of the time: it waits on purpose for goodbyes and timers); their results are read in order.
	Started :: struct {
		build: cli.Build,
		child: cli.Proc,
	}
	building: [dynamic]Started
	for p, i in projects {
		if i > 0 && p.pkg == projects[i - 1].pkg {
			continue
		}
		flags: [dynamic]string
		append(&flags, "-build-mode:dll")
		append(&flags, ..cli.mode_flags(.dev))
		b := cli.Build {
			pkg   = p.pkg,
			out   = cli.join(p.dir, ".out", "bin", cli.lib_name(p.stem)),
			flags = flags[:],
		}
		if cli.stale(b) {
			append(&building, Started{b, cli.start_build(b)})
		}
	}
	for &started in building {
		if !cli.finish_build(started.build, &started.child).ok {
			cli.fatal("building %s failed", cli.rel(started.build.pkg))
		}
	}
	runs := make([]cli.Run, len(projects))
	for p, i in projects {
		cli.write_extension_list_dir(p.dir)
		// --verbose: Godot reports orphan StringNames and leaked objects at exit only then
		runs[i] = {
			cmd     = cli.strs(
				cli.godot(),
				"--headless",
				"--verbose",
				"--path",
				p.dir,
				"-s",
				cli.tprint("res://%s", p.script),
				"--",
				"--local-net",
			),
			capture = true,
			timeout = 30 * time.Second,
		}
	}
	ok := true
	for r, i in cli.run_all(runs) {
		p := projects[i]
		out := strings.concatenate({r.stdout, r.stderr})
		for line in strings.split_lines(r.stdout) {
			if strings.has_prefix(line, "PASS") ||
			   strings.has_prefix(line, "FAIL") ||
			   strings.has_prefix(line, p.summary) {
				cli.log("%s", line)
			}
		}
		errs: [dynamic]string
		append(&errs, ..cli.godot_errors(out))
		append(&errs, ..cli.lines_with(out, "Orphan StringName", "leaked at exit"))
		if len(p.expected) > 0 {
			provoked := make([]bool, len(p.expected), context.temp_allocator)
			kept: [dynamic]string
			outer: for e in errs {
				for expected, k in p.expected {
					if strings.contains(e, expected) {
						provoked[k] = true
						continue outer
					}
				}
				append(&kept, e)
			}
			errs = kept
			for expected, k in p.expected {
				if !provoked[k] do append(&errs, cli.tprint("no error line with %q: the test expects some", expected))
			}
		}
		for e in errs {
			cli.log("godot: %s", e)
		}
		passed := r.ok && len(errs) == 0 && strings.contains(out, cli.tprint("%s: 0 failed", p.summary))
		cli.log("uni: %s %s: %s (%.1fs)", cli.rel(p.dir), p.script, passed ? "ok" : "FAILED", r.seconds)
		ok = ok && passed
	}
	return ok
}

// --- godot-gen --------------------------------------------------------------------------------------------------

cmd_godot_gen :: proc(args: []string) -> cli.Result {
	Opts :: struct {
		force: bool `usage:"regenerate even when the inputs are unchanged"`,
	}
	opts: Opts
	cli.parse(&opts, args)
	cli.ensure_bindings(opts.force)
	return {ok = true, summary = "the Godot bindings are current (src/gdext/*.gen.odin)"}
}
