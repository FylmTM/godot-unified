package cli

import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The public commands (SPEC.md, Commands): every project's CLI has them.
public_commands :: proc() -> []Command {
	return slice.clone(
		[]Command {
			{
				name = "setup",
				usage = "[--check]",
				summary = "fetch and build everything this project needs; print each dependency's version and source",
				no_budget = "downloads and builds",
				run = cmd_setup,
			},
			{
				name = "build",
				usage = "[game] [--mode dev|release|debug]",
				summary = "each game's extension and headless binary, in parallel",
				budget = 8,
				run = cmd_build,
			},
			{
				name = "run",
				usage = "[game] [-- args]",
				summary = "the game in a window (arguments after -- go to the game)",
				no_budget = "interactive",
				run = cmd_run,
			},
			{
				name = "editor",
				usage = "[game]",
				summary = "the Godot editor on the game",
				no_budget = "interactive",
				run = cmd_editor,
			},
			{
				name = "test",
				usage = "[game] [--suite s,...] [--only name,...]",
				summary = "the test suites: plain `test` runs the odin suite, `--suite all` every one",
				budget = 6,
				run = cmd_test,
			},
			{
				name = "vet",
				summary = "odin check with the strict flags, every target and define variant",
				budget = 3,
				run = cmd_vet,
			},
			{
				name = "fmt",
				usage = "[--check] [path...] | --hook",
				summary = "odinfmt (pinned) over the project's Odin code; --hook: the file a Claude Code edit names",
				budget = 1,
				run = cmd_fmt,
			},
			{
				name = "tool",
				usage = "[game] <script> [--window] [--shots] [-- args]",
				summary = "run game/tools/<script>.gd (headless unless --window)",
				no_budget = "depends on the script",
				run = cmd_tool,
			},
			{
				name = "coop",
				usage = "[game] [--window] [--rejoin] [--lan]",
				summary = "host and joiner processes in a real lobby (EOS, or --lan)",
				no_budget = "networked",
				run = cmd_coop,
			},
			{
				name = "bake",
				usage = "[game] [--check]",
				summary = "bake .level files from their scenes (--check: fail if one is stale)",
				budget = 2,
				run = cmd_bake,
			},
			{
				name = "bench",
				usage = "[game...]",
				summary = "each game's standard benchmark, alone, on a release build",
				budget = 10,
				run = cmd_bench,
			},
			{
				name = "record-reference",
				usage = "<game>",
				summary = "record a game's reference run anew (the committed log, trace and snapshot test replays)",
				budget = 8,
				run = cmd_record_reference,
			},
			{
				name = "init",
				usage = "<dir>",
				summary = "a new game repo: layout, shims, tools/main.odin, .gitignore, the unified submodule",
				no_budget = "clones unified",
				run = cmd_init,
			},
			{
				name = "verify",
				summary = "the gate before handing work back or merging: fmt --check, vet, test --suite all, bench",
				budget = 100,
				run = cmd_verify,
			},
			{name = "version", summary = "the CLI's source hash, Odin, and the pins", budget = 1, run = cmd_version},
		},
	)
}

public_suites :: proc() -> []Suite {
	return slice.clone(
		[]Suite {
			{
				name = "odin",
				summary = "every Odin test package in one compile (the inner loop)",
				budget = 6,
				run = suite_odin,
			},
			{name = "godot", summary = "each game under headless Godot", budget = 60, run = suite_godot},
		},
	)
}

// --- test -------------------------------------------------------------------------------------------------------

@(private)
cmd_test :: proc(args: []string) -> Result {
	Opts :: struct {
		game:  string `args:"pos=0" usage:"a game (default: every game)"`,
		suite: string `usage:"suites, comma-separated, or all (default: odin)"`,
		only:  string `usage:"tests (odin) or steps (godot), comma-separated"`,
	}
	opts: Opts
	parse(&opts, args)
	names := split_list(opts.suite)
	if len(names) == 0 {
		names = {"odin"}
	}
	if len(names) == 1 && names[0] == "all" {
		names = make([]string, len(state.suites))
		for s, i in state.suites {
			names[i] = s.name
		}
	}
	suites: [dynamic]^Suite
	for n in names {
		found := false
		for &s in state.suites {
			if s.name == n {
				append(&suites, &s)
				state.budget += s.budget
				found = true
			}
		}
		if !found {
			have := make([]string, len(state.suites))
			for s, i in state.suites {
				have[i] = s.name
			}
			usage("no suite %q (have: %s, all)", n, strings.join(have, ", "))
		}
	}
	games := games_or_all(opts.game)
	only := split_list(opts.only)
	Suite_Result :: struct {
		suite:   string,
		ok:      bool,
		seconds: f64,
	}
	results: [dynamic]Suite_Result
	ok := true
	for s in suites {
		start := time.tick_now()
		log("unified: test --suite %s", s.name)
		passed := s.run(games, only)
		append(&results, Suite_Result{s.name, passed, round2(seconds_since(start))})
		ok = ok && passed
	}
	b := strings.builder_make()
	for r, i in results {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, tprint("%s %s (%.1fs)", r.suite, r.ok ? "passed" : "FAILED", r.seconds))
	}
	return {ok = ok, summary = tprint("test: %s", strings.to_string(b)), data = box(results[:])}
}

split_list :: proc(s: string) -> []string {
	out: [dynamic]string
	for part in strings.split(s, ",") {
		if p := strings.trim_space(part); p != "" {
			append(&out, p)
		}
	}
	return out[:]
}

// --- verify -----------------------------------------------------------------------------------------------------

// The gate: every step runs in this process, in order; the first failure stops it.
@(private)
cmd_verify :: proc(args: []string) -> Result {
	Opts :: struct {}
	opts: Opts
	parse(&opts, args)
	Step :: struct {
		name: string,
		args: []string,
	}
	steps := []Step{{"fmt", {"--check"}}, {"vet", {}}, {"test", {"--suite", "all"}}, {"bench", {}}}
	self := state.command
	for st in steps {
		c := find_command(st.name)
		state.command = c
		start := time.tick_now()
		r := c.run(st.args)
		state.command = self
		log(
			"unified: verify: %s %s: %s (%.1fs)",
			st.name,
			strings.join(st.args, " "),
			r.ok ? "ok" : "FAILED",
			seconds_since(start),
		)
		if r.ok && r.summary != "" {
			log("  %s", r.summary)
		}
		if !r.ok {
			return {ok = false, summary = tprint("verify: %s failed: %s", st.name, r.summary)}
		}
	}
	state.budget = 0
	return {ok = true, summary = "verify: fmt, vet, every test suite and the benchmarks passed"}
}

// --- version ----------------------------------------------------------------------------------------------------

@(private)
cmd_version :: proc(args: []string) -> Result {
	Opts :: struct {}
	opts: Opts
	parse(&opts, args)
	exe, _ := os.get_executable_path(context.temp_allocator)
	Version :: struct {
		cli:      string,
		odin:     string,
		platform: string,
		project:  string,
		unified:  string,
		env:      []string,
		pins:     map[string]map[string]string,
	}
	v := new(Version)
	v^ = {
		cli      = os.base(exe),
		odin     = tprint("%s:%s", ODIN_VERSION, ODIN_VERSION_HASH),
		platform = PLATFORM,
		project  = state.project.root,
		unified  = state.project.unified,
		env      = state.env_keys,
		pins     = state.pins.sections,
	}
	return {ok = true, summary = strings.join({v.cli, v.odin, v.platform}, " "), data = box(v^)}
}
