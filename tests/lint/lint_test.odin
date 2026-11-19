// Determinism lint (AGENTS.md "Deterministic simulation") over unified's packages and its games, through
// unified:lint (src/lint/README.md), the way a game outside the repo lints its own. Every package of src/ has a
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

// The import graph: every package of src/ (src/<pkg>, subdirectories included), what it is (lint.Kind: the bans) and
// the unified packages it may import (a Tick package: everything it may import).
RULES := []Rule {
	// Library code inside a tick: the same rules as game code (lint.sim_rule).
	{pkg = "dmath", kind = .Tick, imports = TICK_IMPORTS},
	// physics wraps Box3D (the `box3d:` collection, unified-box3d's bindings: foreign code outside src/), carries the
	// caller's context through Box3D's C callbacks and walks RTTI (base:runtime), and serializes Box3D world creation
	// across threads with world_mutex (core:sync; b3CreateWorld), which no tick touches.
	{pkg = "physics", kind = .Tick, imports = PHYSICS_IMPORTS, allow_globals = {"world_mutex"}},
	// Levels: parsed when a World is created; plain data, through unified:wire; the Level keeps its allocator
	// (base:runtime).
	{pkg = "level", kind = .Tick, imports = {"unified:wire", "base:runtime", "base:intrinsics"}},
	// The harness: also walks RTTI, hashes and formats errors.
	{pkg = "sim", kind = .Tick, imports = SIM_IMPORTS, allow_fields = {"replaced"}}, // it fills and logs Inputs.replaced
	// Real-time code beside the sim: the encoding, the netcode (its clocks are fine), the EOS transport (its SDK
	// bindings need f64 fields and system: libraries), the headless library, modes and scenarios, the lint itself.
	{pkg = "wire", kind = .Realtime},
	{pkg = "netcode", kind = .Realtime, imports = {"unified:sim", "unified:wire"}},
	{pkg = "eos", kind = .Realtime, imports = {"unified:netcode", "system:"}},
	{pkg = "headless", kind = .Realtime, imports = {"unified:headless", "unified:sim", "unified:netcode"}},
	{pkg = "lint", kind = .Realtime},
	// Host side (Godot bindings and views, dev UI, the CLI): never feeds back into the sim. gdext's generated API imports
	// its gdi sub-package relatively; the CLI imports Odin's own only, so editing the rest of the library never
	// rebuilds it.
	{pkg = "gdext", kind = .Host, imports = {"unified:gdext/gdi", "gdi"}},
	{pkg = "devui", kind = .Host, imports = {"unified:gdext", "unified:gdext/gdi"}},
	{pkg = "godot", kind = .Host, imports = GODOT_IMPORTS},
	{pkg = "cli", kind = .Host},
}

PHYSICS_IMPORTS :: []string {
	"unified:sim",
	"unified:level",
	"unified:dmath",
	"box3d:bindings",
	"base:intrinsics",
	"base:runtime",
	"core:fmt", // create_static names the level shape Box3D refused
	"core:math/bits",
	"core:sync",
}

SIM_IMPORTS :: []string {
	"unified:dmath",
	"unified:wire",
	"base:intrinsics",
	"base:runtime",
	"core:math/bits",
	"core:fmt",
	"core:strings",
	"core:hash/xxhash",
}

GODOT_IMPORTS :: []string {
	"unified:sim",
	"unified:netcode",
	"unified:dmath",
	"unified:gdext",
	"unified:gdext/gdi",
	"unified:devui",
	"system:",
}

@(test)
library_follows_determinism_rules :: proc(t: ^testing.T) {
	for rule in RULES {
		rule := rule
		rule.dir = strings.concatenate({SRC_DIR, "/", rule.pkg}, context.temp_allocator)
		lint.check(t, rule)
	}
}

// Every game's simulation/ by its layout (lint.check_game): headless/, extension/, tests/ and its sim packages,
// exactly as a game outside the repo lints itself. (Its tests are in the one test compile: uni writes
// tests/games.gen.odin.)
@(test)
games_follow_determinism_rules :: proc(t: ^testing.T) {
	for game in game_dirs(t) {
		lint.check_game(t, fmt.tprintf("%s/%s/simulation", GAMES_DIR, game))
	}
}

// Box3D is physics' implementation (src/physics/README.md, The boundary): only src/physics and tests/physics import its
// bindings (box3d:), across the library, its tests and the games.
@(test)
only_physics_imports_box3d :: proc(t: ^testing.T) {
	ALLOWED :: []string{"src/physics", "tests/physics"}
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
				if strings.has_prefix(trimmed, "import") && strings.contains(trimmed, `"box3d:`) {
					testing.expectf(
						t,
						false,
						"%s imports Box3D's bindings (box3d:): Box3D is reached through unified:physics",
						relative,
					)
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
	infos, err := os.read_all_directory_by_path(SRC_DIR, context.temp_allocator)
	if !testing.expectf(t, err == nil, "cannot list %s: %v", SRC_DIR, err) {
		return
	}
	outer: for info in infos {
		if info.type != .Directory {
			continue
		}
		for rule in RULES {
			if rule.pkg == info.name {
				continue outer
			}
		}
		testing.expectf(t, false, "src/%s has no determinism rule in tests/lint/lint_test.odin", info.name)
	}
}

// The import matcher: an import a rule doesn't list fails, Odin's own don't (but in a Tick package), a Realtime
// package's core:math ban holds beside them (core:math/bits is fine), a collection prefix and an aliased import match.
@(test)
lint_catches_unlisted_imports :: proc(t: ^testing.T) {
	Case :: struct {
		rule:   Rule,
		src:    string,
		caught: bool,
	}
	host := Rule {
		pkg     = "host",
		kind    = .Host,
		imports = {"unified:godot", "system:"},
	}
	realtime := Rule {
		pkg     = "realtime",
		kind    = .Realtime,
		imports = {"unified:sim"},
	}
	cases := []Case {
		{host, `import "unified:sim"`, true},
		{host, `import "vendor:darwin/AppKit"`, true},
		{host, `import "core:math"`, false},
		{host, `import v "unified:godot"`, false},
		{host, `foreign import kernel32 "system:Kernel32.lib"`, false},
		{realtime, `import "core:math"`, true},
		{realtime, `import "core:math/linalg"`, true},
		{realtime, `import "core:math/bits"`, false},
		{realtime, `import "core:time"`, false},
		{lint.sim_rule("tick", ""), `import "core:time"`, true},
	}
	for test_case in cases {
		src := fmt.tprintf("package %s\n%s\n", test_case.rule.pkg, test_case.src)
		found := len(lint.scan(test_case.rule, "case.odin", src)) > 0
		testing.expectf(
			t,
			found == test_case.caught,
			"%s: %s: %s",
			test_case.rule.pkg,
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
lo := dmath.min(a, b) + m.max(c, d) + dmath.clamp(x, 0, 1) // dmath's, under any import name
top := max(u16) + min(i32) // a type's bound
bounds.max = cell.min // fields named like the builtins
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
		{"import \"unified:godot\"\n", false},
		{"import \"base:runtime\"\ng := runtime.random_generator\n", true},
		{"import \"core:crypto\"\n", false},
		{"import \"core:sys/posix\"\n", false},
		{"c := intrinsics.read_cycle_counter()\n", true},
		{"import \"core:time\"\n", false},
		{"f :: proc() {\n\t@(static) hits: int\n}\n", true}, // state outside the block
		{"f :: proc() {\n\t@(thread_local) hits: int\n}\n", true},
		{"f :: proc() {\n\tv: [4]f32 = ---\n}\n", true}, // uninitialised: differs per run
		{"when ODIN_OS == .Windows {\n\tK :: 1\n}\n", true}, // a sim per platform or build
		{"f :: proc() -> bool {\n\treturn ODIN_ARCH == .arm64\n}\n", true},
		{"when ODIN_DEBUG {\n\tK :: 1\n}\n", true},
		{"FAST :: #config(FAST, false)\n", true},
		{"import \"base:intrinsics\"\n", false}, // a game lists the low-level imports it uses
		{"import \"core:math/bits\"\n", false},
		{"import \"unified:wire\"\n", false},
		{"f :: proc(x: f32) -> f32 {\n\treturn max(x, 0)\n}\n", true}, // -0 against +0: dmath.max
		{"f :: proc(x: f32) -> f32 {\n\treturn min(\n\t\tx,\n\t\tg(1, 2),\n\t)\n}\n", true},
		{"f :: proc(x: f32) -> f32 {\n\treturn clamp(x, -1, 1)\n}\n", true},
		{"f :: proc(t: ^Tick) -> bool {\n\treturn t.inputs.replaced != {}\n}\n", false}, // differs per peer
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
		if test_case.no_imp {
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
// lint.BOX3D (lint.check_game), which bans the bindings' collection.
@(test)
lint_bans_box3d_outside_physics :: proc(t: ^testing.T) {
	rule := Rule {
		pkg     = "extension",
		kind    = .Host,
		imports = lint.GAME_IMPORTS,
		bans    = lint.BOX3D,
	}
	found := lint.scan(rule, "case.odin", "package extension\nimport box3d \"box3d:bindings\"\n")
	testing.expectf(t, len(found) == 1, "an import of Box3D's bindings is not caught: %v", found)
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

// A game's export leaves out the tool scripts: its own (game/tools) and the library's (the
// addons/unified mirror). Every preset's exclude_filter names them (Godot reads the filters per preset).
@(test)
game_exports_leave_out_the_tools :: proc(t: ^testing.T) {
	for game in game_dirs(t) {
		presets, err := os.read_entire_file(
			fmt.tprintf("%s/%s/export_presets.cfg", GAMES_DIR, game),
			context.temp_allocator,
		)
		if err != nil do continue // no export
		tools := []string{"game/tools/*", "addons/unified/*"}
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
