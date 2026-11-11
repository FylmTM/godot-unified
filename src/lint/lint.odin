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
	only_imports:  []string, // when set: the only imports allowed, as written ("a/" allows a/*)
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
	"unified:box3d",
	"unified:box3d_port",
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
		pkg = pkg,
		dir = dir,
		only_imports = imports,
		ban_idents = sim_idents,
		ban_matrix = true,
		strict = true,
		tick = true,
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
	for fi in infos {
		if fi.type != .Directory do continue
		switch fi.name {
		case "headless":
			check(
				t,
				{
					pkg = "headless",
					dir = fi.fullpath,
					ban_imports = MATH,
					allow_imports = MATH_OK,
					ban_idents = float_traps,
					ban_matrix = true,
				},
				loc,
			)
		case "extension", "tests":
		// host side and test code: nothing inside a tick
		case:
			check(t, sim_rule(fi.name, fi.fullpath, extra_imports), loc)
			append(&out, fi.fullpath)
		}
	}
	testing.expectf(t, len(out) > 0, "lint: no sim package in %s", simulation_dir, loc = loc)
	return out[:]
}

@(private)
float_traps := FLOAT_TRAPS

// Lints every .odin file under `r.dir` (an absolute path, or relative to the current directory) with `scan`,
// and with `scan_globals` when `r.tick`: one test failure per violation, and one when there are no files.
check :: proc(t: ^testing.T, r: Rule, loc := #caller_location) {
	files := make([dynamic]string, context.temp_allocator)
	if !testing.expectf(t, odin_files(r.dir, &files), "lint: cannot list %s", r.dir, loc = loc) {
		return
	}
	for path in files {
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, rerr == nil, "lint: cannot read %s", path, loc = loc) {
			continue
		}
		for v in scan(r, path, string(data)) {
			testing.expect(t, false, v, loc = loc)
		}
		if r.tick {
			for v in scan_globals(r, path, string(data)) {
				testing.expect(t, false, v, loc = loc)
			}
		}
	}
	testing.expectf(t, len(files) > 0, "lint: no .odin files in %s", r.dir, loc = loc)
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

// Returns one line per package-level variable in `src` that is neither `@(rodata)` nor in
// `r.allow_globals`. A write to one during a tick would be state outside the block: not rolled
// back, not hashed, a desync nothing else catches. Token-level: a package-level statement
// (outside every brace except a `when`/`else` block's, outside parentheses and brackets) of the
// form `a, b: ...` or `a := ...` declares variables; `a :: ...` is a constant.
scan_globals :: proc(r: Rule, name, src: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	tz: tokenizer.Tokenizer
	tokenizer.init(&tz, src, name, proc(_: tokenizer.Pos, _: string, _: ..any) {})
	tz.flags = {.Insert_Semicolon}
	braces: [64]bool // open braces, innermost last: true for a package-level `when`/`else` block
	nbraces, opaque, parens := 0, 0, 0
	at_start := true // the next token starts a package-level statement
	block_next := false // the statement started with `when`/`else`: its `{` keeps package level
	rodata := false // the statement's attributes include rodata
	attr, attr_parens := false, 0 // inside an attribute: `@(...)` or `@name`
	phase := 0 // 1: after a name, 2: after `,`, 3: after `name :`, 0: not (or no longer) a declaration
	names := make([dynamic]tokenizer.Token, context.temp_allocator)
	for tok := tokenizer.scan(&tz); tok.kind != .EOF; tok = tokenizer.scan(&tz) {
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
					report_globals(&out, r, name, names[:], rodata, allocator)
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
		report_globals(&out, r, name, names[:], rodata, allocator)
	}
	return out[:]
}

@(private)
report_globals :: proc(
	out: ^[dynamic]string,
	r: Rule,
	file: string,
	names: []tokenizer.Token,
	rodata: bool,
	allocator: runtime.Allocator,
) {
	for n in names {
		if rodata || slice.contains(r.allow_globals, n.text) {
			continue
		}
		where_ := fmt.tprintf("%s(%d:%d)", file, n.pos.line, n.pos.column)
		append(
			out,
			fmt.aprintf(
				"%s: package-level variable `%s` in tick package %s: a write during a tick is state outside the block (not rolled back, not hashed); make it `@(rodata)` or a `::` constant, or list it in the rule's allow_globals with a reason",
				where_,
				n.text,
				r.pkg,
				allocator = allocator,
			),
		)
	}
}

banned_import :: proc(r: Rule, path: string) -> bool {
	if r.only_imports != nil {
		// Compared as written: a relative path (`../x`) is the importer's own neighbour, never a unified
		// package, so a game's `../sim` is not unified:sim and must be listed itself (extra_imports).
		for ok in r.only_imports {
			if path == ok || (strings.has_suffix(ok, "/") && strings.has_prefix(path, ok)) {
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
