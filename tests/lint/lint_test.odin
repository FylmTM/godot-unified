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

Rule :: struct {
	pkg:           string,
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

RULES := []Rule {
	// Simulation state and systems: f32 only, no clocks, no randomness besides the state's RNG.
	{
		pkg = "game",
		ban_imports = {"core:math", "core:time", "core:math/rand", "core:os"},
		allow_imports = MATH_OK,
		ban_idents = {
			"fused_mul_add",
			"quaternion64",
			"quaternion128",
			"quaternion256",
			"complex32",
			"complex64",
			"complex128",
			"f64",
			"f16",
		},
		ban_matrix = true,
	},
	{pkg = "sim", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	{pkg = "box3d", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	{pkg = "pod", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	{pkg = "wire", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	// Netcode feeds inputs into the sim and owns real-time clocks (fine), but stays off core:math.
	{pkg = "netcode", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	// EOS transport (real-time, like netcode): the SDK bindings need f64 fields, nothing else.
	{pkg = "eos", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
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
		dir := strings.concatenate({SRC_DIR, "/", r.pkg}, context.temp_allocator)
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

// Every library package has a rule, so a new one can't skip the lint. The CLI (package main) is
// the only exception: it is the host program, not simulation code.
@(test)
every_package_has_a_rule :: proc(t: ^testing.T) {
	infos, err := os.read_all_directory_by_path(SRC_DIR, context.temp_allocator)
	if !testing.expectf(t, err == nil, "cannot list %s: %v", SRC_DIR, err) {
		return
	}
	outer: for fi in infos {
		if fi.type != .Directory || fi.name == "cli" {
			continue
		}
		for r in RULES {
			if r.pkg == fi.name {
				continue outer
			}
		}
		testing.expectf(t, false, "src/%s has no determinism rule in tests/lint/lint_test.odin", fi.name)
	}
}

// The lint itself: each banned construct is caught, and comments, strings and allowed imports
// are not flagged.
@(test)
lint_catches_violations :: proc(t: ^testing.T) {
	bad := `package game
import "core:math"
import la "core:math/linalg"
import "core:time"
M :: matrix[2, 2]f32
x: f64
y := intrinsics.fused_mul_add(a, b, c)
`
	clean := `package game
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
