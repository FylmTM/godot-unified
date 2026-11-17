// Determinism lint (AGENTS.md "Deterministic simulation") over unified's packages and its games, through
// unified:lint (src/lint/SPEC.md), the way a game outside the repo lints its own. Every package of src/ has a
// rule here (the import graph); each game's simulation/ is linted by its layout (lint.check_game).
package test_lint

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
		pkg          = "dmath",
		only_imports = TICK_IMPORTS,
		ban_idents   = SIM_IDENTS,
		ban_matrix   = true,
		strict       = true,
		tick         = true,
	},
	// physics walks RTTI (base:runtime) and guards Box3D world creation with a mutex (core:sync).
	// world_mutex serializes Box3D world creation across threads (b3CreateWorld); never touched by a tick.
	{
		pkg           = "physics",
		only_imports  = PHYSICS_IMPORTS,
		ban_idents    = SIM_IDENTS,
		ban_matrix    = true,
		strict        = true,
		tick          = true,
		allow_globals = {"world_mutex"},
	},
	// Levels: parsed when a World is created; plain data, through unified:wire.
	{
		pkg          = "level",
		only_imports = {"unified:wire"},
		ban_idents   = SIM_IDENTS,
		ban_matrix   = true,
		strict       = true,
		tick         = true,
	},
	// The harness: also walks RTTI, hashes and formats errors.
	{
		pkg          = "sim",
		only_imports = SIM_IMPORTS,
		ban_idents   = SIM_IDENTS,
		ban_matrix   = true,
		strict       = true,
		tick         = true,
	},
	// The Box3D API (src/b3/SPEC.md): conversions over the library's bindings, called inside a tick, so tick rules.
	// base:runtime carries the caller's context through the library's C callbacks. The `box3d:` collection itself
	// (unified-box3d's bindings) is foreign code, outside src/, like the old C binding was.
	{
		pkg          = "b3",
		only_imports = {"box3d:bindings", "base:runtime"},
		ban_idents   = SIM_IDENTS,
		ban_matrix   = true,
		strict       = true,
		tick         = true,
	},
	// The rest: the unified packages each may import, listed (the graph), plus Odin's own (core:, base:; system: for
	// a foreign import). Real-time packages also stay off core:math.
	{
		pkg           = "wire",
		only_imports  = {"core:", "base:"},
		ban_imports   = MATH,
		allow_imports = MATH_OK,
		ban_idents    = FLOAT_TRAPS,
		ban_matrix    = true,
	},
	// Netcode feeds inputs into the sim and owns real-time clocks (fine), but stays off core:math.
	{
		pkg           = "netcode",
		only_imports  = {"unified:sim", "unified:wire", "core:", "base:"},
		ban_imports   = MATH,
		allow_imports = MATH_OK,
		ban_idents    = FLOAT_TRAPS,
		ban_matrix    = true,
	},
	// Host side (Godot bindings, view, dev UI): never feeds back into the sim, so no bans beyond the graph.
	// gdext: its generated API imports its gdi sub-package relatively.
	{pkg = "gdext", only_imports = {"unified:gdext/gdi", "gdi", "core:", "base:"}},
	{pkg = "view", only_imports = {"core:", "base:"}},
	{pkg = "devui", only_imports = {"unified:gdext", "unified:gdext/gdi", "core:", "base:"}},
	{
		pkg          = "godot",
		only_imports = {
			"unified:sim",
			"unified:netcode",
			"unified:view",
			"unified:dmath",
			"unified:gdext",
			"unified:gdext/gdi",
			"unified:devui",
			"core:",
			"base:",
			"system:",
		},
	},
	// EOS as a godot.Transport: imports eos and godot, so neither imports the other.
	{pkg = "godot_eos", only_imports = {"unified:eos", "unified:godot", "unified:netcode", "core:", "base:"}},
	// The determinism lint itself: test-side code (core:testing, the tokenizer), never inside a tick.
	{
		pkg           = "lint",
		only_imports  = {"core:", "base:"},
		ban_imports   = MATH,
		allow_imports = MATH_OK,
		ban_idents    = FLOAT_TRAPS,
		ban_matrix    = true,
	},
	// EOS transport (real-time, like netcode): the SDK bindings need f64 fields, nothing else.
	{
		pkg           = "eos",
		only_imports  = {"unified:netcode", "core:", "base:", "system:"},
		ban_imports   = MATH,
		allow_imports = MATH_OK,
		ban_idents    = FLOAT_TRAPS,
		ban_matrix    = true,
	},
	// The headless binary's library, its modes and the scenario suites (subdirectories).
	{
		pkg           = "headless",
		only_imports  = {"unified:headless", "unified:sim", "unified:netcode", "core:", "base:"},
		ban_imports   = MATH,
		allow_imports = MATH_OK,
		ban_idents    = FLOAT_TRAPS,
		ban_matrix    = true,
	},
	// The CLI library (src/cli/SPEC.md): Odin's own only, so editing the rest of the library never rebuilds the CLI.
	{pkg = "cli", only_imports = {"core:", "base:"}},
}

PHYSICS_IMPORTS :: []string {
	"unified:sim",
	"unified:level",
	"unified:dmath",
	"unified:b3",
	"base:intrinsics",
	"base:runtime",
	"core:fmt", // create_static names the level shape Box3D refused
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
	"core:hash/xxhash",
}

rule_dir :: proc(rule: Rule) -> string {
	if rule.dir != "" {
		return strings.concatenate({SRC_DIR, "/../", rule.dir}, context.temp_allocator)
	}
	return strings.concatenate({SRC_DIR, "/", rule.pkg}, context.temp_allocator)
}

@(test)
library_follows_determinism_rules :: proc(t: ^testing.T) {
	for rule in RULES {
		rule := rule
		rule.dir = rule_dir(rule)
		lint.check(t, rule)
	}
}

// Every game's simulation/ by its layout (lint.check_game): headless/, extension/, tests/ and its sim packages,
// exactly as a game outside the repo lints itself. Its tests must be part of the one test compile.
@(test)
games_follow_determinism_rules :: proc(t: ^testing.T) {
	root, _ := os.read_entire_file(SRC_DIR + "/../tests/tests.odin", context.temp_allocator)
	for game in game_dirs(t) {
		lint.check_game(t, fmt.tprintf("%s/%s/simulation", GAMES_DIR, game))
		imp := fmt.tprintf("\"../games/%s/simulation/tests\"", game)
		testing.expectf(t, strings.contains(string(root), imp), "tests/tests.odin does not import %s", imp)
	}
}

// Box3D is physics' implementation (src/physics/SPEC.md, The boundary): only src/physics and tests/b3 import
// unified:b3 (and the physics bench, which reads Box3D's own counters), and only src/b3 and tests/b3 the bindings
// (box3d:), across the library, its tests and the games.
@(test)
only_physics_imports_b3 :: proc(t: ^testing.T) {
	ALLOWED :: []string{"src/physics", "src/b3", "tests/b3", "tests/physics/bench"}
	clean, _ := filepath.clean(SRC_DIR + "/..", context.temp_allocator)
	root, _ := strings.replace_all(clean, "\\", "/", context.temp_allocator)
	for top in ([]string{"src", "tests", "games"}) {
		files := make([dynamic]string, context.temp_allocator)
		collect_odin(fmt.tprintf("%s/%s", root, top), &files)
		file_loop: for path in files {
			normalized, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
			relative := strings.trim_prefix(strings.trim_prefix(normalized, root), "/")
			for allowed in ALLOWED {
				if strings.has_prefix(relative, allowed) && strings.has_prefix(relative[len(allowed):], "/") do continue file_loop
			}
			data, _ := os.read_entire_file(path, context.temp_allocator)
			text := string(data)
			for line in strings.split_lines_iterator(&text) {
				trimmed := strings.trim_space(line)
				if strings.has_prefix(trimmed, "import") && strings.contains(trimmed, `"unified:b3"`) {
					testing.expectf(
						t,
						false,
						"%s imports unified:b3 (Box3D is reached through unified:physics)",
						relative,
					)
				}
				bindings_ok := strings.has_prefix(relative, "src/b3/") || strings.has_prefix(relative, "tests/b3/")
				if !bindings_ok && strings.has_prefix(trimmed, "import") && strings.contains(trimmed, `"box3d:`) {
					testing.expectf(t, false, "%s imports Box3D's bindings (box3d:)", relative)
				}
			}
		}
	}
}

@(private)
collect_odin :: proc(dir: string, out: ^[dynamic]string) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for info in infos {
		if info.type == .Directory {
			if info.name == ".out" || info.name == ".godot" do continue
			collect_odin(info.fullpath, out)
		} else if strings.has_suffix(info.name, ".odin") {
			append(out, info.fullpath)
		}
	}
}

game_dirs :: proc(t: ^testing.T) -> []string {
	infos, err := os.read_all_directory_by_path(GAMES_DIR, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot list %s: %v", GAMES_DIR, err)
	out := make([dynamic]string, context.temp_allocator)
	for info in infos {
		if info.type == .Directory && os.exists(fmt.tprintf("%s/simulation", info.fullpath)) do append(&out, info.name)
	}
	testing.expect(t, len(out) > 0, "no games under games/")
	return out[:]
}

// Every library package has a rule with an import allowlist (the graph), so a new one can't skip the lint (games:
// by layout, above).
@(test)
every_package_has_a_rule :: proc(t: ^testing.T) {
	for rule in RULES {
		testing.expectf(
			t,
			rule.only_imports != nil,
			"src/%s's rule has no only_imports: the graph must name its imports",
			rule.pkg,
		)
	}
	infos, err := os.read_all_directory_by_path(SRC_DIR, context.temp_allocator)
	if !testing.expectf(t, err == nil, "cannot list %s: %v", SRC_DIR, err) {
		return
	}
	outer: for info in infos {
		if info.type != .Directory {
			continue
		}
		for rule in RULES {
			if rule.dir == "" && rule.pkg == info.name {
				continue outer
			}
		}
		testing.expectf(t, false, "src/%s has no determinism rule in tests/lint/lint_test.odin", info.name)
	}
}

// The graph holds for host-side packages too: an import their rule doesn't list fails, Odin's own packages don't,
// and a real-time package's core:math ban still applies beside its allowlist.
@(test)
lint_catches_forbidden_host_imports :: proc(t: ^testing.T) {
	rule_of :: proc(pkg: string) -> Rule {
		for rule in RULES {
			if rule.pkg == pkg do return rule
		}
		return {}
	}
	Case :: struct {
		pkg, src: string,
		caught:   bool,
	}
	cases := []Case {
		{"view", `import "unified:gdext"`, true}, // the view layer stays independent of the bindings
		{"netcode", `import "unified:godot"`, true}, // the netcode never reaches the host
		{"gdext", `import "unified:view"`, true},
		{"devui", `import "unified:sim"`, true},
		{"eos", `import "unified:godot"`, true},
		{"cli", `import "unified:sim"`, true}, // the CLI imports Odin's packages only
		{"cli", `import "vendor:darwin/AppKit"`, true},
		{"godot", `import "unified:eos"`, true}, // godot_eos joins them; neither imports the other
		{"netcode", `import "core:math"`, true}, // the ban beside the allowlist
		{"netcode", `import "core:math/bits"`, false},
		{"view", `import "core:math"`, false}, // host side: no ban
		{"godot", `import "unified:view"`, false},
		{"godot", `foreign import kernel32 "system:Kernel32.lib"`, false},
		{"devui", `import gd "unified:gdext"`, false},
	}
	for test_case in cases {
		src := fmt.tprintf("package %s\n%s\n", test_case.pkg, test_case.src)
		found := len(lint.scan(rule_of(test_case.pkg), "case.odin", src)) > 0
		testing.expectf(
			t,
			found == test_case.caught,
			"%s: %s: %s",
			test_case.pkg,
			test_case.src,
			test_case.caught ? "not caught" : "caught, but allowed",
		)
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
	// the low-level imports a game lists to use (lint.GAME_TICK_IMPORTS)
	listed := lint.sim_rule("survivor", "", {"core:math/bits", "base:intrinsics"})
	for violation in lint.scan(listed, "clean.odin", clean) {
		testing.expect(t, false, violation)
	}
	testing.expect_value(t, len(lint.scan(game_rule, "clean.odin", clean)), 2)

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
		for violation in found {
			hit ||= strings.contains(violation, fmt.tprintf("`%s`", want))
		}
		testing.expectf(t, hit, "package-level variable %s not caught", want)
	}
	for violation in lint.scan_globals(game_rule, "clean_globals.odin", clean_globals) {
		testing.expect(t, false, violation)
	}
	physics_rule: Rule
	for rule in RULES {
		if rule.pkg == "physics" {
			physics_rule = rule
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
		{"f :: proc() {\n\t@(static) hits: int\n}\n", false}, // state outside the block (sim keeps a schema cache)
		{"f :: proc() {\n\t@(thread_local) hits: int\n}\n", true},
		{"f :: proc() {\n\tv: [4]f32 = ---\n}\n", true}, // uninitialised: differs per run
		{"when ODIN_OS == .Windows {\n\tK :: 1\n}\n", true}, // a sim per platform or build
		{"f :: proc() -> bool {\n\treturn ODIN_ARCH == .arm64\n}\n", true},
		{"when ODIN_DEBUG {\n\tK :: 1\n}\n", true},
		{"FAST :: #config(FAST, false)\n", true},
		{"import \"base:intrinsics\"\n", false}, // a game lists the low-level imports it uses
		{"import \"core:math/bits\"\n", false},
		{"import \"unified:wire\"\n", false},
	}
	game_rule := lint.sim_rule("survivor", "")
	sim_rule: Rule
	for rule in RULES {
		if rule.pkg == "sim" {
			sim_rule = rule
		}
	}
	for test_case, i in cases {
		src := strings.concatenate({"package survivor\n", test_case.src}, context.temp_allocator)
		testing.expectf(
			t,
			len(lint.scan(game_rule, "case.odin", src)) > 0,
			"case %d not caught by the game rule:\n%s",
			i,
			test_case.src,
		)
		if test_case.no_imp || i == 11 {
			testing.expectf(
				t,
				len(lint.scan(sim_rule, "case.odin", src)) > 0,
				"case %d not caught by the sim rule:\n%s",
				i,
				test_case.src,
			)
		}
	}
}

// Box3D is reached through unified:physics only: a game's headless, extension and tests packages are linted with
// lint.BOX3D (lint.check_game), which bans the bindings' collection too.
@(test)
lint_bans_box3d_outside_physics :: proc(t: ^testing.T) {
	rule := Rule {
		pkg         = "extension",
		ban_imports = lint.BOX3D,
	}
	for src in ([]string{"import \"unified:b3\"\n", "import \"box3d:bindings\"\n"}) {
		found := lint.scan(rule, "case.odin", fmt.tprintf("package extension\n%s", src))
		testing.expectf(t, len(found) == 1, "not caught: %s", src)
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

// A game's export leaves out the tool scripts: its own (game/tools), the shared kit's and the library's (the
// addons/unified mirror). Every preset's exclude_filter names them (Godot reads the filters per preset).
@(test)
game_exports_leave_out_the_tools :: proc(t: ^testing.T) {
	for game in game_dirs(t) {
		presets, err := os.read_entire_file(
			fmt.tprintf("%s/%s/export_presets.cfg", GAMES_DIR, game),
			context.temp_allocator,
		)
		if err != nil do continue // no export
		project, _ := os.read_entire_file(fmt.tprintf("%s/%s/project.godot", GAMES_DIR, game), context.temp_allocator)
		tools := []string{"game/tools/*", "addons/unified/*", "addons/shared/tools/*"}
		if !strings.contains(string(project), "res://addons/shared/") do tools = tools[:2]
		filters := 0
		text := string(presets)
		for line in strings.split_lines_iterator(&text) {
			if !strings.has_prefix(line, "exclude_filter=") do continue
			filters += 1
			for tool in tools {
				testing.expectf(
					t,
					strings.contains(line, tool),
					"%s: an export preset ships %s (%s)",
					game,
					tool,
					line,
				)
			}
		}
		testing.expectf(t, filters > 0, "%s: export_presets.cfg has no exclude_filter", game)
	}
}
