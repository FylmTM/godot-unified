// The unified CLI as a library (README.md). A project's tools/ package (package main) calls `run` with the public
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
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:time"

// A command: `run` parses its own arguments with `parse` and returns its result.
Command :: struct {
	name:    string,
	summary: string,
	// The options struct of each form the command parses (`option_types`, `option_forms`; `parse` refuses another):
	// `help`'s usage line and -h's option table are made from their fields (command_usage).
	options: []Form,
	details: proc() -> string, // more for -h (nil: nothing): what the summary has no room for
	run:     proc(args: []string) -> Result,
}

// One way to call a command: its options struct, after a subcommand word when the command has several (`board
// list`, `board set`; "": none). An options field's tags say how it reads: `usage` (what it does, for -h), `args`
// (core:flags: `pos=N`, `required`, `name=...`, `hidden`) and `hint` (what -h shows for its value: `<url>`; an enum
// shows its names, any other value `<name>`; the `overflow` field's whole text, e.g. `[-- args]`) and, on the
// `overflow` field, `after:"--"` (it takes only what follows --: a positional before it is a usage error).
Form :: struct {
	word: string,
	type: typeid,
}

// Command.options of a command with one form per type and no subcommand words (one type, nearly always).
option_types :: proc(types: ..typeid) -> []Form {
	forms := make([]Form, len(types))
	for type, i in types {
		forms[i] = {"", type}
	}
	return forms
}

// Command.options of a command with subcommands: each form's word and options type.
option_forms :: proc(forms: ..Form) -> []Form {
	return slice.clone(forms)
}

// What a project's tools/ adds to the conventions (README.md, What a project adds), set with `configure` before
// `run`. A game repo needs none of it; this repo registers its test root, its toy game and its Godot test extensions.
Project_Config :: struct {
	tests:             string, // the odin suite's root, relative to the project, compiled with -all-packages ("": the game's simulation/tests)
	// The odin suite's second root (with `tests`), relative to the project: test packages that need no optimised code,
	// compiled unoptimised beside `tests` and run beside it, so the optimised compile is smaller ("": none).
	unoptimized_tests: string,
	headless:          []Extra_Headless, // headless binaries besides the games' (`headless`, `build`)
	vet:               []string, // more packages `vet` checks (no entry point), relative to the project
	fmt:               []string, // more directories `fmt` formats, relative to the project
	uses_box3d:        bool, // something besides the games links Box3D (the tests root)
	bench:             []Bench_Row, // more `bench` rows, after the games'
	bake:              []Bake_Target, // more level scenes `bake` exports when run without a game
}

// Level scenes outside the games that `bake` exports (this repo: the 2D fixture tests/level reads).
Bake_Target :: struct {
	dir:       string, // the Godot project, relative to the project
	scenes:    []string, // res:// paths
	// The Godot project's GDExtension when the exporter needs it (the game's view_scale), relative to the project
	// ("": none): built (dev) to <dir>/.out/bin/<library> when stale, before baking.
	extension: string,
	library:   string, // the extension library's stem
}

// A headless binary that is no game's (this repo's toy).
Extra_Headless :: struct {
	name: string,
	pkg:  string, // relative to the project
}

// A `bench` row of the project's own: its benchmark program, which `bench` builds (release) together with the games'
// binaries before any row runs, and `run`, which runs that binary (its files may go in `work`), logs its line and
// returns what .out/bench.json's `rows` keeps under `name`.
Bench_Row :: struct {
	name:     string,
	program:  Extra_Headless,
	bindings: bool, // the program imports unified:godot: its Godot API bindings are generated first
	run:      proc(work, binary: string) -> (data: any, ok: bool),
}

// Registers a project's additions (call before `run`).
configure :: proc(config: Project_Config) {
	state.config = config
}

// A test suite of `test` (README.md, Test suites): `run` reports whether it passed. A project's tools/ adds its own
// with `add_suites` before `run`.
Suite :: struct {
	name:    string,
	summary: string,
	run:     proc(games: []Game, opts: Test_Options) -> bool,
	// Mostly waits (the real clock, timers): run with other suites, it runs beside them in a child process.
	beside:  bool,
	// With `beside`: makes current, before any suite of the run starts, what it builds that the others share (nil:
	// nothing); it gets what `run` will (the games the run names and its options), so it builds only what they need.
	prepare: proc(games: []Game, opts: Test_Options),
}

// What `test` passes each suite it runs: the options of that run (a nested `test`, as `verify` runs it, has its own).
Test_Options :: struct {
	only:                []string, // tests (odin) or steps (godot)
	long:                bool, // `--long`: the suites' long variants (README.md, Test suites)
	bless:               bool, // `--bless`: the odin suite re-pins what moved (src/headless/README.md, Re-pinning)
	game:                string, // the game `test` names ("": every game): the odin suite compiles that game's tests only
	// The library test package `test` names instead of a game (test_package: one a test root imports), its path
	// ("": none): the odin suite compiles it alone, unoptimised when it is under the unoptimised root.
	library_tests:       string,
	library_unoptimized: bool,
}

// What a command reports: one line on stdout, or with --json one object (command, ok, summary, seconds and `data`,
// marshalled after the command returns, so it must not point at the command's stack).
Result :: struct {
	ok:      bool,
	summary: string,
	data:    any,
}

// The run's state, one per process (`state`): the project, its configuration and pins, the commands and suites
// registered and the command running.
State :: struct {
	project:  Project,
	config:   Project_Config,
	pins:     Config,
	commands: [dynamic]Command,
	command:  ^Command,
	argv:     []string, // the command line after the program name, --json and --verbose removed
	json:     bool,
	verbose:  bool, // --verbose (or VERBOSE_ENV, so a uni the CLI starts is verbose too): echo every command line
	start:    time.Tick,
	env_keys: []string, // the variables .env set
	suites:   [dynamic]Suite,
	undo:     [dynamic]Undo, // what a failing command undoes (on_failure), run newest first by `unwind`
}

// Work a failing command undoes (on_failure): `undo(data)`.
Undo :: struct {
	undo: proc(data: rawptr),
	data: rawptr,
}

// Registers what to undo if the command fails before its work is done: a stamped file to put back, a half-made
// directory to remove. `fatal`, a usage error and a failed result run every one (`unwind`); a command that finishes
// its work undoes it itself, or keeps it. `data` (nil: none) must outlive the caller's frame.
on_failure :: proc(undo: proc(data: rawptr), data: rawptr = nil) {
	append(&state.undo, Undo{undo, data})
}

// Runs every registered undo once, newest first, and forgets them (what every failing exit of a command does), then
// releases every lock the command still holds (lock_release_all: os.exit runs no `defer`). An undo that itself fails
// with `fatal` stops there; the older ones still run.
unwind :: proc() {
	for len(state.undo) > 0 {
		undo := pop(&state.undo)
		undo.undo(undo.data)
	}
	lock_release_all()
}

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
	argv: []string
	argv, state.json, state.verbose = split_global_flags(args)
	state.argv = argv
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

// The command line without the options every command takes (--json, --verbose), and whether each was there. They
// count only before a `--`: what follows belongs to the game, the script or the mode (Godot's own --verbose).
split_global_flags :: proc(args: []string) -> (argv: []string, as_json, verbose: bool) {
	out := make([dynamic]string)
	ended := false
	for arg in args {
		switch {
		case ended:
			append(&out, arg)
		case arg == "--":
			ended = true
			append(&out, arg)
		case arg == "--json":
			as_json = true
		case arg == "--verbose":
			verbose = true
		case:
			append(&out, arg)
		}
	}
	return out[:], as_json, verbose
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

// Prints `uni help`: every command with its usage (every option and form) and summary, then how the pinned Odin and
// the per-user cache work. Shown for `help`, -h, --help and a bare `uni`.
print_help :: proc() {
	fmt.println("uni: build, test, check and run the games of this project (src/cli/README.md)\n")
	fmt.println("usage: uni <command> [options] [--json] [--verbose]   (uni <command> -h: its options and details)\n")
	fmt.println(
		"Any command (before any --): --json prints the result as one JSON object; --verbose echoes every command line it runs.\n",
	)
	for command in state.commands {
		fmt.printf("  %s\n      %s\n", strings.trim_space(command_usage(command)), command.summary)
	}
	fmt.printf(
		"\nEvery command prints how long it took (stderr); `bench` times the simulation itself.\nOdin: the release pins.cfg pins, downloaded once by the shims (./uni, uni.cmd) into the per-user cache and put first on PATH.\nThe per-user cache (%s), shared by every checkout: the shims' Odin, and what the CLI puts there (`clean --cache` clears it): the pinned Godot, the unified-box3d zip, odinfmt.\n",
		USER_CACHE,
	)
}

// The per-user cache (cache.odin, user_cache), as `help` names it.
@(private)
USER_CACHE :: "%LOCALAPPDATA%\\unified" when ODIN_OS == .Windows else "${XDG_CACHE_HOME:-~/.cache}/unified"

// Parses a command's arguments into `opts` (core:flags, Unix style: --name value, --name=value, positionals, and
// everything after -- into an `overflow` field). -h prints the command's help and exits; a bad argument exits 2.
// `Options` must be one of the command's `options` (the table is what -h and `vet` read).
parse :: proc(opts: ^$Options, args: []string) {
	named := false
	for form in state.command.options {
		named ||= form.type == typeid_of(Options)
	}
	if !named {
		fatal(
			"its command table entry doesn't name the options it parses (%v): add them to Command.options",
			typeid_of(Options),
		)
	}
	if slice.contains(args, "-h") || slice.contains(args, "--help") {
		fmt.print(command_help(state.command^))
		os.exit(0)
	}
	if err := flags.parse(opts, args, .Unix); err != nil {
		usage_error(err)
	}
	for field in reflect.struct_fields_zipped(Options) {
		if field.name != "overflow" || field.type.id != typeid_of([dynamic]string) {
			continue
		}
		if after, tagged := reflect.struct_tag_lookup(field.tag, "after"); tagged && after == "--" {
			overflow := (^[dynamic]string)(uintptr(opts) + field.offset)
			if stray := stray_positionals(args, overflow[:]); len(stray) > 0 {
				usage("unexpected argument %q (the game's own arguments go after --)", stray[0])
			}
		}
	}
}

// The positionals core:flags put in an `overflow` field that came before the first `--` (it fills the field with
// both): for a field that takes only what follows -- (`after:"--"`), each one is a mistake.
stray_positionals :: proc(args, overflow: []string) -> []string {
	after := 0
	for arg, i in args {
		if arg == "--" {
			after = len(args) - i - 1
			break
		}
	}
	return overflow[:max(0, len(overflow) - after)]
}

// A command's -h: its usage line (every form) and summary, each option of its `options` with what it does,
// and its details.
command_help :: proc(command: Command) -> string {
	builder := strings.builder_make()
	fmt.sbprintf(&builder, "usage: uni %s\n%s\n", strings.trim_space(command_usage(command)), command.summary)
	Row :: struct {
		label, text: string,
	}
	rows: [dynamic]Row
	width := 0
	for option in command_options(command) {
		label := option.label
		if option.overflow {
			label = "..."
		}
		seen := false
		for row in rows {
			seen ||= row.label == label // a form repeats an option another form has
		}
		if !seen {
			append(&rows, Row{label, option.usage})
			width = max(width, len(label))
		}
	}
	if len(rows) > 0 {
		strings.write_string(&builder, "\n")
	}
	for row in rows {
		fmt.sbprintf(&builder, "  %-*s  %s\n", width, row.label, row.text)
	}
	if command.details != nil {
		fmt.sbprintf(&builder, "\n%s\n", strings.trim_right_space(command.details()))
	}
	return strings.to_string(builder)
}

// A command's usage line, made from its options: "name <pos> [pos] [--switch] [--flag hint] overflow", the forms
// joined by " | " (a later form repeats the command's name: "board list ... | board set <issue> ...").
command_usage :: proc(command: Command) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, command.name)
	for form, i in command.options {
		if i > 0 {
			fmt.sbprintf(&builder, " | %s", command.name)
		}
		if form.word != "" {
			fmt.sbprintf(&builder, " %s", form.word)
		}
		for option in form_options(form) {
			fmt.sbprintf(&builder, " %s", option.usage_word)
		}
	}
	return strings.to_string(builder)
}

// One field of a command's options, as core:flags reads it and help shows it.
Option :: struct {
	name:       string, // the flag (`args:"name=..."`, else the field's name with - for _) or the positional
	usage:      string, // the `usage` tag
	positional: bool, // `args:"pos=N"`
	overflow:   bool, // the `overflow` field: positionals past the numbered ones and everything after --
	label:      string, // -h's: "[game]", "<issue>", "--mode dev|release|debug", "--check"
	usage_word: string, // the usage line's: "[game]", "<issue>", "[--mode dev|release|debug]", "--tag <tag>"
}

// The fields of every options type the command names, in order.
command_options :: proc(command: Command) -> []Option {
	out: [dynamic]Option
	for form in command.options {
		append(&out, ..form_options(form))
	}
	return out[:]
}

// The fields of one form's options type, in order (hidden ones left out).
form_options :: proc(form: Form) -> []Option {
	out: [dynamic]Option
	for field in reflect.struct_fields_zipped(form.type) {
		args_tag, _ := reflect.struct_tag_lookup(field.tag, "args")
		if _, hidden := flags.get_subtag(string(args_tag), "hidden"); hidden {
			continue
		}
		usage_tag, _ := reflect.struct_tag_lookup(field.tag, "usage")
		hint_tag, _ := reflect.struct_tag_lookup(field.tag, "hint")
		hint := string(hint_tag)
		option := Option {
			usage = string(usage_tag),
		}
		option.name, _ = strings.replace_all(field.name, "_", "-")
		if name, renamed := flags.get_subtag(string(args_tag), "name"); renamed {
			option.name = name
		}
		_, option.positional = flags.get_subtag(string(args_tag), "pos")
		_, required := flags.get_subtag(string(args_tag), "required")
		option.overflow = field.name == "overflow"
		switch {
		case option.overflow:
			option.label = hint != "" ? hint : "[args...]"
			option.usage_word = option.label
		case option.positional:
			shown := hint != "" ? hint : option.name
			option.label = required ? aprintf("<%s>", shown) : aprintf("[%s]", shown)
			option.usage_word = option.label
		case reflect.is_boolean(field.type):
			option.label = aprintf("--%s", option.name)
			option.usage_word = required ? option.label : aprintf("[%s]", option.label)
		case:
			if hint == "" {
				hint = aprintf("<%s>", option.name)
				if reflect.is_enum(field.type) {
					hint = strings.join(reflect.enum_field_names(field.type.id), "|")
				}
			}
			option.label = aprintf("--%s %s", option.name, hint)
			option.usage_word = required ? option.label : aprintf("[%s]", option.label)
		}
		append(&out, option)
	}
	return out[:]
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
		msg = aprintf("cannot open %s", problem.filename)
	case flags.Help_Request:
		msg = "-h prints the usage"
	}
	log("uni %s: %s (uni %s -h)", state.command.name, msg, state.command.name)
	unwind()
	os.exit(2)
}

// Stops with a usage error (exit 2).
usage :: proc(format: string, args: ..any) -> ! {
	log("uni %s: %s (uni %s -h)", state.command.name, aprintf(format, ..args), state.command.name)
	unwind()
	os.exit(2)
}

// Ends the run: the result on stdout, how long it took on stderr, the exit code. A failed one first undoes what the
// command registered (unwind).
@(private)
finish :: proc(result: Result) -> ! {
	if !result.ok {
		unwind()
	}
	secs := time.duration_seconds(time.tick_since(state.start))
	what := strings.join(state.argv, " ", context.temp_allocator)
	log("uni: %s %s in %.1fs", what, result.ok ? "done" : "FAILED", secs)
	if state.json {
		Out :: struct {
			command: string,
			ok:      bool,
			summary: string,
			seconds: f64,
		}
		head, err := json.marshal(Out{state.command.name, result.ok, result.summary, round2(secs)})
		data := transmute([]byte)string("null")
		if err == nil && result.data != nil {
			data, err = json.marshal(result.data)
		}
		if err != nil {
			log("uni: cannot encode the result as JSON: %v", err)
			os.exit(1)
		}
		// {"command":...,"seconds":...,"data":<the command's data>}
		fmt.printf("%s,\"data\":%s}\n", string(head[:len(head) - 1]), string(data))
	} else if result.summary != "" {
		fmt.println(result.summary)
	}
	os.exit(result.ok ? 0 : 1)
}

// Stops the command as failed: the message on stderr (and in the --json result).
fatal :: proc(format: string, args: ..any) -> ! {
	msg := aprintf(format, ..args)
	if state.command == nil {
		log("uni: %s", msg)
		unwind()
		os.exit(1)
	}
	log("uni %s: %s", state.command.name, msg)
	finish({ok = false, summary = msg})
}

// Rounds seconds to two decimals for the reports (--json, the suites' results).
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

// A heap slice of strings.
strs :: proc(items: ..string) -> []string {
	return slice.clone(items)
}

// The CLI's formatter: fmt.aprintf, a heap string valid for the whole run, so it is safe in a Result's summary or
// data.
aprintf :: proc(format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args)
}
