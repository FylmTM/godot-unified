// The code is the spec (AGENTS.md, Conventions; .claude/rules/readme.md): every public proc and type of src/ has a
// doc comment directly above it (attributes may sit between), the one `odin doc` and `uni doc` print. Exempt: what is
// @(private) or in a #+private file, a proc a documented proc group names (the group documents it), generated code
// (*.gen.odin) and the files in MIRRORS, which mirror a C API declaration for declaration.
package test_lint

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Files whose declarations mirror a foreign C API one to one: its own headers document them, the file's header says
// which.
MIRRORS :: []string {
	"eos/api.odin", // the EOS SDK's structs and functions
	"physics/box3d_types.odin", // Box3D's value types under Odin names
}

@(test)
every_public_declaration_has_a_doc_comment :: proc(t: ^testing.T) {
	files: [dynamic]string
	collect_odin(SRC_DIR, &files)
	by_dir: map[string][dynamic]string
	defer {
		for _, list in by_dir do delete(list)
		delete(by_dir)
		delete(files)
	}
	for file in files {
		if strings.has_suffix(file, ".gen.odin") do continue
		dir := filepath.dir(file)
		if dir not_in by_dir do by_dir[dir] = {}
		append(&by_dir[dir], file)
	}
	missing := 0
	for _, package_files in by_dir {
		sources := make([]string, len(package_files), context.temp_allocator)
		for file, i in package_files {
			bytes, err := os.read_entire_file(file, context.temp_allocator)
			testing.expectf(t, err == nil, "cannot read %s", file)
			sources[i] = string(bytes)
		}
		grouped := proc_group_members(sources)
		defer delete(grouped)
		for file, i in package_files {
			name := relative_to_src(file)
			if is_mirror(name) do continue
			for undocumented in undocumented_declarations(sources[i], grouped) {
				testing.expectf(t, false, "src/%s: `%s` has no doc comment above it", name, undocumented)
				missing += 1
			}
		}
	}
	if missing > 0 {
		fmt.eprintfln("%d public declarations of src/ have no doc comment (.claude/rules/readme.md)", missing)
	}
}

// The checker itself: a documented declaration passes with attributes between, an undocumented one fails, private
// ones and group members are exempt.
@(test)
doc_check_catches_undocumented :: proc(t: ^testing.T) {
	source := `// Header.
package p

// Documented.
@(require_results)
documented :: proc() -> int {return 0}

undocumented :: proc() {}

Undocumented_Type :: struct {}

@(private)
hidden :: proc() {}

// A group.
area :: proc {
	area_square,
}

area_square :: proc(side: f32) -> f32 {return side * side}
`
	grouped := proc_group_members({source})
	defer delete(grouped)
	found := undocumented_declarations(source, grouped)
	testing.expectf(t, len(found) == 2, "found %v", found)
	if len(found) == 2 {
		testing.expect_value(t, found[0], "undocumented")
		testing.expect_value(t, found[1], "Undocumented_Type")
	}
	private_file := "#+private\npackage p\n\nundocumented :: proc() {}\n"
	testing.expect_value(t, len(undocumented_declarations(private_file, grouped)), 0)
}

// The names every `name :: proc { a, b }` group of the package lists.
@(private)
proc_group_members :: proc(sources: []string) -> map[string]bool {
	members: map[string]bool
	for source in sources {
		rest := source
		for {
			start := strings.index(rest, ":: proc {")
			if start < 0 do break
			body := rest[start + len(":: proc {"):]
			end := strings.index_byte(body, '}')
			if end < 0 do break
			for member in strings.split(body[:end], ",", context.temp_allocator) {
				name := strings.trim_space(member)
				if dot := strings.last_index_byte(name, '.'); dot >= 0 do name = name[dot + 1:]
				if name != "" do members[name] = true
			}
			rest = body[end:]
		}
	}
	return members
}

// The public procs and types declared at column 0 of `source` with no `//` comment directly above them.
@(private)
undocumented_declarations :: proc(source: string, grouped: map[string]bool) -> []string {
	found: [dynamic]string
	found.allocator = context.temp_allocator
	documented, private := false, false
	in_block_comment := false
	for line in strings.split_lines(source, context.temp_allocator) {
		if in_block_comment {
			if strings.contains(line, "*/") do in_block_comment = false
			documented = true
			continue
		}
		if strings.has_prefix(line, "#+private") do return {}
		if strings.has_prefix(line, "/*") {
			in_block_comment = !strings.contains(line, "*/")
			documented = true
			continue
		}
		if strings.has_prefix(line, "//") {
			documented = true
			continue
		}
		if strings.has_prefix(line, "@(") {
			if strings.contains(line, "private") do private = true
			continue
		}
		if name, ok := declared_name(line); ok && !documented && !private && !grouped[name] {
			append(&found, name)
		}
		documented, private = false, false
	}
	return found[:]
}

// The name a column-0 line declares as a proc, a proc group or a type (`Name :: struct`, `enum`, `union`, `bit_set`,
// `distinct`, `proc`); constants and aliases aren't declarations this check reads.
@(private)
declared_name :: proc(line: string) -> (string, bool) {
	if line == "" || !(line[0] >= 'a' && line[0] <= 'z' || line[0] >= 'A' && line[0] <= 'Z') do return "", false
	colons := strings.index(line, "::")
	if colons < 0 do return "", false
	name := strings.trim_space(line[:colons])
	for c in name {
		if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') do return "", false
	}
	value := strings.trim_space(line[colons + 2:])
	for directive in ([]string{"#force_inline ", "#no_bounds_check ", "#type "}) {
		value = strings.trim_prefix(value, directive)
	}
	for kind in ([]string{"proc", "struct", "enum", "union", "bit_set", "distinct"}) {
		if strings.has_prefix(value, kind) {
			rest := value[len(kind):]
			if rest == "" || rest[0] == ' ' || rest[0] == '(' || rest[0] == '{' || rest[0] == '[' || rest[0] == '"' {
				return name, true
			}
		}
	}
	return "", false
}

@(private)
relative_to_src :: proc(file: string) -> string {
	src, _ := filepath.abs(SRC_DIR, context.temp_allocator)
	abs, _ := filepath.abs(file, context.temp_allocator)
	rel, _ := filepath.rel(src, abs, context.temp_allocator)
	slashed, _ := strings.replace_all(rel, "\\", "/", context.temp_allocator)
	return slashed
}

@(private)
is_mirror :: proc(name: string) -> bool {
	for mirror in MIRRORS {
		if name == mirror do return true
	}
	return false
}
