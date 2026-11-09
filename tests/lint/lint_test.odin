// Determinism lint (AGENTS.md "Deterministic simulation"): a token scan of the library packages
// that fails on constructs the simulation must not use. It is cheap (a few ms) and runs with every
// `odin test`. It can't prove determinism (T1, T2, T7 and T8 do that); it stops the known traps
// from creeping back in.
package test_lint

import "base:runtime"
import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "core:testing"

SRC_DIR :: #directory + "/../../src"
GAMES_DIR :: #directory + "/../../games"

Rule :: struct {
	pkg:           string,
	dir:           string, // "" : src/<pkg>; else relative to the repo root (subdirectories included)
	only_imports:  []string, // when set: the only imports allowed (../x counts as unified:x; "a/" allows a/*)
	ban_imports:   []string, // import path prefixes
	allow_imports: []string, // exceptions to ban_imports
	ban_idents:    []string, // identifiers, e.g. types or intrinsics
	ban_matrix:    bool,
	strict:        bool, // also bans `foreign`, `map` and `x := 1.5` (an untyped float literal is f64)
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

// Inside a tick: f32 only, no clocks, entropy or cycle counters.
SIM_IDENTS :: []string {
	"fused_mul_add",
	"quaternion64",
	"quaternion128",
	"quaternion256",
	"complex32",
	"complex64",
	"complex128",
	"f64",
	"f64le",
	"f64be",
	"f16",
	"f16le",
	"f16be",
	"read_cycle_counter",
	"read_cycle_counter_frequency",
	"random_generator",
	"default_random_generator",
}

// What code inside a tick may import: the deterministic packages and the integer bit helpers.
TICK_IMPORTS :: []string {
	"unified:sim",
	"unified:physics",
	"unified:level",
	"unified:dmath",
	"unified:box3d",
	"unified:wire",
	"base:intrinsics",
	"core:math/bits",
}

RULES := []Rule {
	// Game simulation code: an import allowlist, f32 only, no foreign code, no maps, no clocks,
	// files or threads, no randomness besides the state's RNG.
	{
		pkg = "survivor",
		dir = "games/survivor/simulation/survivor",
		only_imports = TICK_IMPORTS,
		ban_idents = SIM_IDENTS,
		ban_matrix = true,
		strict = true,
	},
	// Library code that runs inside a tick: the same rules as game code.
	{pkg = "dmath", only_imports = TICK_IMPORTS, ban_idents = SIM_IDENTS, ban_matrix = true, strict = true},
	// physics walks RTTI (base:runtime) and guards Box3D world creation with a mutex (core:sync).
	{pkg = "physics", only_imports = PHYSICS_IMPORTS, ban_idents = SIM_IDENTS, ban_matrix = true, strict = true},
	// Levels: parsed when a World is created; plain data, through unified:wire.
	{pkg = "level", only_imports = {"unified:wire"}, ban_idents = SIM_IDENTS, ban_matrix = true, strict = true},
	// The harness: also walks RTTI, hashes, formats errors and reads and writes log files.
	{pkg = "sim", only_imports = SIM_IMPORTS, ban_idents = SIM_IDENTS, ban_matrix = true, strict = true},
	// The Box3D binding: foreign code by nature, through core:c only.
	{
		pkg = "box3d",
		only_imports = {"core:c", "../../third_party/box3d/"},
		ban_idents = FLOAT_TRAPS,
		ban_matrix = true,
	},
	{pkg = "wire", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	// Netcode and the headless tools feed inputs into the sim and own real-time clocks (fine), but
	// stay off core:math.
	{pkg = "netcode", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	// Host side (Godot bindings, view, dev UI): never feeds back into the sim, so no bans;
	// listed so every package is accounted for.
	{pkg = "gdext"},
	{pkg = "view"},
	{pkg = "imgui"},
	{pkg = "devui"},
	{pkg = "godot_host"},
	// EOS transport (real-time, like netcode): the SDK bindings need f64 fields, nothing else.
	{pkg = "eos", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	{pkg = "headless", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	// The survivor's headless binary (package main): wires the game and EOS into unified:headless.
	{
		pkg = "headless_main",
		dir = "games/survivor/simulation/headless",
		ban_imports = MATH,
		allow_imports = MATH_OK,
		ban_idents = FLOAT_TRAPS,
		ban_matrix = true,
	},
	// The survivor's GDExtension: host side (views, HUD, input glue), never inside a tick.
	{pkg = "survivor_extension", dir = "games/survivor/simulation/extension"},
	// friendslop (spec/friendslop.md): its sim follows the game rules; its headless binary and GDExtension
	// are like the survivor's.
	{
		pkg = "friendslop",
		dir = "games/friendslop/simulation/friendslop",
		only_imports = TICK_IMPORTS,
		ban_idents = SIM_IDENTS,
		ban_matrix = true,
		strict = true,
	},
	{
		pkg = "friendslop_headless",
		dir = "games/friendslop/simulation/headless",
		ban_imports = MATH,
		allow_imports = MATH_OK,
		ban_idents = FLOAT_TRAPS,
		ban_matrix = true,
	},
	{pkg = "friendslop_extension", dir = "games/friendslop/simulation/extension"},
}

PHYSICS_IMPORTS :: []string {
	"unified:sim",
	"unified:level",
	"unified:dmath",
	"unified:box3d",
	"base:intrinsics",
	"base:runtime",
	"core:math/bits",
	"core:sync",
}

SIM_IMPORTS :: []string {
	"unified:wire",
	"base:intrinsics",
	"base:runtime",
	"core:math/bits",
	"core:fmt",
	"core:strings",
	"core:os",
	"core:hash/xxhash",
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
	report :: proc(
		out: ^[dynamic]string,
		tok: tokenizer.Token,
		name, what: string,
		r: Rule,
		allocator: runtime.Allocator,
	) {
		where_ := fmt.tprintf("%s(%d:%d)", name, tok.pos.line, tok.pos.column)
		append(out, fmt.aprintf("%s: %s is banned in package %s", where_, what, r.pkg, allocator = allocator))
	}
	tz: tokenizer.Tokenizer
	tokenizer.init(&tz, src, name, proc(_: tokenizer.Pos, _: string, _: ..any) {})
	tz.flags = {.Insert_Semicolon} // a newline ends a statement: `x := 1.5` is caught, `x := 1.5 * y` is not
	after_import := false
	prev: [3]tokenizer.Token_Kind // the last significant tokens, prev[0] the latest
	pending: Maybe(tokenizer.Token) // an untyped float literal right after `:=`, if the statement ends there
	for tok := tokenizer.scan(&tz);; tok = tokenizer.scan(&tz) {
		if tok.kind == .Comment {
			continue
		}
		if f, ok := pending.?; ok {
			if tok.kind == .Semicolon || tok.kind == .EOF || tok.kind == .Close_Brace {
				report(&out, f, name, fmt.tprintf("`:= %s` (an untyped float literal is f64)", f.text), r, allocator)
			}
			pending = nil
		}
		if tok.kind == .EOF {
			break
		}
		#partial switch tok.kind {
		case .Import:
			after_import = true
			prev = {tok.kind, prev[0], prev[1]}
			continue
		case .Matrix:
			if r.ban_matrix {
				report(&out, tok, name, "`matrix`", r, allocator)
			}
		case .Foreign:
			if r.strict {
				report(&out, tok, name, "`foreign`", r, allocator)
			}
		case .Map:
			if r.strict {
				report(&out, tok, name, "`map` (unordered)", r, allocator)
			}
		case .Float:
			after_colon_eq := prev[0] == .Eq && prev[1] == .Colon
			signed := (prev[0] == .Sub || prev[0] == .Add) && prev[1] == .Eq && prev[2] == .Colon
			if r.strict && (after_colon_eq || signed) {
				pending = tok
			}
		case .Ident:
			if after_import {
				prev = {tok.kind, prev[0], prev[1]}
				continue // import alias
			}
			for b in r.ban_idents {
				if tok.text == b {
					report(&out, tok, name, fmt.tprintf("`%s`", b), r, allocator)
				}
			}
		case .String:
			if after_import {
				path := strings.trim(tok.text, "\"`")
				if banned_import(r, path) {
					report(&out, tok, name, fmt.tprintf("import %q", path), r, allocator)
				}
			}
		}
		after_import = false
		prev = {tok.kind, prev[0], prev[1]}
	}
	return out[:]
}

banned_import :: proc(r: Rule, path: string) -> bool {
	if r.only_imports != nil {
		p := path
		if strings.has_prefix(p, "../") {
			p = strings.concatenate({"unified:", p[3:]}, context.temp_allocator)
		}
		for ok in r.only_imports {
			if p == ok || (strings.has_suffix(ok, "/") && strings.has_prefix(path, ok)) {
				return false
			}
		}
		return true
	}
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

// Every .odin file under `dir`, subdirectories (sub-packages) included.
odin_files :: proc(dir: string, out: ^[dynamic]string) -> bool {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return false
	}
	for fi in infos {
		if fi.type == .Directory {
			odin_files(fi.fullpath, out)
		} else if strings.has_suffix(fi.name, ".odin") {
			append(out, fi.fullpath)
		}
	}
	return true
}

@(test)
library_follows_determinism_rules :: proc(t: ^testing.T) {
	for r in RULES {
		dir := rule_dir(r)
		files := make([dynamic]string, context.temp_allocator)
		if !testing.expectf(t, odin_files(dir, &files), "cannot list %s", dir) {
			continue
		}
		for path in files {
			data, rerr := os.read_entire_file(path, context.temp_allocator)
			if !testing.expectf(t, rerr == nil, "cannot read %s", path) {
				continue
			}
			for v in scan(r, path, string(data)) {
				testing.expect(t, false, v)
			}
		}
		testing.expectf(t, len(files) > 0, "no .odin files in %s", dir)
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
import "unified:sim"
// matrix f64 "core:math" map foreign x := 1.5 in a comment
s := "matrix f64 core:math"
z := intrinsics.sqrt(f32(2))
k := 0.5 / d2 // typed by d2
c: f32 = 1.5
D :: 1.5
`
	game_rule := RULES[0]
	testing.expect_value(t, len(scan(game_rule, "bad.odin", bad)), 6)
	for v in scan(game_rule, "clean.odin", clean) {
		testing.expect(t, false, v)
	}
}

// Escape hatches a reviewer found the old ban-list lint let through: each must be caught by the
// game rule, and the ones that don't need an import by the harness's rule too.
@(test)
lint_catches_escape_hatches :: proc(t: ^testing.T) {
	Case :: struct {
		src:    string,
		no_imp: bool, // caught without the import allowlist (checked against the sim rule too)
	}
	cases := []Case {
		{"import \"core:c/libc\"\nv := libc.sinf(x)\n", false},
		{"import \"core:simd\"\n", false},
		{"foreign import m \"system:m\"\n", true},
		{"f :: proc() {\n\tx := 1.5\n\ty := -2.0\n}\n", true},
		{"f :: proc(m: map[int]int) {\n\tfor k in m {}\n}\n", true},
		{"v: f64le\n", true},
		{"import \"unified:view\"\n", false},
		{"import \"base:runtime\"\ng := runtime.random_generator\n", true},
		{"import \"core:crypto\"\n", false},
		{"import \"core:sys/posix\"\n", false},
		{"c := intrinsics.read_cycle_counter()\n", true},
		{"import \"core:time\"\n", false},
	}
	sim_rule: Rule
	for r in RULES {
		if r.pkg == "sim" {
			sim_rule = r
		}
	}
	for c, i in cases {
		src := strings.concatenate({"package survivor\n", c.src}, context.temp_allocator)
		testing.expectf(
			t,
			len(scan(RULES[0], "case.odin", src)) > 0,
			"case %d not caught by the game rule:\n%s",
			i,
			c.src,
		)
		if c.no_imp || i == 11 {
			testing.expectf(
				t,
				len(scan(sim_rule, "case.odin", src)) > 0,
				"case %d not caught by the sim rule:\n%s",
				i,
				c.src,
			)
		}
	}
}
