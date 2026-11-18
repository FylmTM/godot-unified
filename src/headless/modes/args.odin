package modes

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import uheadless "unified:headless"
import "unified:netcode"

// A mode's `--key value` options (after the mode's name), and the lobby service of a lobby mode.
Args :: struct {
	mode:  string,
	opts:  map[string]string,
	lobby: ^netcode.Lobby, // <name>-host and <name>-client: the service they run on
	bench: uheadless.Bench, // the game's standard benchmark (run's `bench`), for the `bench` mode
}

// Prints a formatted error to stderr and exits with code 2, the way every mode (and a game's own modes) rejects a bad
// or missing option.
die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(2)
}

// Reads `--key value` pairs; exits through die when they are not.
@(private)
parse_options :: proc(mode: string, argv: []string) -> (args: Args) {
	args.mode = mode
	for i := 0; i < len(argv); i += 2 {
		key := argv[i]
		if !strings.has_prefix(key, "--") || i + 1 >= len(argv) {
			die("%s: bad argument %q (options are --key value)", mode, key)
		}
		if key[2:] in args.opts {
			die("%s: %s given twice", mode, key)
		}
		args.opts[key[2:]] = argv[i + 1]
	}
	return
}

// Fails on options the mode doesn't take (every `--name` its usage line shows), so typos don't silently fall back to
// defaults.
@(private)
check_known :: proc(args: ^Args, usage: string) {
	outer: for key in args.opts {
		rest := usage
		for {
			at := strings.index(rest, "--")
			if at < 0 {
				break
			}
			rest = rest[at + 2:]
			end := 0
			for end < len(rest) && (rest[end] == '-' || rest[end] >= 'a' && rest[end] <= 'z') {
				end += 1
			}
			if rest[:end] == key {
				continue outer
			}
		}
		die("%s: unknown option --%s (usage: %s %s)", args.mode, key, args.mode, usage)
	}
}

// The value of `--key`, or `fallback` when it is absent; exits through die when a required option is missing.
opt_str :: proc(args: ^Args, key: string, fallback := "", required := false) -> string {
	if value, ok := args.opts[key]; ok {
		return value
	}
	if required {
		die("%s: --%s is required", args.mode, key)
	}
	return fallback
}

// The value of `--key` as an integer in [low, high], or `fallback` when absent; exits through die when a
// required option is missing or the value is not such an integer.
opt_int :: proc(args: ^Args, key: string, fallback := 0, required := false, low := 0, high := max(int)) -> int {
	text, ok := args.opts[key]
	if !ok {
		if required {
			die("%s: --%s is required", args.mode, key)
		}
		return fallback
	}
	value, value_ok := strconv.parse_int(text)
	if !value_ok || value < low || value > high {
		die("%s: --%s must be an integer in [%d, %d], got %q", args.mode, key, low, high, text)
	}
	return value
}
