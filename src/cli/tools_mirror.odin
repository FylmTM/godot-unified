package cli

import "core:os"
import "core:strings"

// unified's library tooling (src/godot/README.md, Library tooling): the tool base, validate, coop, the level
// exporter and the navigation and crowd bakers, which every Godot project the CLI runs Godot on sees at
// res://unified/tools_godot/. In a game repo that is the unified submodule itself: Godot scans it in place (every
// other top-level directory of unified holds a .gdignore), so the game holds no copy. unified's own projects
// (examples/<game>, the test projects) are inside the checkout, not around it, so they get a git-ignored mirror at
// that same path, refreshed before every Godot run (ensure_imported, write_extension_list): one path for scripts and
// export filters everywhere.
TOOLS_SOURCE :: "tools_godot"
TOOLS_DIR :: "unified/" + TOOLS_SOURCE
// What the mirror wrote last (path and SHA-256 per file), to tell an in-place edit from a stale copy.
MIRROR_STAMP :: ".unified_mirror"
// Where older unified mirrored the tools; a copy left there (its stamp says it is one) is deleted, else Godot sees
// every class twice.
LEGACY_TOOLS_DIR :: "addons/unified"

// Brings <dir>/unified/tools_godot in line with unified's tools_godot (nothing to do in a game repo, where it is
// the submodule's): new and changed files copied, removed ones deleted. A copy edited in place (the Godot editor saves
// there) stops the run instead of being overwritten: the change belongs in tools_godot. A .uid file Godot wrote for a
// new tool script is copied back, so it is committed. Deletes an older unified's mirror at addons/unified.
sync_tools :: proc(dir: string) {
	if !os.is_file(join(dir, "project.godot")) do return
	remove_legacy_tools(dir)
	source := join(state.project.unified, TOOLS_SOURCE)
	target := join(dir, TOOLS_DIR)
	if path_key(target) != path_key(source) {
		mirror_tree(source, target, TOOLS_SOURCE)
	}
}

// Deletes <dir>/addons/unified when it is an older unified's mirror (it holds MIRROR_STAMP), and addons/ when that
// leaves it empty.
remove_legacy_tools :: proc(dir: string) {
	legacy := join(dir, LEGACY_TOOLS_DIR)
	if !os.is_file(join(legacy, MIRROR_STAMP)) do return
	remove_tree(legacy)
	addons := os.dir(legacy)
	if entries, _ := os.read_all_directory_by_path(addons, context.temp_allocator); len(entries) == 0 {
		os.remove(addons)
	}
	log("uni: %s: deleted (unified's tool scripts are at res://%s now)", rel(legacy), TOOLS_DIR)
}

// Brings `dst` in line with `src` (see sync_tools); `label` names the source in messages.
@(private = "file")
mirror_tree :: proc(src, dst, label: string) {
	stamp := join(dst, MIRROR_STAMP)
	last := make(map[string]string, context.temp_allocator)
	if text, ok := read_text(stamp); ok {
		for line in strings.split_lines(text, context.temp_allocator) {
			if space := strings.index_byte(line, ' '); space > 0 {
				last[line[space + 1:]] = line[:space]
			}
		}
	}
	relative_to :: proc(root, path: string) -> string {
		relative, _ := strings.replace_all(path[len(root) + 1:], "\\", "/", context.temp_allocator)
		return relative
	}
	mirrored :: proc(relative: string) -> bool {
		return relative != "README.md"
	}
	for file in find_files(dst, "") {
		relative := relative_to(dst, file)
		have, _ := sha256_file(file)
		if want, known := last[relative]; known {
			if have != want {
				fatal(
					"%s was edited in place: make the change in %s/%s (uni overwrites the copy), then delete the copy",
					rel(file),
					label,
					relative,
				)
			}
		} else if strings.has_suffix(relative, ".uid") &&
		   os.is_file(join(src, strings.trim_suffix(relative, ".uid"))) &&
		   !os.is_file(join(src, relative)) {
			copy_file(join(src, relative), file)
			log("uni: %s/%s: the UID Godot gave a new script (commit it)", label, relative)
		}
	}
	builder := strings.builder_make()
	keep := make(map[string]bool, context.temp_allocator)
	changed := 0
	for file in find_files(src, "") {
		relative := relative_to(src, file)
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
		log("uni: %s: %s mirrored (%d file(s) changed)", rel(dst), label, changed)
	}
}
