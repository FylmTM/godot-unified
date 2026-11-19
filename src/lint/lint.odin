// The determinism lint (AGENTS.md "Deterministic simulation"): a token scan that fails on constructs a
// simulation must not use. Cheap (a few ms), run from a test package: `tests/lint` runs it over unified and its
// games, and a game outside the repo calls `check_game` from its own sim tests. It can't prove determinism
// (end-to-end suites and reference runs do); it stops the known traps from creeping in (src/lint/README.md).
package lint

import "base:runtime"
import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// What a package is, which says what it may not do:
//
//   Tick      code inside a tick: only its listed imports, none of SIM_IDENTS, no call of BUILTIN_CALLS with two or
//             more arguments (dmath's instead), no field of SIM_FIELDS but its allow_fields, no `matrix`, `foreign`,
//             `map`, `---`, `#config` or `x := 1.5` (an untyped float literal is f64), and no mutable package-level
//             variables (scan_globals) but its allow_globals.
//   Realtime  real-time code beside the sim (netcode, headless): Odin's own packages and its listed ones, but not
//             core:math (core:math/bits is fine), FLOAT_TRAPS or `matrix`.
//   Host      host-side code that never feeds back into the sim: Odin's own packages and its listed ones.
Kind :: enum u8 {
	Host,
	Realtime,
	Tick,
}

// What one package may import and use: its kind's bans (Kind) plus its own lists. check lints a package by it;
// sim_rule makes a game's.
Rule :: struct {
	pkg:           string, // the package's name, for messages (and the tests' rule table)
	dir:           string, // the package's directory (subdirectories included); see `check`
	kind:          Kind,
	// The imports allowed, as written ("a/" allows a/*, "c:" all of collection c): a Tick package's only ones; the
	// others may also import Odin's own (core:, base:).
	imports:       []string,
	bans:          []string, // imports banned besides the kind's, each with what is under it ("c:": all of c)
	allow_globals: []string, // package-level variables a Tick package may keep: each needs a reason where listed
	allow_fields:  []string, // SIM_FIELDS a Tick package may read (the harness that fills them): a reason where listed
	allow_config:  []string, // the `#config` names a Tick package may read (sim.DEV): a reason where listed
}

// What a Realtime package may not name: fused or complex arithmetic. (core:math, banned there too, pulls in
// transcendentals and FMA-friendly code; only the integer helpers of core:math/bits are allowed. `matrix` types
// multiply with fused operations.)
@(private)
FLOAT_TRAPS :: []string {
	"fused_mul_add",
	"quaternion64",
	"quaternion128",
	"quaternion256",
	"complex32",
	"complex64",
	"complex128",
}

// The identifiers a tick may not name: f32 only (no f64 or f16 types, no fused, quaternion or complex arithmetic), no
// cycle counters or random generators (clocks and files are out of reach: a tick imports neither), no
// state outside the block (`@(static)` and `@(thread_local)` variables: not rolled back, not hashed) and no code that
// differs per platform or build (ODIN_OS, ODIN_ARCH, ODIN_DEBUG: peers would run different sims).
@(private)
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
	"static",
	"thread_local",
	"ODIN_OS",
	"ODIN_ARCH",
	"ODIN_DEBUG",
}

// The builtins a tick may not call with two or more arguments: on floats they lower to instructions free to return
// either zero when -0 meets +0, and x64 and arm64, debug and release builds, even two inlined calls of one build pick
// differently. dmath has compare-and-select ones of the same names (dmath.min, dmath.max, dmath.clamp), for integers
// too: the lint can't see types. One argument, a type's bound (`max(u16)`), is a constant and allowed.
@(private)
BUILTIN_CALLS :: []string{"min", "max", "clamp"}

// The fields a tick may not read (`x.name`): they differ between peers computing the same tick. `replaced`
// (sim.Inputs): the relay substituted a late input; a peer that predicted it right steps the tick without it, a
// peer catching up or replaying the log with it. `dev` (sim.Tick, sim.Zone_Scope): the debug draws and zone clock
// one machine's host attached.
@(private)
SIM_FIELDS :: []string{"replaced", "dev"}

// What library code inside a tick may import: the deterministic packages and the integer bit helpers. Not Box3D's
// bindings: Box3D is physics' (src/physics/README.md, The boundary).
TICK_IMPORTS :: []string {
	"unified:sim",
	"unified:physics",
	"unified:level",
	"unified:nav",
	"unified:dmath",
	"unified:wire",
	"base:intrinsics",
	"core:math/bits",
}

// What a game's code inside a tick may import without listing it: TICK_IMPORTS but the encoding (unified:wire) and the
// low-level helpers (base:intrinsics, whose SIMD, atomics and syscalls the identifier bans don't name; core:math/bits).
// A game that needs one lists it in extra_imports.
GAME_TICK_IMPORTS :: []string{"unified:sim", "unified:physics", "unified:level", "unified:nav", "unified:dmath"}

// The rule for a game's simulation package (the code inside its tick): a Tick package importing only
// GAME_TICK_IMPORTS plus `extra_imports` (the game's own deterministic packages as its code imports them, e.g.
// "../grid"; "a/" allows a/*).
sim_rule :: proc(pkg, dir: string, extra_imports: []string = nil, allocator := context.temp_allocator) -> Rule {
	imports := make([]string, len(GAME_TICK_IMPORTS) + len(extra_imports), allocator)
	copy(imports, GAME_TICK_IMPORTS)
	copy(imports[len(GAME_TICK_IMPORTS):], extra_imports)
	return {pkg = pkg, dir = dir, kind = .Tick, imports = imports}
}

// The lists as variables: a constant slice in a returned Bans would point at the stack.
@(private)
sim_idents := SIM_IDENTS
@(private)
float_traps := FLOAT_TRAPS
@(private)
builtin_calls := BUILTIN_CALLS
@(private)
sim_fields := SIM_FIELDS

// What a rule bans, from its kind.
@(private)
Bans :: struct {
	idents:       []string,
	calls:        []string, // builtins not to call with two or more arguments
	fields:       []string, // fields not to read (`x.name`)
	math:         bool, // core:math (but core:math/bits)
	strict:       bool, // `foreign`, `map`, `---`, `#config`, `x := 1.5`; package-level variables
	odin_allowed: bool, // core: and base: besides the listed imports
	matrices:     bool,
}

@(private)
bans_of :: proc(kind: Kind) -> Bans {
	switch kind {
	case .Tick:
		return {idents = sim_idents, calls = builtin_calls, fields = sim_fields, strict = true, matrices = true}
	case .Realtime:
		return {idents = float_traps, math = true, odin_allowed = true, matrices = true}
	case .Host:
		return {odin_allowed = true}
	}
	return {}
}


// Lints a game's `simulation/` directory by its layout: `headless/` (the headless binary: real-time code, off
// core:math, no float traps), `extension/` (the GDExtension: host side) and `tests/` (test code) are known, and none
// of them imports Box3D's bindings (box3d:); every other directory is one of the game's sim packages, linted under `sim_rule`
// with `extra_imports`. So a new sim package can't skip the lint. Returns the sim packages' directories.
check_game :: proc(
	t: ^testing.T,
	simulation_dir: string,
	extra_imports: []string = nil,
	loc := #caller_location,
) -> (
	sims: []string,
) {
	infos, err := os.read_all_directory_by_path(simulation_dir, context.temp_allocator)
	if !testing.expectf(t, err == nil, "lint: cannot list %s", simulation_dir, loc = loc) {
		return
	}
	out := make([dynamic]string, context.temp_allocator)
	for info in infos {
		if info.type != .Directory do continue
		switch info.name {
		case "headless":
			check(
				t,
				{pkg = "headless", dir = info.fullpath, kind = .Realtime, imports = GAME_IMPORTS, bans = BOX3D},
				loc,
			)
		case "extension", "tests":
			// host side and test code: nothing inside a tick, but Box3D only through physics as everywhere in a game
			check(t, {pkg = info.name, dir = info.fullpath, kind = .Host, imports = GAME_IMPORTS, bans = BOX3D}, loc)
		case:
			check(t, sim_rule(info.name, info.fullpath, extra_imports), loc)
			append(&out, info.fullpath)
		}
	}
	testing.expectf(t, len(out) > 0, "lint: no sim package in %s", simulation_dir, loc = loc)
	return out[:]
}

// What a game's headless, extension and tests packages may import besides Odin's own: unified and the game's own
// packages (relative paths). Box3D only through physics (BOX3D, banned).
GAME_IMPORTS :: []string{"unified:", "../"}

// Box3D's bindings: physics' implementation, never imported by a game (src/physics/README.md, The boundary).
BOX3D :: []string{"box3d:"}

// Lints every .odin file under `rule.dir` (an absolute path, or relative to the current directory) with `scan`,
// and with `scan_globals` for a Tick package: one test failure per violation, and one when there are no files.
check :: proc(t: ^testing.T, rule: Rule, loc := #caller_location) {
	files := make([dynamic]string, context.temp_allocator)
	if !testing.expectf(t, odin_files(rule.dir, &files), "lint: cannot list %s", rule.dir, loc = loc) {
		return
	}
	for path in files {
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, rerr == nil, "lint: cannot read %s", path, loc = loc) {
			continue
		}
		for violation in scan(rule, path, string(data)) {
			testing.expect(t, false, violation, loc = loc)
		}
		if rule.kind == .Tick {
			for violation in scan_globals(rule, path, string(data)) {
				testing.expect(t, false, violation, loc = loc)
			}
		}
	}
	testing.expectf(t, len(files) > 0, "lint: no .odin files in %s", rule.dir, loc = loc)
}

// Returns one line per violation in `src` (file `name`) under rule `rule`.
scan :: proc(rule: Rule, name, src: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	report :: proc(
		out: ^[dynamic]string,
		tok: tokenizer.Token,
		name, what: string,
		rule: Rule,
		allocator: runtime.Allocator,
	) {
		where_ := fmt.tprintf("%s(%d:%d)", name, tok.pos.line, tok.pos.column)
		append(out, fmt.aprintf("%s: %s is banned in package %s", where_, what, rule.pkg, allocator = allocator))
	}
	bans := bans_of(rule.kind)
	scanner: tokenizer.Tokenizer
	tokenizer.init(&scanner, src, name, proc(_: tokenizer.Pos, _: string, _: ..any) {})
	scanner.flags = {.Insert_Semicolon} // a newline ends a statement: `x := 1.5` is caught, `x := 1.5 * y` is not
	after_import := false
	prev: [3]tokenizer.Token_Kind // the last significant tokens, prev[0] the latest
	pending: Maybe(tokenizer.Token) // an untyped float literal right after `:=`, if the statement ends there
	for tok := tokenizer.scan(&scanner);; tok = tokenizer.scan(&scanner) {
		if tok.kind == .Comment {
			continue
		}
		if literal, ok := pending.?; ok {
			if tok.kind == .Semicolon || tok.kind == .EOF || tok.kind == .Close_Brace {
				report(
					&out,
					literal,
					name,
					fmt.tprintf("`:= %s` (an untyped float literal is f64)", literal.text),
					rule,
					allocator,
				)
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
			if bans.matrices {
				report(&out, tok, name, "`matrix`", rule, allocator)
			}
		case .Foreign:
			if bans.strict {
				report(&out, tok, name, "`foreign`", rule, allocator)
			}
		case .Map:
			if bans.strict {
				report(&out, tok, name, "`map` (unordered)", rule, allocator)
			}
		case .Undef:
			if bans.strict {
				report(&out, tok, name, "`---` (uninitialised memory differs per run)", rule, allocator)
			}
		case .Float:
			after_colon_eq := prev[0] == .Eq && prev[1] == .Colon
			signed := (prev[0] == .Sub || prev[0] == .Add) && prev[1] == .Eq && prev[2] == .Colon
			if bans.strict && (after_colon_eq || signed) {
				pending = tok
			}
		case .Ident:
			if after_import {
				prev = {tok.kind, prev[0], prev[1]}
				continue // import alias
			}
			if bans.strict &&
			   prev[0] == .Hash &&
			   tok.text == "config" &&
			   !slice.contains(rule.allow_config, config_name(scanner)) {
				report(&out, tok, name, "`#config` (a build option: peers would run different sims)", rule, allocator)
			}
			for banned in bans.idents {
				if tok.text == banned {
					report(&out, tok, name, fmt.tprintf("`%s`", banned), rule, allocator)
				}
			}
			if prev[0] == .Period &&
			   slice.contains(bans.fields, tok.text) &&
			   !slice.contains(rule.allow_fields, tok.text) {
				report(
					&out,
					tok,
					name,
					fmt.tprintf("`.%s` (it differs between peers computing the same tick)", tok.text),
					rule,
					allocator,
				)
			}
			if prev[0] != .Period && slice.contains(bans.calls, tok.text) && call_with_arguments(scanner) {
				report(
					&out,
					tok,
					name,
					fmt.tprintf(
						"the builtin `%s` with two or more arguments (-0 against +0 differs per platform and build: dmath.%s)",
						tok.text,
						tok.text,
					),
					rule,
					allocator,
				)
			}
		case .String:
			if after_import {
				path := strings.trim(tok.text, "\"`")
				if banned_import(rule, path) {
					report(&out, tok, name, fmt.tprintf("import %q", path), rule, allocator)
				}
			}
		}
		after_import = false
		prev = {tok.kind, prev[0], prev[1]}
	}
	return out[:]
}

// The option a `#config` reads (`scanner` is right after `config`): the name after its `(`, else "".
@(private)
config_name :: proc(scanner: tokenizer.Tokenizer) -> string {
	ahead := scanner
	if tokenizer.scan(&ahead).kind != .Open_Paren do return ""
	name := tokenizer.scan(&ahead)
	return name.kind == .Ident ? name.text : ""
}

// Whether the tokens after a name (`scanner` is right after it) are a call with two or more arguments: `(`, then a
// comma outside any nested bracket before its `)`. Scans a copy: the caller's position doesn't move.
@(private)
call_with_arguments :: proc(scanner: tokenizer.Tokenizer) -> bool {
	ahead := scanner
	if tokenizer.scan(&ahead).kind != .Open_Paren do return false
	depth := 1
	for tok := tokenizer.scan(&ahead); tok.kind != .EOF; tok = tokenizer.scan(&ahead) {
		#partial switch tok.kind {
		case .Open_Paren, .Open_Bracket, .Open_Brace:
			depth += 1
		case .Close_Paren, .Close_Bracket, .Close_Brace:
			depth -= 1
			if depth == 0 do return false
		case .Comma:
			if depth == 1 do return true
		}
	}
	return false
}

// Returns one line per package-level variable in `src` that is neither `@(rodata)` nor in
// `rule.allow_globals`. A write to one during a tick would be state outside the block: not rolled
// back, not hashed, a desync nothing else catches. Token-level: a package-level statement
// (outside every brace except a `when`/`else` block's, outside parentheses and brackets) of the
// form `a, b: ...` or `a := ...` declares variables; `a :: ...` is a constant.
scan_globals :: proc(rule: Rule, name, src: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	scanner: tokenizer.Tokenizer
	tokenizer.init(&scanner, src, name, proc(_: tokenizer.Pos, _: string, _: ..any) {})
	scanner.flags = {.Insert_Semicolon}
	braces: [64]bool // open braces, innermost last: true for a package-level `when`/`else` block
	nbraces, opaque, parens := 0, 0, 0
	at_start := true // the next token starts a package-level statement
	block_next := false // the statement started with `when`/`else`: its `{` keeps package level
	rodata := false // the statement's attributes include rodata
	attr, attr_parens := false, 0 // inside an attribute: `@(...)` or `@name`
	phase := 0 // 1: after a name, 2: after `,`, 3: after `name :`, 0: not (or no longer) a declaration
	names := make([dynamic]tokenizer.Token, context.temp_allocator)
	for tok := tokenizer.scan(&scanner); tok.kind != .EOF; tok = tokenizer.scan(&scanner) {
		if tok.kind == .Comment || tok.kind == .File_Tag {
			continue
		}
		if attr {
			#partial switch tok.kind {
			case .Open_Paren:
				attr_parens += 1
			case .Close_Paren:
				attr_parens -= 1
			case .Ident:
				rodata ||= tok.text == "rodata"
			}
			attr = attr_parens > 0
			continue
		}
		top := opaque == 0 && parens == 0
		if top && at_start {
			at_start = false
			phase = 0
			#partial switch tok.kind {
			case .At:
				attr, attr_parens, at_start = true, 0, true
				continue
			case .Semicolon:
				at_start = true // the newline after an attribute
				continue
			case .Ident:
				clear(&names)
				append(&names, tok)
				phase = 1
				continue
			case .When, .Else:
				block_next = true
			}
		} else if top && phase != 0 {
			next := 0
			#partial switch tok.kind {
			case .Comma:
				next = phase == 1 ? 2 : 0
			case .Ident:
				if phase == 2 {
					append(&names, tok)
					next = 1
				}
			case .Colon:
				next = phase == 1 ? 3 : 0
			}
			if phase == 3 || phase == 4 {
				// `name :` then a type, if any: `:` makes it a constant, `=` or the statement's end a variable.
				#partial switch tok.kind {
				case .Colon:
					next = 0
				case .Eq, .Semicolon:
					report_globals(&out, rule, name, names[:], rodata, allocator)
					next = 0
				case:
					next = 4
				}
			}
			phase = next
		}
		#partial switch tok.kind {
		case .Semicolon:
			if top {
				at_start, rodata, block_next = true, false, false
			}
		case .Open_Brace:
			block := top && block_next
			braces[min(nbraces, len(braces) - 1)] = block
			nbraces += 1
			if block {
				at_start, block_next = true, false
			} else {
				opaque += 1
			}
		case .Close_Brace:
			if nbraces > 0 {
				nbraces -= 1
				if braces[min(nbraces, len(braces) - 1)] {
					at_start, rodata = true, false
				} else {
					opaque -= 1
				}
			}
		case .Open_Paren, .Open_Bracket:
			parens += 1
		case .Close_Paren, .Close_Bracket:
			parens -= 1
		}
	}
	if phase == 3 || phase == 4 {
		report_globals(&out, rule, name, names[:], rodata, allocator)
	}
	return out[:]
}

@(private)
report_globals :: proc(
	out: ^[dynamic]string,
	rule: Rule,
	file: string,
	names: []tokenizer.Token,
	rodata: bool,
	allocator: runtime.Allocator,
) {
	for token in names {
		if rodata || slice.contains(rule.allow_globals, token.text) {
			continue
		}
		where_ := fmt.tprintf("%s(%d:%d)", file, token.pos.line, token.pos.column)
		append(
			out,
			fmt.aprintf(
				"%s: package-level variable `%s` in tick package %s: a write during a tick is state outside the block (not rolled back, not hashed); make it `@(rodata)` or a `::` constant, or list it in the rule's allow_globals with a reason",
				where_,
				token.text,
				rule.pkg,
				allocator = allocator,
			),
		)
	}
}

// Whether `rule` forbids importing `path`: not among its imports (Odin's own are allowed but in a Tick package), under one of its bans, or under core:math in a Realtime package (but core:math/bits). scan reports
// each import it bans.
@(private)
banned_import :: proc(rule: Rule, path: string) -> bool {
	bans := bans_of(rule.kind)
	// Compared as written: a relative path (`../x`) is the importer's own neighbour, never a unified package, so a
	// game's `../sim` is not unified:sim and must be listed itself (extra_imports).
	listed := bans.odin_allowed && (strings.has_prefix(path, "core:") || strings.has_prefix(path, "base:"))
	for ok in rule.imports {
		prefix := strings.has_suffix(ok, "/") || strings.has_suffix(ok, ":")
		listed ||= path == ok || (prefix && strings.has_prefix(path, ok))
	}
	if !listed {
		return true
	}
	if bans.math && path != "core:math/bits" && under(path, "core:math") {
		return true
	}
	for banned in rule.bans {
		if under(path, banned) do return true
	}
	return false
}

// Whether an import path is `banned` or under it ("a" covers a/*, "c:" all of collection c).
@(private)
under :: proc(path, banned: string) -> bool {
	collection := strings.has_suffix(banned, ":") && strings.has_prefix(path, banned)
	return(
		collection ||
		path == banned ||
		strings.has_prefix(path, strings.concatenate({banned, "/"}, context.temp_allocator)) \
	)
}

// Every .odin file under `dir`, subdirectories (sub-packages) included.
@(private)
odin_files :: proc(dir: string, out: ^[dynamic]string) -> bool {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return false
	}
	for info in infos {
		if info.type == .Directory {
			odin_files(info.fullpath, out)
		} else if strings.has_suffix(info.name, ".odin") {
			append(out, info.fullpath)
		}
	}
	return true
}
