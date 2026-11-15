// The unified CLI as a library (SPEC.md). A project's tools/ package (package main) calls `run` with the public
// commands plus its own:
//
//	main :: proc() {cli.run(cli.public_commands(), my_commands)}
//
// It imports only core:, so editing the rest of the library never rebuilds the CLI.
package cli

import "core:encoding/json"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// A command: `run` parses its own arguments with `parse` and returns its result. `budget` is the seconds a warm run
// may take (0: none, and `no_budget` says why).
Command :: struct {
	name:      string,
	usage:     string, // the arguments, for `help`: "[game] [--mode dev|release|debug]"
	summary:   string,
	budget:    f64,
	no_budget: string,
	run:       proc(args: []string) -> Result,
}

// A test suite of `test` (SPEC.md, Test suites): `run` reports whether it passed. A project's tools/ adds its own
// with `add_suites` before `run`.
Suite :: struct {
	name:        string,
	summary:     string,
	budget:      f64,
	long_budget: f64, // with `test --long` (0: `budget`)
	run:         proc(games: []Game, only: []string) -> bool,
	// Mostly waits (the real clock, timers): run with other suites, it runs beside them in a child process.
	beside:      bool,
	// With `beside`: makes current, before the others start, what it builds that they share (nil: nothing).
	prepare:     proc(),
}

// What a command reports: one line on stdout, or with --json one object with `data` (marshalled after the command
// returns, so it must not point at the command's stack).
Result :: struct {
	ok:      bool,
	summary: string,
	data:    any,
}

// CI allows this many times a command's budget (shared runners are slower and noisier).
CI_BUDGET_SCALE :: 3

State :: struct {
	project:     Project,
	pins:        Config,
	commands:    [dynamic]Command,
	command:     ^Command,
	argv:        []string, // the command line after the program name, --json and --verbose removed
	json:        bool,
	verbose:     bool, // --verbose (or VERBOSE_ENV, so a uni the CLI starts is verbose too): echo every command line
	start:       time.Tick,
	cold:        [dynamic]string, // what this run built or fetched first: such a run isn't held to its budget
	env_keys:    []string, // the variables .env set
	suites:      [dynamic]Suite,
	budget:      f64, // set by a command whose budget depends on its arguments (test: its suites)
	long:        bool, // `test --long`: the suites' long variants (SPEC.md, Test suites)
	crash:       bool, // `test --crash`: the tests that crash on purpose run (src/cli/testrun.odin)
	box3d_debug: bool, // `test --box3d-debug`: the odin suite links Box3D's debug library (its asserts on)
}

// Set in the environment of a `uni` the CLI starts itself (the godot suite's one per game): that run leaves
// .out/timings.json to its parent.
CHILD_ENV :: "UNIFIED_CLI_CHILD"

// Set by --verbose for the processes the CLI starts (another uni reads it).
VERBOSE_ENV :: "UNIFIED_VERBOSE"

// Adds a project's own test suites (call before `run`).
add_suites :: proc(suites: ..Suite) {
	append(&state.suites, ..suites)
}

state: State

// The entry point: finds the project, loads the pins, keeps the binary current (it may rebuild and re-run itself),
// loads .env, then runs the command named on the command line.
run :: proc(command_sets: ..[]Command) -> ! {
	args := os.args[1:]
	state.project = find_project()
	pins, ok := config_load(join(state.project.unified, "pins.cfg"))
	if !ok {
		fatal("cannot read %s", join(state.project.unified, "pins.cfg"))
	}
	state.pins = pins
	self_check(args)
	check_odin_version()
	state.env_keys = env_load(state.project.root)
	inject_at(&state.suites, 0, ..public_suites())
	for set in command_sets {
		for command in set {
			if find_command(command.name) != nil {
				fatal("command %s is defined twice", command.name)
			}
			append(&state.commands, command)
		}
	}
	argv := make([dynamic]string)
	for arg in args {
		if arg == "--json" {
			state.json = true
		} else if arg == "--verbose" {
			state.verbose = true
		} else {
			append(&argv, arg)
		}
	}
	state.argv = argv[:]
	if state.verbose {
		_ = os.set_env(VERBOSE_ENV, "1")
	} else {
		state.verbose = os.get_env(VERBOSE_ENV, context.temp_allocator) != ""
	}
	if len(argv) == 0 || argv[0] == "help" || argv[0] == "-h" || argv[0] == "--help" {
		print_help()
		os.exit(len(argv) == 0 ? 2 : 0)
	}
	cmd := find_command(argv[0])
	if cmd == nil {
		log("uni: unknown command %q (uni help lists them)", argv[0])
		os.exit(2)
	}
	state.command = cmd
	state.start = time.tick_now()
	result := cmd.run(argv[1:])
	finish(result)
}

// The registered command of that name, or nil: `run` dispatches the command line with it and refuses a name
// defined twice; `verify` finds its steps with it.
find_command :: proc(name: string) -> ^Command {
	for &command in state.commands {
		if command.name == name {
			return &command
		}
	}
	return nil
}

// Prints `uni help`: every command with its usage and summary, then how budgets, the pinned Odin and the per-user
// cache work. Shown for `help`, -h, --help and a bare `uni`.
print_help :: proc() {
	fmt.println("uni: build, test, check and run the games of this project (src/cli/SPEC.md)\n")
	fmt.println("usage: uni <command> [options] [--json] [--verbose]   (uni <command> -h: its options and budget)\n")
	width := 0
	for command in state.commands {
		width = max(width, len(command.name) + 1 + len(command.usage))
	}
	for command in state.commands {
		line := strings.concatenate({command.name, " ", command.usage}, context.temp_allocator)
		fmt.printf("  %-*s  %s\n", width, line, command.summary)
	}
	fmt.printf(
		"\nBudgets: seconds for a warm run (CI allows %dx); over budget is reported, not failed. A cold run (it built or fetched something first) is exempt.\n",
		CI_BUDGET_SCALE,
	)
	fmt.printf(
		"Odin: the release pins.cfg pins. The shims (./uni, uni.cmd) use the odin on PATH when it reports the pinned commit, else download that release once into the per-user cache and put it first on PATH.\nThe per-user cache (%s), shared by every checkout: the shims' Odin, the pinned Godot, the unified-box3d zip; `clean --cache` clears what the CLI put there.\n",
		USER_CACHE,
	)
}

// The per-user cache (cache.odin, user_cache), as `help` names it.
@(private)
USER_CACHE :: "%LOCALAPPDATA%\\unified" when ODIN_OS == .Windows else "${XDG_CACHE_HOME:-~/.cache}/unified"

// A command's budget line for its -h: the seconds a warm run may take and the CI allowance, or why it has none.
budget_text :: proc(command: ^Command) -> string {
	if command.budget > 0 {
		return tprint("budget: %.0fs for a warm run (%dx in CI)", command.budget, CI_BUDGET_SCALE)
	}
	return tprint("budget: none (%s)", command.no_budget)
}

// Parses a command's arguments into `opts` (core:flags, Unix style: --name value, --name=value, positionals, and
// everything after -- into an `overflow` field). -h prints the usage and exits; a bad argument exits 2.
parse :: proc(opts: ^$Options, args: []string) {
	if slice.contains(args, "-h") || slice.contains(args, "--help") {
		command := state.command
		fmt.printf("usage: uni %s %s\n%s\n%s\n\n", command.name, command.usage, command.summary, budget_text(command))
		flags.write_usage(os.to_stream(os.stdout), Options, tprint("uni %s", command.name), .Unix)
		os.exit(0)
	}
	if err := flags.parse(opts, args, .Unix); err != nil {
		usage_error(err)
	}
}

@(private)
usage_error :: proc(err: flags.Error) -> ! {
	msg := ""
	switch problem in err {
	case flags.Parse_Error:
		msg = problem.message
	case flags.Validation_Error:
		msg = problem.message
	case flags.Open_File_Error:
		msg = tprint("cannot open %s", problem.filename)
	case flags.Help_Request:
		msg = "-h prints the usage"
	}
	log("uni %s: %s (uni %s -h)", state.command.name, msg, state.command.name)
	os.exit(2)
}

// Stops with a usage error (exit 2).
usage :: proc(format: string, args: ..any) -> ! {
	log("uni %s: %s (uni %s -h)", state.command.name, tprint(format, ..args), state.command.name)
	os.exit(2)
}

// Ends the run: the result on stdout, the time against the budget on stderr and in .out/timings.json, the exit code.
@(private)
finish :: proc(result: Result) -> ! {
	secs := time.duration_seconds(time.tick_since(state.start))
	report_timing(secs, result.ok)
	if state.json {
		Out :: struct {
			command: string,
			ok:      bool,
			summary: string,
			seconds: f64,
			cold:    []string,
		}
		head, err := json.marshal(Out{state.command.name, result.ok, result.summary, round2(secs), state.cold[:]})
		data := transmute([]byte)string("null")
		if err == nil && result.data != nil {
			data, err = json.marshal(result.data)
		}
		if err != nil {
			log("uni: cannot encode the result as JSON: %v", err)
			os.exit(1)
		}
		// {"command":...,"cold":[...],"data":<the command's data>}
		fmt.printf("%s,\"data\":%s}\n", string(head[:len(head) - 1]), string(data))
	} else if result.summary != "" {
		fmt.println(result.summary)
	}
	os.exit(result.ok ? 0 : 1)
}

// Stops the command as failed: the message on stderr (and in the --json result).
fatal :: proc(format: string, args: ..any) -> ! {
	msg := tprint(format, ..args)
	if state.command == nil {
		log("uni: %s", msg)
		os.exit(1)
	}
	log("uni %s: %s", state.command.name, msg)
	finish({ok = false, summary = msg})
}

// Marks the run cold: it built or fetched `what` first, so it isn't held to its budget.
cold :: proc(what: string) {
	append(&state.cold, strings.clone(what))
}

// Whether this runs in CI (CI=true): budgets are scaled by CI_BUDGET_SCALE there, and the view index is checked by
// the godot suite instead of rewritten.
in_ci :: proc() -> bool {
	return os.get_env("CI", context.temp_allocator) == "true"
}

@(private)
report_timing :: proc(secs: f64, ok: bool) {
	command := state.command
	note := ""
	Entry :: struct {
		seconds: f64,
		budget:  f64,
		over:    bool,
		cold:    []string,
		ok:      bool,
	}
	entry := Entry {
		seconds = round2(secs),
		cold    = state.cold[:],
		ok      = ok,
	}
	budget := state.budget > 0 ? state.budget : command.budget
	if budget > 0 {
		allowed := budget * (in_ci() ? CI_BUDGET_SCALE : 1)
		entry.budget = allowed
		if len(state.cold) > 0 {
			note = tprint(
				" (budget %.0fs; cold run, not held to it: %s)",
				allowed,
				strings.join(state.cold[:], ", ", context.temp_allocator),
			)
		} else if secs > allowed {
			entry.over = true
			note = tprint(" (budget %.0fs)", allowed)
			log(
				"uni: OVER BUDGET: %s took %.1fs, budget %.0fs: find out why (AGENTS.md, Non-negotiables)",
				strings.join(state.argv, " ", context.temp_allocator),
				secs,
				allowed,
			)
		} else {
			note = tprint(" (budget %.0fs)", allowed)
		}
	}
	what := strings.join(state.argv, " ", context.temp_allocator)
	log("uni: %s %s in %.1fs%s", what, ok ? "done" : "FAILED", secs, note)
	// .out/timings.json keeps each command line's last run (CI's job summary shows it).
	if os.get_env(CHILD_ENV, context.temp_allocator) != "" {
		return
	}
	path := join(state.project.out, "timings.json")
	timings: map[string]Entry
	if data, err := os.read_entire_file(path, context.allocator); err == nil {
		_ = json.unmarshal(data, &timings)
	}
	timings[what] = entry
	if data, err := json.marshal(timings, {pretty = true}); err == nil {
		_ = write_file(path, data)
	}
}

// Rounds seconds to two decimals for the reports (--json, .out/timings.json, the suites' results).
round2 :: proc(value: f64) -> f64 {
	return f64(i64(value * 100 + 0.5)) / 100
}

// Progress and errors go to stderr; stdout carries only the result.
log :: proc(format: string, args: ..any) {
	fmt.eprintf(format, ..args)
	fmt.eprintln()
}

// A heap copy of a value, for Result.data (marshalled after the command returns).
box :: proc(value: $Value) -> any {
	boxed := new_clone(value)
	return boxed^
}

// Heap slices of commands and suites, for a project's tools/ to return.
box_commands :: proc(commands: ..Command) -> []Command {
	return slice.clone(commands)
}

// A heap slice of suites, for a project's tools/ to return its own test suites (see box_commands).
box_suites :: proc(suites: ..Suite) -> []Suite {
	return slice.clone(suites)
}

// A heap slice of strings.
strs :: proc(items: ..string) -> []string {
	return slice.clone(items)
}

// The CLI's formatter: fmt.aprintf, a heap string valid for the whole run (not the temp allocator, despite the
// name), so it is safe in a Result's summary or data.
tprint :: proc(format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args)
}
