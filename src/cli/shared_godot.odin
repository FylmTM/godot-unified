package cli

import "core:os"
import "core:strings"

// A project's shared Godot code: what its games' Godot projects share (this repo: the demo games', games/shared and
// its SPEC.md), mirrored into every Godot project that uses it as res://addons/shared/ (git-ignored there). Godot
// loads nothing from outside a project, so each game gets a copy, refreshed before every Godot run
// (ensure_imported, write_extension_list).

SHARED_SOURCE :: "games/shared"
SHARED_DIR :: "addons/shared"
// unified's library tooling (src/godot/SPEC.md): the tool base and the validate step, mirrored into every game.
TOOLS_SOURCE :: "src/godot/tools"
TOOLS_DIR :: "addons/unified"
// What the mirror wrote last (path and SHA-256 per file), to tell an in-place edit from a stale copy.
SHARED_STAMP :: ".unified_mirror"

// A Godot project uses the shared code when its project.godot names res://addons/shared/ (an autoload, the bus
// layout).
uses_shared :: proc(dir: string) -> bool {
	text, ok := read_text(join(dir, "project.godot"))
	return ok && strings.contains(text, "res://addons/shared/")
}

// Brings <dir>/addons/shared in line with the project's games/shared: new and changed files copied, removed ones
// deleted. A copy edited in place (the Godot editor saves there) stops the run instead of being overwritten: the
// change belongs in games/shared. A .uid file Godot wrote for a new shared script is copied back, so it is committed
// and every game shares the UID. The SPEC.md stays behind.
sync_shared :: proc(dir: string) {
	if uses_shared(dir) {
		mirror_tree(join(state.project.root, SHARED_SOURCE), join(dir, SHARED_DIR), SHARED_SOURCE)
	}
	// every game (a Godot project with game/): unified's tool scripts
	if os.is_directory(join(dir, "game")) {
		mirror_tree(join(state.project.unified, TOOLS_SOURCE), join(dir, TOOLS_DIR), TOOLS_SOURCE)
	}
}

// Brings `dst` in line with `src` (see sync_shared); `label` names the source in messages.
@(private = "file")
mirror_tree :: proc(src, dst, label: string) {
	stamp := join(dst, SHARED_STAMP)
	last := make(map[string]string, context.temp_allocator)
	if text, ok := read_text(stamp); ok {
		for line in strings.split_lines(text, context.temp_allocator) {
			if space := strings.index_byte(line, ' '); space > 0 {
				last[line[space + 1:]] = line[:space]
			}
		}
	}
	rel :: proc(root, path: string) -> string {
		relative, _ := strings.replace_all(path[len(root) + 1:], "\\", "/", context.temp_allocator)
		return relative
	}
	mirrored :: proc(relative: string) -> bool {
		return relative != "SPEC.md"
	}
	for file in find_files(dst, "") {
		relative := rel(dst, file)
		have, _ := sha256_file(file)
		if want, known := last[relative]; known {
			if have != want {
				fatal(
					"%s was edited in place: make the change in %s/%s (uni overwrites the copy), then delete the copy",
					rel_path(file),
					label,
					relative,
				)
			}
		} else if strings.has_suffix(relative, ".uid") &&
		   os.is_file(join(src, strings.trim_suffix(relative, ".uid"))) &&
		   !os.is_file(join(src, relative)) {
			copy_file(join(src, relative), file)
			log("uni: %s/%s: the UID Godot gave a new shared script (commit it)", label, relative)
		}
	}
	builder := strings.builder_make()
	keep := make(map[string]bool, context.temp_allocator)
	changed := 0
	for file in find_files(src, "") {
		relative := rel(src, file)
		if !mirrored(relative) {
			continue
		}
		keep[relative] = true
		data, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil {
			fatal("cannot read %s", file)
		}
		target := join(dst, relative)
		if old, read_err := os.read_entire_file(target, context.temp_allocator);
		   read_err != nil || string(old) != string(data) {
			if !write_file(target, data) {
				fatal("cannot write %s", target)
			}
			changed += 1
		}
		strings.write_string(&builder, aprintf("%s %s\n", sha256_hex(data), relative))
	}
	for relative in last {
		if !keep[relative] {
			os.remove(join(dst, relative))
			changed += 1
		}
	}
	if have, _ := read_text(stamp); have != strings.to_string(builder) {
		write_text(stamp, strings.to_string(builder))
	}
	if changed > 0 {
		log("uni: %s: %s mirrored (%d file(s) changed)", rel_path(dst), label, changed)
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
