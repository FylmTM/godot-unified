package modes

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "unified:netcode"

// `--key value` options after the mode; flags without a value are not used by this CLI.
Args :: struct {
	mode: string,
	opts: map[string]string,
}

usage :: proc() -> ! {
	fmt.eprintf("usage: %s <mode> [options]\n", len(os.args) > 0 ? os.args[0] : "headless")
	fmt.eprintln(
		`
  sim      --ticks N [--seed S] [--players P] [--trace F] [--log F]
  synctest --ticks N --window W [--seed S] [--players P]
  replay   --log F --trace F
  session  --clients N --transport loopback|udp --profile ideal|wan|bad --ticks N
           [--late-join P@T] [--log F] [--seed S] [--clock real|virtual]
  relay    --port P --players N --ticks T --log F [--bind local|lan]  (lan: listen on every interface)
  client   --connect HOST:PORT --slot I --ticks T [--profile ideal|wan|bad] [--token HEX]  (HEX: 32 digits, what
           the relay knows this person by when they come back over UDP)
  <online>-host   --ticks T [--wait-s N] [--bucket B] [--players N] [--code-file F] [--log F] [transport options]
  <online>-client --code CODE --ticks T [--bucket B] [transport options]
                  (when the game plugs in an online transport, e.g. eos-host / eos-client)
  snapshot --ticks T --out F [--seed S] [--players P]
  resume   --in F --ticks N --trace F
  bench    --entities E --window W --ticks N [--seed S] [--players P]
  table-bench [--live L] [--walks W]  (a sparse 65,536-slot table walk vs a dense one; game-independent)
  any mode: [--game NAME] picks a variant of the game (e.g. its play tuning)`,
	)
	os.exit(2)
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(2)
}

parse_args :: proc() -> (args: Args) {
	argv := os.args[1:]
	if len(argv) < 1 {
		usage()
	}
	args.mode = argv[0]
	for i := 1; i < len(argv); i += 2 {
		key := argv[i]
		if !strings.has_prefix(key, "--") || i + 1 >= len(argv) {
			die("bad argument %q", key)
		}
		args.opts[key[2:]] = argv[i + 1]
	}
	return
}

opt_str :: proc(args: ^Args, key: string, fallback := "", required := false) -> string {
	if value, ok := args.opts[key]; ok {
		return value
	}
	if required {
		die("%s: --%s is required", args.mode, key)
	}
	return fallback
}

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

// Fails on options the mode doesn't know, so typos don't silently fall back to defaults.
// A client token (netcode.Token) from 32 hex digits ("": none).
token_of :: proc(text: string) -> (token: netcode.Token, ok: bool) {
	if text == "" {
		return {}, true
	}
	if len(text) != 2 * netcode.TOKEN_SIZE {
		return
	}
	for &value, i in token {
		byte_value, byte_ok := strconv.parse_u64_of_base(text[2 * i:][:2], 16)
		if !byte_ok {
			return {}, false
		}
		value = u8(byte_value)
	}
	return token, true
}

check_known :: proc(args: ^Args, known: ..string) {
	outer: for key in args.opts {
		for known_key in known {
			if key == known_key {
				continue outer
			}
		}
		die("%s: unknown option --%s", args.mode, key)
	}
}
