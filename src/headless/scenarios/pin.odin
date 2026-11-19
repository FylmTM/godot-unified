// Re-pinning (src/headless/README.md, Re-pinning): a test pins a value in its own source (a reference run's literal,
// a golden trace), and after a meant change `uni test --bless` (BLESS) rewrites it there instead of failing. The
// rewrite finds the literal by the value the test was compiled with and changes, token by token, only its numbers and
// strings that differ, so the file keeps the formatting odinfmt gave it. It runs in the test binary, as blessing a
// replay regression does; a lock makes two tests rewriting one file take turns.
package scenarios

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"

// One value a re-pin changed.
Pin_Change :: struct {
	name:  string, // the constant the literal's line declares ("REFERENCE"), or "" when it declares none
	value: string, // where in the literal: a field ("trace"), an element ("[2]") or both ("checkpoints[1]")
	old:   string, // the value's text in the file before
	new:   string, // and after
}

// Rewrites the pinned literal `old` to `new` in `source` (an Odin file's text). Both are literals as a test prints
// them; only their braced part counts (from the first `{`), so a type before it may be written any way. They must
// differ in their numbers and strings alone. `found`: the source holds `old` (then `rewritten` has `new`'s values
// wherever they differ, and `changes` says which) or already holds `new` (then nothing changes). `problem` (nothing
// rewritten): the two literals differ in more than their values, or the source holds `old` more than once. Numbers
// compare by value, so `0x0f` is `0xf`. Everything is temp-allocated.
pin_rewrite :: proc(
	source, old, new: string,
) -> (
	rewritten: string,
	changes: []Pin_Change,
	found: bool,
	problem: string,
) {
	rewritten = source
	old_braces, new_braces := braced(old), braced(new)
	old_tokens, new_tokens := tokenize(old_braces), tokenize(new_braces)
	if len(old_tokens) == 0 || !same_tokens(old_braces, old_tokens, new_braces, new_tokens, values = false) {
		problem = "the pinned literal and the new one differ in more than their values"
		return
	}
	source_tokens := tokenize(source)
	at, holds_new, count := -1, false, 0
	for token, k in source_tokens {
		if token.kind != .Punct || source[token.start] != '{' || len(source_tokens) - k < len(old_tokens) do continue
		window := source_tokens[k:][:len(old_tokens)]
		if same_tokens(source, window, old_braces, old_tokens, values = true) {
			at = k
			count += 1
		} else if same_tokens(source, window, new_braces, new_tokens, values = true) {
			holds_new = true
		}
	}
	if count > 1 {
		problem = "the file holds the pinned literal more than once"
		return
	}
	found = count == 1 || holds_new
	if count == 0 do return
	name := declared_name(source, source_tokens[at].start)
	paths := token_paths(old_braces, old_tokens)
	text := strings.builder_make(context.temp_allocator)
	written := 0
	listed := make([dynamic]Pin_Change, context.temp_allocator)
	for token, j in old_tokens {
		if token.kind != .Number && token.kind != .String do continue
		in_file := source_tokens[at + j]
		was := source[in_file.start:in_file.end]
		now := new_braces[new_tokens[j].start:new_tokens[j].end]
		if same_value(was, now, token.kind) do continue
		strings.write_string(&text, source[written:in_file.start])
		strings.write_string(&text, now)
		written = in_file.end
		append(&listed, Pin_Change{name = name, value = paths[j], old = was, new = now})
	}
	strings.write_string(&text, source[written:])
	return strings.to_string(text), listed[:], true, ""
}

// Rewrites the pinned literal `old` to `new` (pin_rewrite) in the one .odin file of `dir` that holds it, and writes
// that file back when a value changed. `changes` is empty when the file already holds `new` (a second test of one
// pin). `problem` says why nothing was rewritten: no file or several hold the literal, it can't be rewritten
// (pin_rewrite), or the file can't be written. Temp-allocated.
repin :: proc(dir, old, new: string) -> (file: string, changes: []Pin_Change, problem: string) {
	sync.guard(&pin_lock)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return "", nil, fmt.tprintf("cannot list %s", dir)
	rewritten: string
	holders := 0
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, ".odin") do continue
		data, read_err := os.read_entire_file(entry.fullpath, context.temp_allocator)
		if read_err != nil do continue
		text, file_changes, found, file_problem := pin_rewrite(string(data), old, new)
		if file_problem != "" do return entry.fullpath, nil, file_problem
		if !found do continue
		holders += 1
		file, changes, rewritten = entry.fullpath, file_changes, text
	}
	switch {
	case holders == 0:
		return "", nil, fmt.tprintf("no .odin file in %s holds the pinned literal or the new one", dir)
	case holders > 1:
		return "", nil, fmt.tprintf("more than one .odin file in %s holds the literal", dir)
	case len(changes) > 0 && os.write_entire_file(file, transmute([]u8)rewritten) != nil:
		return file, nil, fmt.tprintf("cannot write %s", file)
	}
	return
}

// Re-pins `old` to `new` in the caller's package (repin, in the directory of `loc`'s file) and warns with each value it
// changed, file, value, old and new, so the diff can be reviewed; false, with a failure saying why, when it can't.
// `what` names the check in the messages. A test calls it under BLESS once its own rules allow the new value.
bless_pin :: proc(t: ^testing.T, what, old, new: string, loc := #caller_location) -> bool {
	dir: string
	{
		context.allocator = context.temp_allocator
		dir = filepath.dir(loc.file_path)
	}
	file, changes, problem := repin(dir, old, new)
	if problem != "" {
		testing.expectf(
			t,
			false,
			"%s: --bless can't re-pin it (%s); paste it by hand:\n%s",
			what,
			problem,
			new,
			loc = loc,
		)
		return false
	}
	if len(changes) == 0 do return true
	text := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&text, "%s: re-pinned in %s:", what, shown_path(file))
	for change in changes {
		separator := change.name != "" && !strings.has_prefix(change.value, "[") ? "." : ""
		fmt.sbprintf(&text, "\n\t%s%s%s: %s -> %s", change.name, separator, change.value, change.old, change.new)
	}
	log.warn(strings.to_string(text), location = loc)
	return true
}

// What a check does with a value it pins (reference_reproduces; a golden trace's check), given what moved.
Pin_Verdict :: enum u8 {
	Same, // nothing moved: it passes
	Unpinned, // nothing is pinned yet (a new game's reference): it warns with the literal to pin
	Predates, // pinned before a field the check now pins (reference_verdict): the literal is pasted once
	Refuse, // results moved while the identity they were pinned on stayed: a failure even under BLESS, naming what moved
	Repin, // under BLESS, anything else that moved: re-pinned (bless_pin)
	Fail, // without BLESS, anything else that moved: a failure printing the new literal
}

// The verdict on a pinned value: `results_moved` (what the build computes: checkpoints, a trace), `anything_moved`
// (results, encodings or the identity), `identity_moved` (the build's identity it was pinned on: sim.compat_of, the
// library). Results that move on an identity that didn't are refused, under BLESS too: a change that moves them bumps
// a version first (src/headless/README.md, Re-pinning).
pin_verdict :: proc(pinned, results_moved, anything_moved, identity_moved, bless: bool) -> Pin_Verdict {
	switch {
	case !pinned:
		return .Unpinned
	case !anything_moved:
		return .Same
	case results_moved && !identity_moved:
		return .Refuse
	case bless:
		return .Repin
	}
	return .Fail
}

// --- the rewrite ---------------------------------------------------------------------------------------------------

@(private = "file")
pin_lock: sync.Mutex

@(private = "file")
Token_Kind :: enum u8 {
	Ident,
	Punct,
	Number,
	String,
}

@(private = "file")
Token :: struct {
	kind:       Token_Kind,
	start, end: int, // its bytes in the text
}

// `text` from its first `{` (all of it when it has none).
@(private = "file")
braced :: proc(text: string) -> string {
	open := strings.index_byte(text, '{')
	return open < 0 ? text : text[open:]
}

// Odin's tokens, roughly: what a pinned literal holds (identifiers, numbers, strings, punctuation, one character each),
// with whitespace, comments and a comma before a `}` skipped.
@(private = "file")
tokenize :: proc(text: string) -> []Token {
	tokens := make([dynamic]Token, context.temp_allocator)
	i := 0
	for i < len(text) {
		c := text[i]
		start := i
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			i += 1
			continue
		case strings.has_prefix(text[i:], "//"):
			for i < len(text) && text[i] != '\n' do i += 1
			continue
		case strings.has_prefix(text[i:], "/*"):
			depth := 0
			for i < len(text) {
				if strings.has_prefix(text[i:], "/*") {
					depth += 1
					i += 2
				} else if strings.has_prefix(text[i:], "*/") {
					depth -= 1
					i += 2
					if depth == 0 do break
				} else {
					i += 1
				}
			}
			continue
		case c == '"' || c == '\'':
			i += 1
			for i < len(text) && text[i] != c && text[i] != '\n' {
				i += text[i] == '\\' ? 2 : 1
			}
			i = i < len(text) ? i + 1 : len(text)
			append(&tokens, Token{.String, start, i})
		case c == '`':
			i += 1
			for i < len(text) && text[i] != '`' do i += 1
			i = i < len(text) ? i + 1 : len(text)
			append(&tokens, Token{.String, start, i})
		case is_digit(c):
			for i < len(text) && (is_word(text[i]) || text[i] == '.' && i + 1 < len(text) && is_digit(text[i + 1])) {
				i += 1
			}
			append(&tokens, Token{.Number, start, i})
		case is_word(c):
			for i < len(text) && is_word(text[i]) do i += 1
			append(&tokens, Token{.Ident, start, i})
		case:
			i += 1
			// a trailing comma reads as none: odinfmt writes one after a multi-line literal's last value
			if c == '}' &&
			   len(tokens) > 0 &&
			   tokens[len(tokens) - 1].kind == .Punct &&
			   text[tokens[len(tokens) - 1].start] == ',' {
				pop(&tokens)
			}
			append(&tokens, Token{.Punct, start, i})
		}
	}
	return tokens[:]
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_word :: proc(c: u8) -> bool {
	return is_digit(c) || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_'
}

// Whether two token lists read alike: the same kinds and, but for numbers and strings, the same text; with `values`
// those must be equal too (numbers by value).
@(private = "file")
same_tokens :: proc(a_text: string, a: []Token, b_text: string, b: []Token, values: bool) -> bool {
	if len(a) != len(b) do return false
	for token, k in a {
		other := b[k]
		if token.kind != other.kind do return false
		a_token, b_token := a_text[token.start:token.end], b_text[other.start:other.end]
		switch token.kind {
		case .Ident, .Punct:
			if a_token != b_token do return false
		case .Number, .String:
			if values && !same_value(a_token, b_token, token.kind) do return false
		}
	}
	return true
}

// Whether two number or string tokens hold the same value: numbers as integers when both read as one (`0x0f` is
// `0xf`), else by their text.
@(private = "file")
same_value :: proc(a, b: string, kind: Token_Kind) -> bool {
	if kind == .Number {
		a_value, a_ok := strconv.parse_u64(a)
		b_value, b_ok := strconv.parse_u64(b)
		if a_ok && b_ok do return a_value == b_value
	}
	return a == b
}

// Each token's place in a braced literal (`tokens` of `text`, from its `{`): the field and element names that lead to
// it, "checkpoints[1]" or "[2]" ("" outside a value).
@(private = "file")
token_paths :: proc(text: string, tokens: []Token) -> []string {
	Level :: struct {
		field: string, // the field this element sets ("": a positional element)
		index: int, // the element's position
	}
	levels := make([dynamic]Level, context.temp_allocator)
	paths := make([]string, len(tokens), context.temp_allocator)
	for token, k in tokens {
		token_text := text[token.start:token.end]
		top := len(levels) > 0 ? &levels[len(levels) - 1] : nil
		switch {
		case token_text == "{":
			append(&levels, Level{})
		case token_text == "}":
			if len(levels) > 0 do pop(&levels)
		case token_text == "," && top != nil:
			top.index += 1
			top.field = ""
		case token.kind == .Ident &&
		     top != nil &&
		     k + 1 < len(tokens) &&
		     text[tokens[k + 1].start:tokens[k + 1].end] == "=":
			top.field = token_text
		case token.kind == .Number || token.kind == .String:
			path := strings.builder_make(context.temp_allocator)
			for level in levels {
				if level.field != "" {
					if strings.builder_len(path) > 0 do strings.write_byte(&path, '.')
					strings.write_string(&path, level.field)
				} else {
					fmt.sbprintf(&path, "[%d]", level.index)
				}
			}
			paths[k] = strings.to_string(path)
		}
	}
	return paths
}

// The constant declared on the line holding byte `at` of `source` (`NAME :: ...`), or "".
@(private = "file")
declared_name :: proc(source: string, at: int) -> string {
	line_start := strings.last_index_byte(source[:at], '\n') + 1
	before, separator, _ := strings.partition(source[line_start:at], "::")
	return separator == "" ? "" : strings.trim_space(before)
}

// `path` relative to the working directory when it is inside it (the project root, where uni runs the tests).
@(private = "file")
shown_path :: proc(path: string) -> string {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return path
	relative, rel_err := filepath.rel(cwd, path, context.temp_allocator)
	if rel_err != nil || strings.has_prefix(relative, "..") do return path
	slashed, _ := strings.replace_all(relative, "\\", "/", context.temp_allocator)
	return slashed
}
