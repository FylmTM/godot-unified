// Determinism lint (AGENTS.md "Deterministic simulation"): a token scan of the library packages
// that fails on constructs the simulation must not use. It is cheap (a few ms) and runs with every
// `odin test`. It can't prove determinism (T1, T2, T7 and T8 do that); it stops the known traps
// from creeping back in.
package test_lint

import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "core:testing"

SRC_DIR :: #directory + "/../../src"
GAMES_DIR :: #directory + "/../../games"

Rule :: struct {
	pkg:           string,
	dir:           string, // "" : src/<pkg>; else relative to the repo root
	ban_imports:   []string, // import path prefixes
	allow_imports: []string, // exceptions to ban_imports
	ban_idents:    []string, // identifiers, e.g. types or intrinsics
	ban_matrix:    bool,
}

// core:math (and linalg, rand, noise...) pulls in transcendentals and FMA-friendly code; only the
// integer helpers of core:math/bits are allowed. `matrix` types multiply with fused operations.
MATH :: []string{"core:math"}
MATH_OK :: []string{"core:math/bits"}
FLOAT_TRAPS :: []string {
	"fused_mul_add",
	"quaternion64",
	"quaternion128",
	"quaternion256",
	"complex32",
	"complex64",
	"complex128",
}

GAME_IMPORTS :: []string{"core:math", "core:time", "core:math/rand", "core:os", "core:thread", "core:sync"}
GAME_IDENTS :: []string {
	"fused_mul_add",
	"quaternion64",
	"quaternion128",
	"quaternion256",
	"complex32",
	"complex64",
	"complex128",
	"f64",
	"f16",
}

RULES := []Rule {
	// Game simulation code: f32 only, no clocks, files or threads, no randomness besides the
	// state's RNG.
	{
		pkg = "survivor",
		dir = "games/survivor/simulation/survivor",
		ban_imports = GAME_IMPORTS,
		allow_imports = MATH_OK,
		ban_idents = GAME_IDENTS,
		ban_matrix = true,
	},
	// Library code that runs inside a tick: the same rules as game code.
	{pkg = "dmath", ban_imports = GAME_IMPORTS, allow_imports = MATH_OK, ban_idents = GAME_IDENTS, ban_matrix = true},
	// physics guards Box3D world creation with a mutex (core:sync), nothing else of the kind.
	{
		pkg = "physics",
		ban_imports = {"core:math", "core:time", "core:math/rand", "core:os", "core:thread"},
		allow_imports = MATH_OK,
		ban_idents = GAME_IDENTS,
		ban_matrix = true,
	},
	// The harness: f32 traps and core:math banned; it reads files (logs) and that's fine.
	{pkg = "sim", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	{pkg = "box3d", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	{pkg = "wire", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	// Netcode and the headless tools feed inputs into the sim and own real-time clocks (fine), but
	// stay off core:math.
	{pkg = "netcode", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	{pkg = "headless", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	// The survivor's headless binary (package main): only wires the game into unified:headless.
	{
		pkg = "headless_main",
		dir = "games/survivor/simulation/headless",
		ban_imports = MATH,
		allow_imports = MATH_OK,
		ban_idents = FLOAT_TRAPS,
		ban_matrix = true,
	},
}

rule_dir :: proc(r: Rule) -> string {
	if r.dir != "" {
		return strings.concatenate({SRC_DIR, "/../", r.dir}, context.temp_allocator)
	}
	return strings.concatenate({SRC_DIR, "/", r.pkg}, context.temp_allocator)
}

// Returns one line per violation in `src` (file `name`) under rule `r`.
scan :: proc(r: Rule, name, src: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	tz: tokenizer.Tokenizer
	tokenizer.init(&tz, src, name, proc(_: tokenizer.Pos, _: string, _: ..any) {})
	after_import := false
	for tok := tokenizer.scan(&tz); tok.kind != .EOF; tok = tokenizer.scan(&tz) {
		where_ := fmt.tprintf("%s(%d:%d)", name, tok.pos.line, tok.pos.column)
		#partial switch tok.kind {
		case .Import:
			after_import = true
			continue
		case .Matrix:
			if r.ban_matrix {
				append(
					&out,
					fmt.aprintf("%s: `matrix` types are banned in package %s", where_, r.pkg, allocator = allocator),
				)
			}
		case .Ident:
			if after_import {
				continue // import alias
			}
			for b in r.ban_idents {
				if tok.text == b {
					append(
						&out,
						fmt.aprintf("%s: `%s` is banned in package %s", where_, b, r.pkg, allocator = allocator),
					)
				}
			}
		case .String:
			if after_import {
				path := strings.trim(tok.text, "\"`")
				if banned_import(r, path) {
					append(
						&out,
						fmt.aprintf(
							"%s: import %q is banned in package %s",
							where_,
							path,
							r.pkg,
							allocator = allocator,
						),
					)
				}
			}
		}
		after_import = false
	}
	return out[:]
}

banned_import :: proc(r: Rule, path: string) -> bool {
	for ok in r.allow_imports {
		if path == ok {
			return false
		}
	}
	for b in r.ban_imports {
		if path == b || strings.has_prefix(path, strings.concatenate({b, "/"}, context.temp_allocator)) {
			return true
		}
	}
	return false
}

@(test)
library_follows_determinism_rules :: proc(t: ^testing.T) {
	for r in RULES {
		dir := rule_dir(r)
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if !testing.expectf(t, err == nil, "cannot list %s: %v", dir, err) {
			continue
		}
		files := 0
		for fi in infos {
			if !strings.has_suffix(fi.name, ".odin") {
				continue
			}
			data, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator)
			if !testing.expectf(t, rerr == nil, "cannot read %s", fi.fullpath) {
				continue
			}
			files += 1
			for v in scan(r, fi.fullpath, string(data)) {
				testing.expect(t, false, v)
			}
		}
		testing.expectf(t, files > 0, "no .odin files in %s", dir)
	}
}

// Every library package and every package of the survivor's simulation/ has a rule, so a new one
// can't skip the lint.
@(test)
every_package_has_a_rule :: proc(t: ^testing.T) {
	check_dir :: proc(t: ^testing.T, dir, prefix: string) {
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if !testing.expectf(t, err == nil, "cannot list %s: %v", dir, err) {
			return
		}
		outer: for fi in infos {
			if fi.type != .Directory {
				continue
			}
			for r in RULES {
				if (r.dir == "" && prefix == "src" && r.pkg == fi.name) ||
				   r.dir == strings.concatenate({prefix, "/", fi.name}, context.temp_allocator) {
					continue outer
				}
			}
			testing.expectf(t, false, "%s/%s has no determinism rule in tests/lint/lint_test.odin", prefix, fi.name)
		}
	}
	check_dir(t, SRC_DIR, "src")
	check_dir(t, GAMES_DIR + "/survivor/simulation", "games/survivor/simulation")
}

// The lint itself: each banned construct is caught, and comments, strings and allowed imports
// are not flagged.
@(test)
lint_catches_violations :: proc(t: ^testing.T) {
	bad := `package survivor
import "core:math"
import la "core:math/linalg"
import "core:time"
M :: matrix[2, 2]f32
x: f64
y := intrinsics.fused_mul_add(a, b, c)
`
	clean := `package survivor
import "core:math/bits"
import "base:intrinsics"
// matrix f64 "core:math" in a comment
s := "matrix f64 core:math"
z := intrinsics.sqrt(f32(2))
`
	game_rule := RULES[0]
	testing.expect_value(t, len(scan(game_rule, "bad.odin", bad)), 6)
	for v in scan(game_rule, "clean.odin", clean) {
		testing.expect(t, false, v)
	}
}
