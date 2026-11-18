// gdext: src/gdext/bindings.txt stays trimmed to what the Odin code uses (every listed class's wrappers are
// generated and compiled on every build). The binding calls themselves run under Godot: tests/godot.
package test_gdext

import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "core:testing"

ROOT :: #directory + "/../.."
GDEXT_DIR :: "src/gdext"

// The packages that call Godot: the library's host packages, the binding test extensions and every game's extension.
@(private)
godot_dirs :: proc() -> []string {
	dirs := make([dynamic]string, context.temp_allocator)
	for dir in ([]string{"src/godot", "src/devui", GDEXT_DIR, "tests/godot/ext", "tests/godot_views/ext"}) {
		append(&dirs, fmt.tprintf("%s/%s", ROOT, dir))
	}
	infos, _ := os.read_all_directory_by_path(ROOT + "/games", context.temp_allocator)
	for info in infos {
		extension := fmt.tprintf("%s/simulation/extension", info.fullpath)
		if info.type == .Directory && os.exists(extension) do append(&dirs, extension)
	}
	return dirs[:]
}

// The names the code reaches through the bindings: `gd.Name` and `gd.Name_method` (any import alias of
// unified:gdext), or a bare identifier inside gdext's own hand-written files.
@(private)
scan_dir :: proc(used: ^map[string]bool, dir: string, in_gdext: bool) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for info in infos {
		if info.type == .Directory || !strings.has_suffix(info.name, ".odin") do continue
		if strings.has_suffix(info.name, ".gen.odin") do continue
		data, read_err := os.read_entire_file(info.fullpath, context.temp_allocator)
		if read_err != nil do continue
		source := string(data)
		aliases := gdext_aliases(source)
		tokens: tokenizer.Tokenizer
		tokenizer.init(&tokens, source, info.fullpath, proc(_: tokenizer.Pos, _: string, _: ..any) {})
		before, last: tokenizer.Token
		for token := tokenizer.scan(&tokens); token.kind != .EOF; token = tokenizer.scan(&tokens) {
			if token.kind == .Ident {
				qualified := last.kind == .Period && before.kind == .Ident && aliases[before.text]
				if qualified || (in_gdext && last.kind != .Period) do used[token.text] = true
			}
			before, last = last, token
		}
	}
}

// The names a file imports unified:gdext under (`import gd "unified:gdext"`; without an alias: gdext).
@(private)
gdext_aliases :: proc(source: string) -> map[string]bool {
	aliases := make(map[string]bool, context.temp_allocator)
	text := source
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "import ") || !strings.has_suffix(trimmed, `"unified:gdext"`) do continue
		fields := strings.fields(trimmed, context.temp_allocator)
		aliases[len(fields) == 3 ? fields[1] : "gdext"] = true
	}
	return aliases
}

// A class is used when the code names its type (gd.Node3D) or calls one of its wrappers (gd.Node3D_set_position);
// a builtin only when it calls one of its methods: its constructors (_newN) and destructor are generated whatever
// the list says.
@(private)
is_used :: proc(used: ^map[string]bool, name: string, is_builtin: bool) -> bool {
	if !is_builtin && used[name] do return true
	for id in used {
		if len(id) <= len(name) + 1 || !strings.has_prefix(id, name) || id[len(name)] != '_' do continue
		method := id[len(name) + 1:]
		if method[0] < 'a' || method[0] > 'z' do continue
		if is_builtin && (method == "destroy" || (strings.has_prefix(method, "new") && is_digits(method[3:]))) do continue
		return true
	}
	return false
}

@(private)
is_digits :: proc(text: string) -> bool {
	if text == "" do return false
	for r in text do if r < '0' || r > '9' do return false
	return true
}

@(test)
bindings_all_used :: proc(t: ^testing.T) {
	used := make(map[string]bool, context.temp_allocator)
	for dir in godot_dirs() do scan_dir(&used, dir, strings.has_suffix(dir, GDEXT_DIR))
	testing.expect(t, len(used) > 200, "scanned too little code")
	data, err := os.read_entire_file(ROOT + "/src/gdext/bindings.txt", context.temp_allocator)
	testing.expect(t, err == nil, "cannot read bindings.txt")
	count := 0
	section := ""
	for line in strings.split_lines(string(data), context.temp_allocator) {
		name := strings.trim_space(line)
		if name == "" || name[0] == '#' do continue
		if name[0] == '[' {
			section = name
			continue
		}
		count += 1
		testing.expectf(
			t,
			is_used(&used, name, section == "[builtins]"),
			"bindings.txt lists %s %s, which no Odin code that calls Godot uses: remove it",
			section,
			name,
		)
	}
	testing.expect(t, count > 10, "bindings.txt looks empty")
}

// The rule itself: a builtin's constructor or destructor alone doesn't keep it, a method call does; a class named
// as a type does; a name outside `gd.` doesn't count.
@(test)
bindings_rule :: proc(t: ^testing.T) {
	used := make(map[string]bool, context.temp_allocator)
	used["String_destroy"] = true
	used["StringName_new2"] = true
	used["Array_push_back"] = true
	used["Node3D"] = true
	testing.expect(t, !is_used(&used, "String", true))
	testing.expect(t, !is_used(&used, "StringName", true))
	testing.expect(t, is_used(&used, "Array", true))
	testing.expect(t, is_used(&used, "Node3D", false))
	testing.expect(t, !is_used(&used, "Node", false))
	source := "package x\nimport gd \"unified:gdext\"\nInput :: struct{}\nf :: proc() {gd.Mesh_get_aabb(); Input{}}\n"
	aliases := gdext_aliases(source)
	testing.expect(t, aliases["gd"])
}
