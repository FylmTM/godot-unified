package cli

import "core:crypto/hash"
import "core:encoding/hex"
import "core:os"
import "core:strings"

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
	sort_strings(out[:])
	return out[:]
}
