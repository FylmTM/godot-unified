package modes

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

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
  client   --connect HOST:PORT --player I --ticks T [--profile ideal|wan|bad]
  <online>-host   --ticks T [--wait-s N] [--bucket B] [--players N] [--code-file F] [--log F] [transport options]
  <online>-client --code CODE --ticks T [--bucket B] [transport options]
                  (when the game plugs in an online transport, e.g. eos-host / eos-client)
  snapshot --ticks T --out F [--seed S] [--players P]
  resume   --in F --ticks N --trace F
  bench    --enemies E --window W --ticks N [--seed S] [--players P]
  any mode: [--game NAME] picks a variant of the game (e.g. its play tuning)`,
	)
	os.exit(2)
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(2)
}

parse_args :: proc() -> (a: Args) {
	argv := os.args[1:]
	if len(argv) < 1 {
		usage()
	}
	a.mode = argv[0]
	for i := 1; i < len(argv); i += 2 {
		k := argv[i]
		if !strings.has_prefix(k, "--") || i + 1 >= len(argv) {
			die("bad argument %q", k)
		}
		a.opts[k[2:]] = argv[i + 1]
	}
	return
}

opt_str :: proc(a: ^Args, key: string, def := "", required := false) -> string {
	if v, ok := a.opts[key]; ok {
		return v
	}
	if required {
		die("%s: --%s is required", a.mode, key)
	}
	return def
}

opt_int :: proc(a: ^Args, key: string, def := 0, required := false, lo := 0, hi := max(int)) -> int {
	v, ok := a.opts[key]
	if !ok {
		if required {
			die("%s: --%s is required", a.mode, key)
		}
		return def
	}
	n, nok := strconv.parse_int(v)
	if !nok || n < lo || n > hi {
		die("%s: --%s must be an integer in [%d, %d], got %q", a.mode, key, lo, hi, v)
	}
	return n
}

// Fails on options the mode doesn't know, so typos don't silently fall back to defaults.
check_known :: proc(a: ^Args, known: ..string) {
	outer: for k in a.opts {
		for kk in known {
			if k == kk {
				continue outer
			}
		}
		die("%s: unknown option --%s", a.mode, k)
	}
}
