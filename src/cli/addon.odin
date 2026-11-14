package cli

import "core:os"
import "core:strings"

// The unified addon: the library's GDScript half (src/godot_host/addon, its SPEC.md), mirrored into every Godot
// project that uses it as res://addons/unified/ (git-ignored there). Godot loads nothing from outside a project, so
// each game gets a copy, refreshed before every Godot run (ensure_imported, write_extension_list).

ADDON_SOURCE :: "src/godot_host/addon"
ADDON_DIR :: "addons/unified"
// What the mirror wrote last (path and SHA-256 per file), to tell an in-place edit from a stale copy.
ADDON_STAMP :: ".unified_mirror"

// A Godot project uses the addon when its project.godot names res://addons/unified/ (an autoload, the bus layout).
uses_addon :: proc(dir: string) -> bool {
	text, ok := read_text(join(dir, "project.godot"))
	return ok && strings.contains(text, "res://addons/unified/")
}

// Brings <dir>/addons/unified in line with the library: new and changed files copied, removed ones deleted. A copy
// edited in place (the Godot editor saves there) stops the run instead of being overwritten: the change belongs in
// src/godot_host/addon. A .uid file Godot wrote for a new addon script is copied back to the library, so it is
// committed and every game shares the UID. The library's SPEC.md stays behind.
sync_addon :: proc(dir: string) {
	if !uses_addon(dir) {
		return
	}
	src := join(state.project.unified, ADDON_SOURCE)
	dst := join(dir, ADDON_DIR)
	stamp := join(dst, ADDON_STAMP)
	last := make(map[string]string, context.temp_allocator)
	if text, ok := read_text(stamp); ok {
		for line in strings.split_lines(text, context.temp_allocator) {
			if sp := strings.index_byte(line, ' '); sp > 0 {
				last[line[sp + 1:]] = line[:sp]
			}
		}
	}
	rel :: proc(root, path: string) -> string {
		r, _ := strings.replace_all(path[len(root) + 1:], "\\", "/", context.temp_allocator)
		return r
	}
	mirrored :: proc(r: string) -> bool {
		return r != "SPEC.md"
	}
	for f in find_files(dst, "") {
		r := rel(dst, f)
		have, _ := sha256_file(f)
		if want, known := last[r]; known {
			if have != want {
				fatal(
					"%s was edited in place: make the change in %s/%s (uni overwrites the copy), then delete the copy",
					rel_path(f),
					ADDON_SOURCE,
					r,
				)
			}
		} else if strings.has_suffix(r, ".uid") &&
		   os.is_file(join(src, strings.trim_suffix(r, ".uid"))) &&
		   !os.is_file(join(src, r)) {
			copy_file(join(src, r), f)
			log("uni: %s/%s: the UID Godot gave a new addon script (commit it)", ADDON_SOURCE, r)
		}
	}
	b := strings.builder_make()
	keep := make(map[string]bool, context.temp_allocator)
	changed := 0
	for f in find_files(src, "") {
		r := rel(src, f)
		if !mirrored(r) {
			continue
		}
		keep[r] = true
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil {
			fatal("cannot read %s", f)
		}
		target := join(dst, r)
		if old, rerr := os.read_entire_file(target, context.temp_allocator);
		   rerr != nil || string(old) != string(data) {
			if !write_file(target, data) {
				fatal("cannot write %s", target)
			}
			changed += 1
		}
		strings.write_string(&b, tprint("%s %s\n", sha256_hex(data), r))
	}
	for r in last {
		if !keep[r] {
			os.remove(join(dst, r))
			changed += 1
		}
	}
	if have, _ := read_text(stamp); have != strings.to_string(b) {
		write_text(stamp, strings.to_string(b))
	}
	if changed > 0 {
		log("uni: %s: the unified addon mirrored (%d file(s) changed)", rel_path(dst), changed)
	}
}

// A path relative to the project root, for messages.
@(private = "file")
rel_path :: proc(path: string) -> string {
	root := state.project.root
	if strings.has_prefix(path, root) && len(path) > len(root) {
		return path[len(root) + 1:]
	}
	return path
}
