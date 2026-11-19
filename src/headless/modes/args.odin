package modes

@(require) import "core:flags" // only in parse, a generic proc
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"

import uheadless "unified:headless"
import "unified:netcode"

// What a mode gets: its name, the words of its options (the command line after the mode's name, less the options any
// mode takes: --game, --level, --setup), the lobby service of a lobby mode and the game's standard benchmark.
Args :: struct {
	mode:  string,
	argv:  []string,
	lobby: ^netcode.Lobby, // <name>-host and <name>-client: the service they run on
	bench: uheadless.Bench, // the game's standard benchmark (run's `bench`), for the `bench` mode
}

// Prints a formatted error to stderr and exits with code 2, the way every mode (and a game's own modes) rejects a bad
// or missing option.
die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(2)
}

// Parses the mode's options into `options` with core:flags, Unix style (`--name value` or `--name=value`, a bool a
// bare `--name`; a field `wait_s` is `--wait-s`). Set the defaults in `options` first: an option not given keeps its
// field. Exits through die on an unknown option, a missing `args:"required"` one or a value of the wrong type; a
// range is the mode's to check (in_range).
parse :: proc(args: ^Args, options: ^$Options) {
	err := flags.parse(options, args.argv, .Unix)
	message := ""
	switch problem in err {
	case flags.Parse_Error:
		message = problem.message
	case flags.Validation_Error:
		message = problem.message
	case flags.Open_File_Error:
		message = fmt.tprintf("cannot open %s", problem.filename)
	case flags.Help_Request:
		message = "--help prints the usage"
	}
	if message != "" {
		die("%s: %s (usage: %s %s)", args.mode, message, args.mode, usage(Options))
	}
}

// Exits through die unless option `--name`'s `value` is in [low, high].
in_range :: proc(args: ^Args, name: string, value, low, high: int) {
	if value < low || value > high {
		die("%s: --%s must be an integer in [%d, %d], got %d", args.mode, name, low, high, value)
	}
}

// A mode's options as `help` shows them, from its options type: `--name HINT` per field (the `hint` tag, else N for a
// number and S for text), in brackets unless `args:"required"`, a bool a bare `--name`.
usage :: proc(options: typeid) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for field in reflect.struct_fields_zipped(options) {
		args_tag := reflect.struct_tag_get(field.tag, "args")
		name, _ := strings.replace_all(field.name, "_", "-", context.temp_allocator)
		if renamed, ok := flags.get_subtag(args_tag, "name"); ok do name = renamed
		word := fmt.tprintf("--%s", name)
		if !reflect.is_boolean(field.type) {
			hint := reflect.struct_tag_get(field.tag, "hint")
			if hint == "" do hint = reflect.is_string(field.type) ? "S" : "N"
			word = fmt.tprintf("%s %s", word, hint)
		}
		_, required := flags.get_subtag(args_tag, "required")
		if strings.builder_len(builder) > 0 do strings.write_byte(&builder, ' ')
		fmt.sbprintf(&builder, required ? "%s" : "[%s]", word)
	}
	return strings.to_string(builder)
}

// The options any mode takes, taken out of a mode's words before it parses its own (`rest`, temp-allocated).
@(private)
Any_Mode :: struct {
	game, level, setup: string,
	rest:               []string,
}

@(private)
take_any_mode :: proc(argv: []string) -> (taken: Any_Mode) {
	rest := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(argv); i += 1 {
		name, _, inline := strings.partition(argv[i], "=")
		target: ^string
		switch name {
		case "--game":
			target = &taken.game
		case "--level":
			target = &taken.level
		case "--setup":
			target = &taken.setup
		}
		if target == nil {
			append(&rest, argv[i])
		} else if strings.contains_rune(argv[i], '=') {
			target^ = inline
		} else if i + 1 < len(argv) {
			i += 1
			target^ = argv[i]
		} else {
			die("%s wants a value", name)
		}
	}
	taken.rest = rest[:]
	return
}
