// The determinism lint (AGENTS.md "Deterministic simulation"): a token scan that fails on constructs a
// simulation must not use. Cheap (a few ms), run from a test package: `tests/lint` runs it over unified and its
// games, and a game outside the repo calls `check_sim_package` from its own sim tests. It can't prove determinism
// (end-to-end suites and reference runs do); it stops the known traps from creeping in. src/lint/SPEC.md.
package lint

import "base:runtime"
import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

Rule :: struct {
	pkg:           string, // the package's name, for messages (and the tests' rule table)
	dir:           string, // the package's directory (subdirectories included); see `check`
	only_imports:  []string, // when set: the only imports allowed, as written ("a/" allows a/*, "core:" all of core)
	ban_imports:   []string, // import path prefixes
	allow_imports: []string, // exceptions to ban_imports
	ban_idents:    []string, // identifiers, e.g. types or intrinsics
	ban_matrix:    bool,
	strict:        bool, // also bans `foreign`, `map` and `x := 1.5` (an untyped float literal is f64)
	tick:          bool, // code inside a tick: package-level variables must be @(rodata) (see scan_globals)
	allow_globals: []string, // package-level variables a tick package may keep: each needs a reason where listed
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
	"unified:b3",
	"unified:wire",
	"base:intrinsics",
	"core:math/bits",
}

// The rule for a game's simulation package (the code inside its tick): only TICK_IMPORTS plus `extra_imports`
// (the game's own deterministic packages as its code imports them, e.g. "../grid"; "a/" allows a/*), f32
// only, no foreign code, no maps, no clocks, files or threads, no randomness besides the state's RNG, no
// mutable package-level variables.
sim_rule :: proc(pkg, dir: string, extra_imports: []string = nil, allocator := context.temp_allocator) -> Rule {
	imports := make([]string, len(TICK_IMPORTS) + len(extra_imports), allocator)
	copy(imports, TICK_IMPORTS)
	copy(imports[len(TICK_IMPORTS):], extra_imports)
	return {
		pkg          = pkg,
		dir          = dir,
		only_imports = imports,
		ban_idents   = sim_idents,
		ban_matrix   = true,
		strict       = true,
		tick         = true,
	}
}

@(private)
sim_idents := SIM_IDENTS // a constant slice in a returned Rule would point at the stack

// Lints a game's simulation package under `sim_rule`: every .odin file in `dir` (subdirectories included), one
// test failure per violation. A game's sim tests call it on their sim package, e.g.
// `lint.check_sim_package(t, #directory + "/../mygame")`.
check_sim_package :: proc(t: ^testing.T, dir: string, extra_imports: []string = nil, loc := #caller_location) {
	check(t, sim_rule(filepath.base(dir), dir, extra_imports), loc)
}

// Lints a game's `simulation/` directory by its layout: `headless/` (the headless binary: real-time code, off
// core:math, no float traps), `extension/` (the GDExtension: host side, nothing banned) and `tests/` (test code,
// nothing banned) are known; every other directory is one of the game's sim packages, linted under `sim_rule`
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
			check(t, {
					pkg           = "headless",
					dir           = info.fullpath,
					ban_imports   = MATH,
					allow_imports = MATH_OK,
					ban_idents    = float_traps,
					ban_matrix    = true,
				}, loc)
		case "extension", "tests":
		// host side and test code: nothing inside a tick
		case:
			check(t, sim_rule(info.name, info.fullpath, extra_imports), loc)
			append(&out, info.fullpath)
		}
	}
	testing.expectf(t, len(out) > 0, "lint: no sim package in %s", simulation_dir, loc = loc)
	return out[:]
}

@(private)
float_traps := FLOAT_TRAPS

// Lints every .odin file under `rule.dir` (an absolute path, or relative to the current directory) with `scan`,
// and with `scan_globals` when `rule.tick`: one test failure per violation, and one when there are no files.
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
		if rule.tick {
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
			if rule.ban_matrix {
				report(&out, tok, name, "`matrix`", rule, allocator)
			}
		case .Foreign:
			if rule.strict {
				report(&out, tok, name, "`foreign`", rule, allocator)
			}
		case .Map:
			if rule.strict {
				report(&out, tok, name, "`map` (unordered)", rule, allocator)
			}
		case .Float:
			after_colon_eq := prev[0] == .Eq && prev[1] == .Colon
			signed := (prev[0] == .Sub || prev[0] == .Add) && prev[1] == .Eq && prev[2] == .Colon
			if rule.strict && (after_colon_eq || signed) {
				pending = tok
			}
		case .Ident:
			if after_import {
				prev = {tok.kind, prev[0], prev[1]}
				continue // import alias
			}
			for banned in rule.ban_idents {
				if tok.text == banned {
					report(&out, tok, name, fmt.tprintf("`%s`", banned), rule, allocator)
				}
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

// Whether `rule` forbids importing `path`: outside only_imports when that is set, or under a ban_imports prefix and
// not an allow_imports exception (both apply: a host package lists its unified imports and allows "core:", while
// still banning core:math). scan reports each import it bans.
banned_import :: proc(rule: Rule, path: string) -> bool {
	if rule.only_imports != nil {
		// Compared as written: a relative path (`../x`) is the importer's own neighbour, never a unified
		// package, so a game's `../sim` is not unified:sim and must be listed itself (extra_imports).
		listed := false
		for ok in rule.only_imports {
			prefix := strings.has_suffix(ok, "/") || strings.has_suffix(ok, ":")
			listed ||= path == ok || (prefix && strings.has_prefix(path, ok))
		}
		if !listed {
			return true
		}
	}
	for ok in rule.allow_imports {
		if path == ok {
			return false
		}
	}
	for banned in rule.ban_imports {
		if path == banned || strings.has_prefix(path, strings.concatenate({banned, "/"}, context.temp_allocator)) {
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
	for info in infos {
		if info.type == .Directory {
			odin_files(info.fullpath, out)
		} else if strings.has_suffix(info.name, ".odin") {
			append(out, info.fullpath)
		}
	}
	return true
}
