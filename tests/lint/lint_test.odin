// Determinism lint (AGENTS.md "Deterministic simulation") over unified's packages and its games, through
// unified:lint (src/lint/SPEC.md), the way a game outside the repo lints its own. Every package of src/ has a
// rule here (the import graph); each game's simulation/ is linted by its layout (lint.check_game).
package test_lint

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "unified:lint"

SRC_DIR :: #directory + "/../../src"
GAMES_DIR :: #directory + "/../../games"

Rule :: lint.Rule
TICK_IMPORTS :: lint.TICK_IMPORTS
SIM_IDENTS :: lint.SIM_IDENTS
FLOAT_TRAPS :: lint.FLOAT_TRAPS
MATH :: lint.MATH
MATH_OK :: lint.MATH_OK

// `dir` "": src/<pkg>; else relative to the repo root (subdirectories included).
RULES := []Rule {
	// Library code that runs inside a tick: the same rules as game code (lint.sim_rule).
	{
		pkg = "dmath",
		only_imports = TICK_IMPORTS,
		ban_idents = SIM_IDENTS,
		ban_matrix = true,
		strict = true,
		tick = true,
	},
	// physics walks RTTI (base:runtime) and guards Box3D world creation with a mutex (core:sync).
	// world_mutex serializes Box3D world creation across threads (b3CreateWorld); never touched by a tick.
	{
		pkg = "physics",
		only_imports = PHYSICS_IMPORTS,
		ban_idents = SIM_IDENTS,
		ban_matrix = true,
		strict = true,
		tick = true,
		allow_globals = {"world_mutex"},
	},
	// Levels: parsed when a World is created; plain data, through unified:wire.
	{
		pkg = "level",
		only_imports = {"unified:wire"},
		ban_idents = SIM_IDENTS,
		ban_matrix = true,
		strict = true,
		tick = true,
	},
	// The harness: also walks RTTI, hashes, formats errors and reads and writes log files.
	{pkg = "sim", only_imports = SIM_IMPORTS, ban_idents = SIM_IDENTS, ban_matrix = true, strict = true, tick = true},
	// The Box3D API (src/b3/SPEC.md): conversions over the library's bindings, called inside a tick, so tick rules.
	// base:runtime carries the caller's context through the library's C callbacks. The `box3d:` collection itself
	// (unified-box3d's bindings) is foreign code, outside src/, like the old C binding was.
	{
		pkg = "b3",
		only_imports = {"box3d:bindings", "base:runtime"},
		ban_idents = SIM_IDENTS,
		ban_matrix = true,
		strict = true,
		tick = true,
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
	{pkg = "devui_controls"}, // spike: the dev UI on Godot controls
	{pkg = "godot_host"},
	// The determinism lint itself: test-side code (core:testing, the tokenizer), never inside a tick.
	{pkg = "lint", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	// EOS transport (real-time, like netcode): the SDK bindings need f64 fields, nothing else.
	{pkg = "eos", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	{pkg = "headless", ban_imports = MATH, allow_imports = MATH_OK, ban_idents = FLOAT_TRAPS, ban_matrix = true},
	// The CLI library (src/cli/SPEC.md): core: only, so editing the rest of the library never rebuilds the CLI.
	{pkg = "cli", ban_imports = {"unified:", "vendor:"}},
}

PHYSICS_IMPORTS :: []string {
	"unified:sim",
	"unified:level",
	"unified:dmath",
	"unified:b3",
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

@(test)
library_follows_determinism_rules :: proc(t: ^testing.T) {
	for r in RULES {
		r := r
		r.dir = rule_dir(r)
		lint.check(t, r)
	}
}

// Every game's simulation/ by its layout (lint.check_game): headless/, extension/, tests/ and its sim packages,
// exactly as a game outside the repo lints itself. Its tests must be part of the one test compile.
@(test)
games_follow_determinism_rules :: proc(t: ^testing.T) {
	root, _ := os.read_entire_file(SRC_DIR + "/../tests/tests.odin", context.temp_allocator)
	for g in game_dirs(t) {
		lint.check_game(t, fmt.tprintf("%s/%s/simulation", GAMES_DIR, g))
		imp := fmt.tprintf("\"../games/%s/simulation/tests\"", g)
		testing.expectf(t, strings.contains(string(root), imp), "tests/tests.odin does not import %s", imp)
	}
}

game_dirs :: proc(t: ^testing.T) -> []string {
	infos, err := os.read_all_directory_by_path(GAMES_DIR, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot list %s: %v", GAMES_DIR, err)
	out := make([dynamic]string, context.temp_allocator)
	for fi in infos {
		if fi.type == .Directory && os.exists(fmt.tprintf("%s/simulation", fi.fullpath)) do append(&out, fi.name)
	}
	testing.expect(t, len(out) > 0, "no games under games/")
	return out[:]
}

// Every library package has a rule, so a new one can't skip the lint (games: by layout, above).
@(test)
every_package_has_a_rule :: proc(t: ^testing.T) {
	infos, err := os.read_all_directory_by_path(SRC_DIR, context.temp_allocator)
	if !testing.expectf(t, err == nil, "cannot list %s: %v", SRC_DIR, err) {
		return
	}
	outer: for fi in infos {
		if fi.type != .Directory {
			continue
		}
		for r in RULES {
			if r.dir == "" && r.pkg == fi.name {
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
	game_rule := lint.sim_rule("survivor", "")
	testing.expect_value(t, len(lint.scan(game_rule, "bad.odin", bad)), 6)
	for v in lint.scan(game_rule, "clean.odin", clean) {
		testing.expect(t, false, v)
	}

	// Package-level variables in tick code: each mutable one is caught, by name.
	bad_globals := `package survivor
counter := 0
a, b: f32
when ODIN_DEBUG {
	debug_hits: int
} else {
	hits: [4]i32 = {1, 2, 3, 4}
}
@(private)
P := [2]f32{0, 1}
world_mutex: int
`
	clean_globals := `package survivor
#+private
@(rodata)
TABLE := [2]f32{0, 1}
@(private, rodata)
NAMES := [2]string{"a", "b"}
@rodata
SPEC := Spec {
	speed = 2,
}
K :: 3
DT: f32 : 1.0 / 64
F :: proc(x: int) -> int {
	y := x
	v: f32 = 2
	return y
}
S :: struct {
	field: int,
}
when ODIN_DEBUG {
	D :: 1
}
`
	found := lint.scan_globals(game_rule, "globals.odin", bad_globals)
	testing.expect_value(t, len(found), 7)
	for want in ([]string{"counter", "a", "b", "debug_hits", "hits", "P", "world_mutex"}) { 	// world_mutex: allowed in physics only
		hit := false
		for v in found {
			hit ||= strings.contains(v, fmt.tprintf("`%s`", want))
		}
		testing.expectf(t, hit, "package-level variable %s not caught", want)
	}
	for v in lint.scan_globals(game_rule, "clean_globals.odin", clean_globals) {
		testing.expect(t, false, v)
	}
	physics_rule: Rule
	for r in RULES {
		if r.pkg == "physics" {
			physics_rule = r
		}
	}
	testing.expect_value(
		t,
		len(lint.scan_globals(physics_rule, "globals.odin", "package physics\nworld_mutex: int\n")),
		0,
	)
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
	game_rule := lint.sim_rule("survivor", "")
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
			len(lint.scan(game_rule, "case.odin", src)) > 0,
			"case %d not caught by the game rule:\n%s",
			i,
			c.src,
		)
		if c.no_imp || i == 11 {
			testing.expectf(
				t,
				len(lint.scan(sim_rule, "case.odin", src)) > 0,
				"case %d not caught by the sim rule:\n%s",
				i,
				c.src,
			)
		}
	}
}

// A game's own deterministic packages: banned by the sim rule until listed in extra_imports.
@(test)
lint_sim_rule_extra_imports :: proc(t: ^testing.T) {
	src := "package mygame\nimport \"../grid\"\nimport \"../ai/paths\"\nimport \"unified:sim\"\n"
	testing.expect_value(t, len(lint.scan(lint.sim_rule("mygame", ""), "a.odin", src)), 2)
	testing.expect_value(t, len(lint.scan(lint.sim_rule("mygame", "", {"../grid", "../ai/"}), "a.odin", src)), 0)
	// A relative import is the game's own package even when it shares a unified package's name.
	own := "package mygame\nimport \"../sim\"\nimport \"../physics\"\n"
	testing.expect_value(t, len(lint.scan(lint.sim_rule("mygame", ""), "b.odin", own)), 2)
	testing.expect_value(t, len(lint.scan(lint.sim_rule("mygame", "", {"../sim", "../physics"}), "b.odin", own)), 0)
}
