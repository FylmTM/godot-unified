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
scan_dir :: proc(u: ^Uses, dir: string) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for fi in infos {
		if fi.type == .Directory {
			if fi.name != "gen" && !strings.has_prefix(fi.name, ".") do scan_dir(u, fi.fullpath)
			continue
		}
		if !strings.has_suffix(fi.name, ".odin") || strings.has_suffix(fi.name, ".gen.odin") do continue
		data, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator)
		if rerr != nil do continue
		tz: tokenizer.Tokenizer
		tokenizer.init(&tz, string(data), fi.fullpath, proc(_: tokenizer.Pos, _: string, _: ..any) {})
		for tok := tokenizer.scan(&tz); tok.kind != .EOF; tok = tokenizer.scan(&tz) {
			#partial switch tok.kind {
			case .Ident:
				u.idents[tok.text] = true
			case .String:
				if len(tok.text) >= 2 do u.strings[tok.text[1:len(tok.text) - 1]] = true
			}
		}
	}
}

// A class or builtin is used when code names its type (gd.Node3D), calls a wrapper (Node3D_set_position,
// PackedFloat32Array_new0) or passes its class name ("InputEventKey" for object_cast).
@(private)
is_used :: proc(u: ^Uses, name: string) -> bool {
	if u.idents[name] || u.strings[name] do return true
	for id in u.idents {
		if len(id) > len(name) + 1 && strings.has_prefix(id, name) && id[len(name)] == '_' {
			c := id[len(name) + 1]
			if c >= 'a' && c <= 'z' || c >= '0' && c <= '9' do return true
		}
	}
	return false
}

@(test)
bindings_all_used :: proc(t: ^testing.T) {
	u: Uses
	u.idents.allocator = context.temp_allocator
	u.strings.allocator = context.temp_allocator
	for d in SCAN_DIRS do scan_dir(&u, fmt.tprintf("%s/%s", ROOT, d))
	testing.expect(t, len(u.idents) > 1000, "scanned too little code")
	data, err := os.read_entire_file(ROOT + "/src/gdext/bindings.txt", context.temp_allocator)
	testing.expect(t, err == nil, "cannot read bindings.txt")
	n := 0
	for line in strings.split_lines(string(data), context.temp_allocator) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' || l[0] == '[' do continue
		n += 1
		testing.expectf(t, is_used(&u, l), "bindings.txt lists %s, which no Odin code uses: remove it", l)
	}
	testing.expect(t, n > 10, "bindings.txt looks empty")
}
