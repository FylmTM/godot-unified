// gdext: src/gdext/bindings.txt stays trimmed to what the Odin code uses (every listed class's wrappers are
// generated and compiled on every build). The binding calls themselves run under Godot: tests/godot.
package test_gdext

import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "core:testing"

ROOT :: #directory + "/../.."
SCAN_DIRS :: []string{"src", "games", "tests"}

@(private)
Uses :: struct {
	idents:  map[string]bool,
	strings: map[string]bool,
}

@(private)
scan_dir :: proc(uses: ^Uses, dir: string) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for info in infos {
		if info.type == .Directory {
			if info.name != "gen" && !strings.has_prefix(info.name, ".") do scan_dir(uses, info.fullpath)
			continue
		}
		if !strings.has_suffix(info.name, ".odin") || strings.has_suffix(info.name, ".gen.odin") do continue
		data, rerr := os.read_entire_file(info.fullpath, context.temp_allocator)
		if rerr != nil do continue
		tokens: tokenizer.Tokenizer
		tokenizer.init(&tokens, string(data), info.fullpath, proc(_: tokenizer.Pos, _: string, _: ..any) {})
		for token := tokenizer.scan(&tokens); token.kind != .EOF; token = tokenizer.scan(&tokens) {
			#partial switch token.kind {
			case .Ident:
				uses.idents[token.text] = true
			case .String:
				if len(token.text) >= 2 do uses.strings[token.text[1:len(token.text) - 1]] = true
			}
		}
	}
}

// A class or builtin is used when code names its type (gd.Node3D), calls a wrapper (Node3D_set_position,
// PackedFloat32Array_new0) or passes its class name ("InputEventKey" for object_cast).
@(private)
is_used :: proc(uses: ^Uses, name: string) -> bool {
	if uses.idents[name] || uses.strings[name] do return true
	for id in uses.idents {
		if len(id) > len(name) + 1 && strings.has_prefix(id, name) && id[len(name)] == '_' {
			next := id[len(name) + 1]
			if next >= 'a' && next <= 'z' || next >= '0' && next <= '9' do return true
		}
	}
	return false
}

@(test)
bindings_all_used :: proc(t: ^testing.T) {
	uses: Uses
	uses.idents.allocator = context.temp_allocator
	uses.strings.allocator = context.temp_allocator
	for dir in SCAN_DIRS do scan_dir(&uses, fmt.tprintf("%s/%s", ROOT, dir))
	testing.expect(t, len(uses.idents) > 1000, "scanned too little code")
	data, err := os.read_entire_file(ROOT + "/src/gdext/bindings.txt", context.temp_allocator)
	testing.expect(t, err == nil, "cannot read bindings.txt")
	count := 0
	for line in strings.split_lines(string(data), context.temp_allocator) {
		name := strings.trim_space(line)
		if name == "" || name[0] == '#' || name[0] == '[' do continue
		count += 1
		testing.expectf(t, is_used(&uses, name), "bindings.txt lists %s, which no Odin code uses: remove it", name)
	}
	testing.expect(t, count > 10, "bindings.txt looks empty")
}
