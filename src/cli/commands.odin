package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The public commands (README.md, Commands): every project's CLI has them.
public_commands :: proc() -> []Command {
	return slice.clone([]Command {
		{
			name      = "setup",
			summary   = "fetch and build everything this project needs (UNIFIED_BOX3D: build that unified-box3d checkout instead of the release); print each dependency's version and source",
			no_budget = "downloads and builds",
			options   = option_types(Setup_Opts),
			run       = cmd_setup,
		},
		{
			name    = "clean",
			summary = "remove what the CLI built or fetched (.out/, .godot/, generated bindings); --cache: also the per-user cache's downloads",
			budget  = 5,
			options = option_types(Clean_Opts),
			run     = cmd_clean,
		},
		{
			name    = "build",
			summary = "each game's extension and headless binary that is stale, all at once (--force: every one)",
			budget  = 1,
			options = option_types(Build_Opts),
			run     = cmd_build,
		},
		{
			name      = "headless",
			summary   = "the game's headless binary (built when stale), its JSON on stdout; modes: sim, synctest, replay, session, relay, client, bench, and a game's own (`-- help`: every mode and its options)",
			no_budget = "the mode decides",
			options   = option_types(Headless_Opts),
			run       = cmd_headless,
		},
		{
			name      = "run",
			summary   = "the game in a window (arguments after -- go to the game)",
			no_budget = "interactive",
			options   = option_types(Run_Opts),
			run       = cmd_run,
		},
		{
			name      = "editor",
			summary   = "the Godot editor on the game",
			no_budget = "interactive",
			options   = option_types(Editor_Opts),
			run       = cmd_editor,
		},
		{
			name    = "test",
			summary = "the test suites: plain `test` runs the odin suite, `--suite all` every one; --long: the long variants; quiet when it passes",
			budget  = 6,
			options = option_types(Test_Opts),
			details = test_details,
			run     = cmd_test,
		},
		{
			name    = "vet",
			summary = "odin check with the strict flags, every target and define variant",
			budget  = 3,
			options = option_types(Vet_Opts),
			run     = cmd_vet,
		},
		{
			name    = "doc",
			summary = "a package's API: each file's header comment and every public declaration with its doc comment and file:line (no package: list them with their README's title)",
			budget  = 1,
			options = option_types(Doc_Opts),
			run     = cmd_doc,
		},
		{
			name    = "fmt",
			summary = "odinfmt (pinned) over the project's Odin code; --hook: the file a Claude Code edit names",
			budget  = 1,
			options = option_types(Fmt_Opts),
			run     = cmd_fmt,
		},
		{
			name      = "tool",
			summary   = "run a tool script, the game's or unified's (headless; --window: muted, on the leftmost screen, never taking focus); a script error fails the run at once",
			no_budget = "depends on the script",
			options   = option_types(Tool_Opts),
			details   = tool_details,
			run       = cmd_tool,
		},
		{
			name      = "coop",
			summary   = "host and joiner processes in a real lobby (EOS, or --lan); EOS: one test at a time (docs/EOS.md)",
			no_budget = "networked",
			options   = option_types(Coop_Opts),
			run       = cmd_coop,
		},
		{
			name    = "bake",
			summary = "write the view index and bake .level files from their scenes (--check: fail if one is stale)",
			budget  = 2,
			options = option_types(Bake_Opts),
			run     = cmd_bake,
		},
		{
			name    = "bench",
			summary = "each game's standard benchmark and its sessions on the virtual clock (bad; wan with a late joiner), alone, on a release build; the project's own rows",
			budget  = 10,
			options = option_types(Bench_Opts),
			details = bench_details,
			run     = cmd_bench,
		},
		{
			name      = "init",
			summary   = "a new game repo: the template game, shims, tools/main.odin, .gitignore, .gitattributes, the unified submodule (pinned to main's commit, or --ref); --in-repo: the template game inside this checkout (its tests join the test compile by themselves)",
			no_budget = "clones unified",
			options   = option_types(Init_Opts),
			run       = cmd_init,
		},
		{
			name    = "verify",
			summary = "the gate before handing work back or merging: fmt --check, vet, test --suite all",
			budget  = 25,
			options = option_types(Verify_Opts),
			run     = cmd_verify,
		},
		{
			name    = "version",
			summary = "the CLI's source hash, Odin, and the pins",
			budget  = 1,
			options = option_types(Version_Opts),
			run     = cmd_version,
		},
	})
}

// The test suites every project has (`odin`, `box3d-debug`, `godot`); `run` puts them before the project's own
// (`add_suites`).
public_suites :: proc() -> []Suite {
	return slice.clone(
		[]Suite {
			{
				name        = "odin",
				summary     = "every Odin test package (the inner loop; a project's unoptimised test root compiles beside the optimised one); with a game named, that game's tests",
				budget      = 6,
				long_budget = 12,
				run         = suite_odin,
			},
			{
				name    = "box3d-debug",
				summary = "the odin suite's binaries again, against Box3D's debug library (its asserts trap a misused id)",
				// its physics is unoptimised: several times the odin suite's run (CI's watchdog: 3x the budget)
				budget  = 12,
				run     = suite_box3d_debug,
			},
			{
				name        = "godot",
				summary     = "each game under headless Godot, the games in parallel",
				budget      = 25,
				long_budget = 30,
				run         = suite_godot,
				beside      = true,
				prepare     = godot_prepare,
			},
		},
	)
}

// --- test -------------------------------------------------------------------------------------------------------

// `test`'s options (the command table names them: -h lists them).
@(private)
Test_Opts :: struct {
	game:  string `args:"pos=0" usage:"a game (default: every game); the odin suite then compiles that game's tests only"`,
	suite: string `hint:"s,..." usage:"suites, comma-separated, or all (default: odin); listed below"`,
	only:  string `hint:"name,..." usage:"tests (odin) or steps (godot), comma-separated"`,
	long:  bool `usage:"the long variants: every standard scenario at full length (odin), 960 ticks (net), a 256-tick session (godot)"`,
}

@(private)
cmd_test :: proc(args: []string) -> Result {
	opts: Test_Opts
	parse(&opts, args)
	names := split_list(opts.suite)
	if len(names) == 0 {
		names = {"odin"}
	}
	if len(names) == 1 && names[0] == "all" {
		names = suite_names()
	}
	test_opts := Test_Options {
		only = split_list(opts.only),
		long = opts.long,
		game = opts.game,
	}
	// The run's budget: its suites' (each by suite_budget, --long included).
	budget: f64
	suites: [dynamic]^Suite
	for name in names {
		found := false
		for &suite in state.suites {
			if suite.name == name {
				append(&suites, &suite)
				budget += suite_budget(&suite, test_opts)
				found = true
			}
		}
		if !found {
			usage("no suite %q (have: %s, all)", name, strings.join(suite_names(), ", "))
		}
	}
	games := games_or_all(opts.game)
	Suite_Result :: struct {
		suite:   string,
		ok:      bool,
		seconds: f64,
	}
	results := make([]Suite_Result, len(suites))
	ok := true
	// With other suites, the `beside` ones run in child processes while the rest run here, in order. Each child starts
	// once its `prepare` has made current what it shares with the others.
	children := make([]Maybe(Proc), len(suites))
	in_process := 0
	for suite in suites {
		in_process += suite.beside ? 0 : 1
	}
	if in_process > 0 && in_process < len(suites) {
		exe := self_exe()
		for suite, i in suites {
			if !suite.beside do continue
			if suite.prepare != nil {
				suite.prepare()
			}
			cmd: [dynamic]string
			append(&cmd, exe, "test")
			if opts.game != "" {
				append(&cmd, opts.game)
			}
			append(&cmd, "--suite", suite.name, "--json")
			if opts.only != "" {
				append(&cmd, "--only", opts.only)
			}
			if opts.long {
				append(&cmd, "--long")
			}
			if state.verbose do log("uni: test --suite %s: beside the others", suite.name)
			children[i] = start({
				cmd     = cmd[:],
				dir     = state.project.root,
				capture = true,
				quiet   = true,
				env     = beside_env(),
			})
		}
	}
	// A suite is held to its own budget only when it had the machine to itself: run here with nothing beside it. One
	// measured beside others says how busy the machine was; this run is held to the sum of their budgets instead.
	alone := !state.beside && !(in_process > 0 && in_process < len(suites))
	for suite, i in suites {
		if children[i] != nil do continue
		start := time.tick_now()
		cold_before := len(state.cold)
		if state.verbose do log("uni: test --suite %s", suite.name)
		passed := suite.run(games, test_opts)
		results[i] = {suite.name, passed, round2(seconds_since(start))}
		ok = ok && passed
		allowed := suite_budget(suite, test_opts) * (in_ci() ? CI_BUDGET_SCALE : 1)
		if len(suites) > 1 && alone && len(state.cold) == cold_before && results[i].seconds > allowed {
			log(
				"uni: OVER BUDGET: the %s suite took %.1fs, budget %.0fs: find out why (AGENTS.md, Non-negotiables)",
				suite.name,
				results[i].seconds,
				allowed,
			)
		}
	}
	// A child reports its time (beside the others: not held to its budget); its log is printed when it ends
	// (child_log).
	for &child, i in children {
		running, is_child := child.?
		if !is_child do continue
		ran := wait(&running)
		child_log(ran.stderr, ran.ok)
		results[i] = {suites[i].name, ran.ok, round2(ran.seconds)}
		if report, found := last_json_object(ran.stdout); found {
			if seconds, is_number := report["seconds"].(json.Float); is_number {
				results[i].seconds = round2(f64(seconds))
			}
			adopt_cold(report)
		}
		ok = ok && ran.ok
	}
	builder := strings.builder_make()
	for result, i in results {
		if i > 0 {
			strings.write_string(&builder, ", ")
		}
		strings.write_string(
			&builder,
			aprintf("%s %s (%.1fs)", result.suite, result.ok ? "passed" : "FAILED", result.seconds),
		)
	}
	return {
		ok      = ok,
		summary = aprintf("test: %s", strings.to_string(builder)),
		data    = box(results[:]),
		budget  = budget,
	}
}

// What a child `uni` built or fetched first (its --json report's `cold`) makes this run cold too.
adopt_cold :: proc(report: json.Object) {
	if list, is_list := report["cold"].(json.Array); is_list {
		for item in list {
			if what, is_str := item.(json.String); is_str {
				cold(string(what))
			}
		}
	}
}

// The registered suites' names, in order.
suite_names :: proc() -> []string {
	names := make([]string, len(state.suites))
	for suite, i in state.suites {
		names[i] = suite.name
	}
	return names
}

// Prints a child `uni`'s log (its stderr): whole when it failed or with --verbose; else only its warnings (lines with
// OVER BUDGET or WARN), so a passing run stays a few lines (README.md, Test suites).
child_log :: proc(stderr: string, ok: bool) {
	text := strings.trim_right_space(stderr)
	if text == "" {
		return
	}
	if !ok || state.verbose {
		log("%s", text)
		return
	}
	for line in strings.split_lines(text, context.temp_allocator) {
		if strings.contains(line, "OVER BUDGET") || strings.contains(line, "WARN") {
			log("%s", line)
		}
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

// `test -h`'s details: the suites with their budgets, the godot suite's steps, and what a run prints.
@(private)
test_details :: proc() -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "suites (--suite; all: every one; plain `test`: odin):\n")
	width := 0
	for suite in state.suites {
		width = max(width, len(suite.name))
	}
	for suite in state.suites {
		budget := aprintf("%.0fs", suite.budget)
		if suite.long_budget > 0 {
			budget = aprintf("%s, --long %.0fs", budget, suite.long_budget)
		}
		fmt.sbprintf(&builder, "  %-*s  %s (budget %s)\n", width, suite.name, suite.summary, budget)
		if suite.name == "godot" {
			fmt.sbprintf(
				&builder,
				"  %-*s  steps, in order (--only; a failing one skips those after it): %s\n",
				width,
				"",
				strings.join(GODOT_STEPS, ", "),
			)
		}
	}
	strings.write_string(
		&builder,
		"With other suites, the ones that mostly wait (godot, and the project's own that say so) run beside them in\n" +
		"child processes. A run's budget is its suites' sum; a suite is held to its own only when it ran alone (beside\n" +
		"others, its time says how busy the machine was). A passing run prints a summary: each suite's result and\n" +
		"the warnings it logged (a leak, OVER BUDGET); a failing one prints the whole log of what failed, and\n" +
		"--verbose everything.",
	)
	return strings.to_string(builder)
}

// --- verify -----------------------------------------------------------------------------------------------------

// `verify --long`'s budget (plain `verify`: the command's).
VERIFY_LONG_BUDGET :: 45

// `verify`'s options.
@(private)
Verify_Opts :: struct {
	long: bool `usage:"test --long: the suites' long variants"`,
}

// The gate: every step runs in this process, in order; the first failure stops it. Each step reports its own budget
// in its Result (verify ignores it); verify's is the command's, or VERIFY_LONG_BUDGET with --long. The benchmarks
// are not in it: they gate nothing (a re-sim mismatch fails every game's sync-test first); `uni bench` runs them,
// and CI on every platform.
@(private)
cmd_verify :: proc(args: []string) -> Result {
	opts: Verify_Opts
	parse(&opts, args)
	Step :: struct {
		name: string,
		args: []string,
	}
	test := opts.long ? []string{"--suite", "all", "--long"} : []string{"--suite", "all"}
	steps := []Step{{"fmt", {"--check"}}, {"vet", {}}, {"test", test}}
	budget: f64 = opts.long ? VERIFY_LONG_BUDGET : 0
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
			return {ok = false, summary = aprintf("verify: %s failed: %s", step.name, result.summary), budget = budget}
		}
	}
	return {ok = true, summary = "verify: fmt, vet and every test suite passed", budget = budget}
}

// --- version ----------------------------------------------------------------------------------------------------

@(private)
Version_Opts :: struct {}

@(private)
cmd_version :: proc(args: []string) -> Result {
	opts: Version_Opts
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
		odin     = aprintf("%s:%s", ODIN_VERSION, ODIN_VERSION_HASH),
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
