package cli

import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The public commands (SPEC.md, Commands): every project's CLI has them.
public_commands :: proc() -> []Command {
	return slice.clone([]Command {
		{
			name      = "setup",
			usage     = "[--check]",
			summary   = "fetch and build everything this project needs (UNIFIED_BOX3D: build that unified-box3d checkout instead of the release); print each dependency's version and source",
			no_budget = "downloads and builds",
			run       = cmd_setup,
		},
		{
			name    = "clean",
			usage   = "[--check] [--cache]",
			summary = "remove what the CLI built or fetched (.out/, .godot/, generated bindings); --cache: also the per-user cache's downloads",
			budget  = 5,
			run     = cmd_clean,
		},
		{
			name    = "build",
			usage   = "[game] [--mode dev|release|debug]",
			summary = "each game's extension and headless binary, in parallel",
			budget  = 8,
			run     = cmd_build,
		},
		{
			name      = "headless",
			usage     = "[game] [--mode dev|release|debug] -- <mode> [options]",
			summary   = "the game's headless binary (built when stale): sim, synctest, replay, session, relay, client, snapshot, resume, bench, net-bench; its JSON on stdout",
			no_budget = "the mode decides",
			run       = cmd_headless,
		},
		{
			name      = "run",
			usage     = "[game] [--mute] [--screen s] [--background] [-- args]",
			summary   = "the game in a window (arguments after -- go to the game)",
			no_budget = "interactive",
			run       = cmd_run,
		},
		{
			name      = "editor",
			usage     = "[game] [--mute] [--screen s]",
			summary   = "the Godot editor on the game",
			no_budget = "interactive",
			run       = cmd_editor,
		},
		{
			name    = "test",
			usage   = "[game] [--suite s,...] [--only name,...] [--long] [--crash] [--box3d-debug]",
			summary = "the test suites: plain `test` runs the odin suite, `--suite all` every one; --long: the long variants",
			budget  = 6,
			run     = cmd_test,
		},
		{
			name    = "vet",
			summary = "odin check with the strict flags, every target and define variant",
			budget  = 3,
			run     = cmd_vet,
		},
		{
			name    = "fmt",
			usage   = "[--check] [path...] | --hook",
			summary = "odinfmt (pinned) over the project's Odin code, and LF line endings in every text file; --hook: the file a Claude Code edit names",
			budget  = 1,
			run     = cmd_fmt,
		},
		{
			name      = "tool",
			usage     = "[game] <script> [--window [--mute] [--screen s]] [--shots] [-- args]",
			summary   = "run a tool script, the game's or games/shared's (headless unless --window)",
			no_budget = "depends on the script",
			run       = cmd_tool,
		},
		{
			name      = "coop",
			usage     = "[game] [--window [--mute] [--screen s]] [--rejoin | --crash] [--lan]",
			summary   = "host and joiner processes in a real lobby (EOS, or --lan)",
			no_budget = "networked",
			run       = cmd_coop,
		},
		{
			name    = "bake",
			usage   = "[game] [--check]",
			summary = "bake .level files from their scenes (--check: fail if one is stale)",
			budget  = 2,
			run     = cmd_bake,
		},
		{
			name    = "bench",
			usage   = "[game...]",
			summary = "each game's standard benchmark, alone, on a release build, and the sim's sparse-table walk",
			budget  = 10,
			run     = cmd_bench,
		},
		{
			name    = "record-reference",
			usage   = "<game>",
			summary = "record a game's reference run anew (the committed log, trace and snapshot test replays)",
			budget  = 8,
			run     = cmd_record_reference,
		},
		{
			name      = "init",
			usage     = "<dir> [--unified <url>] [--ref <ref>]",
			summary   = "a new game repo: the template game, shims, tools/main.odin, .gitignore, .gitattributes, the unified submodule (pinned to main's commit, or --ref)",
			no_budget = "clones unified",
			run       = cmd_init,
		},
		{
			name    = "verify",
			usage   = "[--long]",
			summary = "the gate before handing work back or merging: fmt --check, vet, test --suite all, test --box3d-debug, bench",
			budget  = 45,
			run     = cmd_verify,
		},
		{
			name    = "version",
			summary = "the CLI's source hash, Odin, and the pins",
			budget  = 1,
			run     = cmd_version,
		},
	})
}

// The test suites every project has (`odin`, `godot`); `run` puts them before the project's own (`add_suites`).
public_suites :: proc() -> []Suite {
	return slice.clone([]Suite {
		{
			name        = "odin",
			summary     = "every Odin test package in one compile (the inner loop)",
			budget      = 6,
			long_budget = 12,
			run         = suite_odin,
		},
		{
			name        = "godot",
			summary     = "each game under headless Godot, the games in parallel",
			budget      = 20,
			long_budget = 25,
			run         = suite_godot,
		},
	})
}

// --- test -------------------------------------------------------------------------------------------------------

// What `test --box3d-debug` adds to the odin suite's budget: the debug library's physics is unoptimised, so the run
// takes 3-4 times as long (3.4x here on 28 threads, 4x on CI's 4-core linux-x64: 17 s against 4 s); the compile is the
// same, into a folder of its own.
BOX3D_DEBUG_EXTRA_BUDGET :: 6

@(private)
cmd_test :: proc(args: []string) -> Result {
	Opts :: struct {
		game:        string `args:"pos=0" usage:"a game (default: every game)"`,
		suite:       string `usage:"suites, comma-separated, or all (default: odin)"`,
		only:        string `usage:"tests (odin) or steps (godot), comma-separated"`,
		long:        bool `usage:"the long variants: every standard scenario at full length (odin), 960 ticks (net), a 256-tick session (godot)"`,
		crash:       bool `usage:"odin, this repo: a test also crashes holding a lock another test waits for; proves the run fails within seconds and names it"`,
		box3d_debug: bool `args:"name=box3d-debug" usage:"odin: link Box3D's debug library (its id and state asserts trap a misuse the release library lets through)"`,
	}
	opts: Opts
	parse(&opts, args)
	state.long = opts.long
	state.crash = opts.crash
	state.box3d_debug = opts.box3d_debug
	if opts.crash && !is_unified_repo() {
		usage("--crash runs tests/cli's crash test: the unified repo only")
	}
	if opts.box3d_debug && opts.suite != "" && opts.suite != "odin" {
		usage("--box3d-debug is for the odin suite")
	}
	if opts.box3d_debug {
		state.budget += BOX3D_DEBUG_EXTRA_BUDGET
	}
	names := split_list(opts.suite)
	if len(names) == 0 {
		names = {"odin"}
	}
	if len(names) == 1 && names[0] == "all" {
		names = make([]string, len(state.suites))
		for suite, i in state.suites {
			names[i] = suite.name
		}
	}
	suites: [dynamic]^Suite
	for name in names {
		found := false
		for &suite in state.suites {
			if suite.name == name {
				append(&suites, &suite)
				state.budget += opts.long && suite.long_budget > 0 ? suite.long_budget : suite.budget
				found = true
			}
		}
		if !found {
			have := make([]string, len(state.suites))
			for suite, i in state.suites {
				have[i] = suite.name
			}
			usage("no suite %q (have: %s, all)", name, strings.join(have, ", "))
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
	for suite in suites {
		start := time.tick_now()
		log("uni: test --suite %s", suite.name)
		passed := suite.run(games, only)
		append(&results, Suite_Result{suite.name, passed, round2(seconds_since(start))})
		ok = ok && passed
	}
	builder := strings.builder_make()
	for result, i in results {
		if i > 0 {
			strings.write_string(&builder, ", ")
		}
		strings.write_string(
			&builder,
			tprint("%s %s (%.1fs)", result.suite, result.ok ? "passed" : "FAILED", result.seconds),
		)
	}
	return {
		ok      = ok,
		summary = tprint("test: %s", strings.to_string(builder)),
		data    = box(results[:]),
	}
}

// A comma-separated option (`test --suite`, `--only`) as its trimmed, non-empty items.
split_list :: proc(text: string) -> []string {
	out: [dynamic]string
	for part in strings.split(text, ",") {
		if trimmed := strings.trim_space(part); trimmed != "" {
			append(&out, trimmed)
		}
	}
	return out[:]
}

// --- verify -----------------------------------------------------------------------------------------------------

// `verify --long`'s budget (plain `verify`: the command's).
VERIFY_LONG_BUDGET :: 65

// The gate: every step runs in this process, in order; the first failure stops it.
@(private)
cmd_verify :: proc(args: []string) -> Result {
	Opts :: struct {
		long: bool `usage:"test --long: the suites' long variants"`,
	}
	opts: Opts
	parse(&opts, args)
	Step :: struct {
		name: string,
		args: []string,
	}
	test := opts.long ? []string{"--suite", "all", "--long"} : []string{"--suite", "all"}
	// The odin suite again against Box3D's debug library, where a misused id traps.
	steps := []Step{{"fmt", {"--check"}}, {"vet", {}}, {"test", test}, {"test", {"--box3d-debug"}}, {"bench", {}}}
	self := state.command
	for step in steps {
		command := find_command(step.name)
		state.command = command
		start := time.tick_now()
		result := command.run(step.args)
		state.command = self
		log(
			"uni: verify: %s %s: %s (%.1fs)",
			step.name,
			strings.join(step.args, " "),
			result.ok ? "ok" : "FAILED",
			seconds_since(start),
		)
		if result.ok && result.summary != "" {
			log("  %s", result.summary)
		}
		if !result.ok {
			return {ok = false, summary = tprint("verify: %s failed: %s", step.name, result.summary)}
		}
	}
	state.budget = opts.long ? VERIFY_LONG_BUDGET : 0
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
	version := new(Version)
	version^ = {
		cli      = os.base(exe),
		odin     = tprint("%s:%s", ODIN_VERSION, ODIN_VERSION_HASH),
		platform = PLATFORM,
		project  = state.project.root,
		unified  = state.project.unified,
		env      = state.env_keys,
		pins     = state.pins.sections,
	}
	return {
		ok      = true,
		summary = strings.join({version.cli, version.odin, version.platform}, " "),
		data    = box(version^),
	}
}
