package cli

import "core:crypto/hash"
import "core:encoding/hex"
import "core:os"
import "core:slice"
import "core:strings"

// A file a command changed for its run (swap_text): its original bytes and their backup.
@(private)
Swapped :: struct {
	path, original, backup, backups: string,
}

@(private)
swapped: [dynamic]Swapped

// Writes `text` to `path` (a file of the project) for the rest of the command, keeping its original bytes the first
// time: in memory, and on disk under `backups` (a directory in .out/, the path mirrored from the project's root) in
// case the run is killed. `restore_texts` puts them back; so does a failure (on_failure), and a killed run's are put
// back by the next run's `restore_backups`.
swap_text :: proc(path, text, backups: string) {
	known := false
	for file in swapped do known ||= path_key(file.path) == path_key(path)
	if !known {
		inside := rel(path)
		if inside == path || os.is_absolute_path(inside) {
			fatal("%s is not a file of the project %s", path, state.project.root)
		}
		original := must_read(path)
		backup := join(backups, inside)
		if !write_file(backup, transmute([]byte)original) {
			fatal("cannot back up %s to %s", path, backup)
		}
		if len(swapped) == 0 do on_failure(proc(_: rawptr) {restore_texts()})
		append(&swapped, Swapped{path, original, backup, backups})
	}
	write_text(path, text)
}

// Puts every file swap_text changed back as it was, byte for byte, then drops the backups. Again: nothing to do.
restore_texts :: proc() {
	backups: [dynamic]string
	for len(swapped) > 0 {
		file := pop(&swapped)
		write_text(file.path, file.original)
		os.remove(file.backup)
		if !slice.contains(backups[:], file.backups) do append(&backups, file.backups)
	}
	for dir in backups do remove_tree(dir) // with the directories that mirrored the project's
}

// Puts back the originals a killed run left under `backups` (swap_text), each over the file of the project it
// mirrors, before anything reads those files; returns their paths. Nothing there: nothing to do.
restore_backups :: proc(backups: string) -> []string {
	out: [dynamic]string
	if !os.is_directory(backups) {
		return nil
	}
	for backup in find_files(backups, "") {
		target := join(state.project.root, slashed(backup[len(backups) + 1:]))
		write_text(target, must_read(backup))
		os.remove(backup)
		append(&out, target)
	}
	remove_tree(backups)
	return out[:]
}

// The path with / separators (Godot's, a JSON report's, a zip entry's), on every OS.
slashed :: proc(path: string) -> string {
	out, _ := strings.replace_all(path, "\\", "/")
	return out
}

// A path to compare: / separators, no trailing one, and (on Windows) lowercase.
path_key :: proc(path: string) -> string {
	key := slashed(path)
	key = strings.trim_right(key, "/")
	return ODIN_OS == .Windows ? strings.to_lower(key) : key
}

// The directory a typed path names: absolute against `cwd` when relative, `.` and `..` resolved, / separators, so a
// check like "is it inside this checkout" sees `<root>/../game` as the sibling it is.
absolute_path :: proc(cwd, path: string) -> string {
	joined := os.is_absolute_path(path) ? path : join(cwd, path)
	cleaned, _ := os.clean_path(joined, context.allocator)
	if ODIN_OS == .Windows {
		cleaned = slashed(cleaned)
	}
	return cleaned
}

// Writes a file whole through a temp file and a rename, so a reader never sees half of it. Creates the directory.
write_file :: proc(path: string, data: []byte) -> bool {
	if os.make_directory_all(os.dir(path)) != nil && !os.is_directory(os.dir(path)) {
		return false
	}
	tmp := aprintf("%s.%d.tmp", path, os.get_pid())
	if os.write_entire_file(tmp, data) != nil {
		return false
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// Writes a text file whole (write_file: a temp file and a rename); stops the command when it can't.
write_text :: proc(path, text: string) {
	if !write_file(path, transmute([]byte)text) {
		fatal("cannot write %s", path)
	}
}

// A whole file as text; false when it can't be read.
read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	return string(data), err == nil
}

// A whole file as text, for a file that must exist: stops the command when it can't be read.
must_read :: proc(path: string) -> string {
	text, ok := read_text(path)
	if !ok {
		fatal("cannot read %s", path)
	}
	return text
}

// Creates a directory and its parents (an existing one is fine); stops the command when it can't.
make_dirs :: proc(path: string) {
	if os.make_directory_all(path) != nil && !os.is_directory(path) {
		fatal("cannot create %s", path)
	}
}

// Deletes a file or directory tree when it exists, ignoring failures (what a running process holds may stay).
remove_tree :: proc(path: string) {
	if os.exists(path) {
		os.remove_all(path)
	}
}

// A fresh copy (not a clone: on macOS a clone of a quarantined file keeps a state under which dlopen can hang).
copy_file :: proc(dst, src: string) {
	data, err := os.read_entire_file(src, context.allocator)
	if err != nil {
		fatal("cannot read %s", src)
	}
	defer delete(data)
	if !write_file(dst, data) {
		fatal("cannot write %s", dst)
	}
	if info, stat_err := os.stat(src, context.temp_allocator); stat_err == nil {
		os.change_mode(dst, info.mode)
	}
}

// The SHA-256 of bytes, as lowercase hex.
sha256_hex :: proc(data: []byte) -> string {
	digest := hash.hash_bytes(.SHA256, data, context.temp_allocator)
	return string(hex.encode(digest, context.allocator))
}

// The SHA-256 of a file as lowercase hex, streamed from disk; false when it can't be read. Checks pinned
// downloads (check_sha256) and lets copies skip unchanged files.
sha256_file :: proc(path: string) -> (string, bool) {
	digest, err := hash.hash_file_by_name(.SHA256, path, false, context.temp_allocator)
	if err != nil {
		return "", false
	}
	return string(hex.encode(digest, context.allocator)), true
}

// Fails (and deletes the file) unless its SHA-256 is the pinned one: every download that ends up in a toolchain or
// a shipped build is pinned by hash.
check_sha256 :: proc(path, want, what: string) {
	got, ok := sha256_file(path)
	if !ok {
		fatal("%s: cannot read %s", what, path)
	}
	if got != want {
		os.remove(path)
		fatal("%s: SHA-256 mismatch: got %s, pinned %s", what, got, want)
	}
}

// Every file under `dir` (recursively) whose name ends with `suffix`, skipping hidden entries (.godot, .out, .git);
// sorted.
find_files :: proc(dir, suffix: string) -> []string {
	out: [dynamic]string
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if strings.has_prefix(info.name, ".") {
			if info.type == .Directory {
				os.walker_skip_dir(&walker)
			}
			continue
		}
		if info.type == .Regular && strings.has_suffix(info.name, suffix) {
			append(&out, strings.clone(info.fullpath))
		}
	}
	slice.sort(out[:]) // the same order on every OS
	return out[:]
}
