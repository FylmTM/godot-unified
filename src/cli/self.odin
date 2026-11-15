package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// The self-rebuild (SPEC.md, Bootstrap and self-rebuild). Each binary .out/cli/uni-<hash> has a manifest,
// <binary>.inputs (not .manifest: Windows reads foo.exe.manifest as the program's own): the content hash, then one
// line per input with its size and modification time: every source file it was built from (outside the Odin
// install), the directories they sit in (a new file changes its directory's time) and the odin executable. Before
// every command the binary checks them: all the same, it runs. Else it hashes the sources: the same content, it
// refreshes the times and runs; different, it rebuilds itself to uni-<new hash>, points .out/cli/current at it and
// runs that with the same arguments.

Manifest_Entry :: struct {
	kind:  string, // "file", "dir" or "odin"
	path:  string,
	size:  i64,
	mtime: i64, // nanoseconds
}

@(private)
CLI_KEEP :: 4 // binaries kept in .out/cli: switching branches back and forth needs no rebuild

@(private)
self_check :: proc(args: []string) {
	exe, _ := os.get_executable_path(context.allocator)
	name := os.base(exe)
	cli_dir := os.dir(exe)
	if strings.has_prefix(name, "uni-bootstrap") {
		// Built by a shim: install this binary under its hash, then go on running it.
		deps := join(cli_dir, "uni-bootstrap.deps.json")
		files, odin := read_deps(deps)
		hash := content_hash(files)
		target := join(cli_dir, binary_name(hash, ODIN_VERSION_HASH))
		if !os.exists(target) {
			copy_file(target, exe)
		}
		write_manifest(tprint("%s.inputs", target), hash, files, odin)
		write_text(join(cli_dir, "current"), tprint("%s\n", os.base(target)))
		os.remove(deps)
		return
	}
	entries, hash, ok := read_manifest(tprint("%s.inputs", exe))
	// Built with an Odin that isn't the pinned one while PATH now names another odin (the shims put the pinned
	// release first): rebuild with it. Else check_odin_version refuses.
	if ok && entries_current(entries) && (built_with_pinned_odin() || !odin_changed(entries)) {
		return
	}
	if ok && !odin_changed(entries) {
		files: [dynamic]string
		for entry in entries {
			if entry.kind == "file" {
				append(&files, entry.path)
			}
		}
		if dirs_current(entries) && content_hash(files[:]) == hash {
			odin := ""
			for entry in entries {
				if entry.kind == "odin" {
					odin = entry.path
				}
			}
			write_manifest(tprint("%s.inputs", exe), hash, files[:], odin)
			return
		}
	}
	rebuild(cli_dir, args)
}

// The binary a child `uni` runs: this one, or when this is a shim's first build (uni-bootstrap), the one it installed
// (.out/cli/current): a child of uni-bootstrap would take itself for a fresh one and miss the deps file it removed.
self_exe :: proc() -> string {
	exe, _ := os.get_executable_path(context.allocator)
	if !strings.has_prefix(os.base(exe), "uni-bootstrap") {
		return exe
	}
	current, ok := read_text(join(os.dir(exe), "current"))
	if !ok || strings.trim_space(current) == "" {
		return exe
	}
	return join(os.dir(exe), strings.trim_space(current))
}

// uni-<source hash>-<odin commit>: the same sources built by another Odin are another binary (the content hash
// leaves the Odin install out), so switching to the pinned Odin never keeps a binary the old one built.
@(private)
binary_name :: proc(hash, odin_commit: string) -> string {
	if odin_commit == "" {
		return tprint("uni-%s%s", hash[:12], EXE)
	}
	return tprint("uni-%s-%s%s", hash[:12], odin_commit, EXE)
}

// Rebuilds the CLI from source, installs it and runs it with our arguments in our place.
@(private)
rebuild :: proc(cli_dir: string, args: []string) -> ! {
	odin := which("odin")
	if odin == "" {
		log("uni: odin is not on PATH: run uni through its shim (./uni, uni.cmd), which downloads the pinned release")
		os.exit(1)
	}
	project := state.project
	tmp := join(cli_dir, tprint("uni-build-%d%s", os.get_pid(), EXE))
	deps := tprint("%s.deps.json", tmp)
	log("uni: the CLI's sources or its odin changed: rebuilding it")
	ran := run_proc({
		cmd   = {
			odin,
			"build",
			join(project.root, "tools"),
			tprint("-collection:unified=%s", join(project.unified, "src")),
			"-o:minimal",
			tprint("-out:%s", tmp),
			"-export-dependencies:json",
			tprint("-export-dependencies-file:%s", deps),
		},
		quiet = true,
	})
	if !ran.ok {
		log("uni: the CLI does not build (above)")
		os.exit(1)
	}
	// The odin that built it may not be ours (the shims switched to the pinned one): its own install's files are
	// left out of the manifest, and its commit names the binary.
	root := run_proc({
		cmd     = {odin, "root"},
		capture = true,
		quiet   = true,
	})
	odin_root := strings.trim_space(root.stdout)
	version := run_proc({
		cmd     = {odin, "version"},
		capture = true,
		quiet   = true,
	})
	// "<odin path> version <tag>:<commit>": the commit follows the last ':' (a Windows path has one too)
	version_text := strings.trim_space(version.stdout)
	commit :=
		version_text[strings.last_index_byte(version_text, ':') + 1:] if version.ok && strings.contains_rune(version_text, ':') else ""
	files, odin_path := read_deps(deps, odin_root if root.ok && odin_root != "" else ODIN_ROOT)
	os.remove(deps)
	hash := content_hash(files)
	target := join(cli_dir, binary_name(hash, commit))
	if os.exists(target) {
		os.remove(tmp)
	} else if os.rename(tmp, target) != nil {
		log("uni: cannot install %s", target)
		os.exit(1)
	}
	write_manifest(tprint("%s.inputs", target), hash, files, odin_path)
	write_text(join(cli_dir, "current"), tprint("%s\n", os.base(target)))
	prune_binaries(cli_dir)
	cmd := make([dynamic]string)
	append(&cmd, target)
	append(&cmd, ..args)
	child := run_proc({
		cmd         = cmd[:],
		interactive = true,
		quiet       = true,
	})
	os.exit(child.exit_code)
}

// The source files of a build from Odin's dependency export, minus the Odin install's own (the odin executable
// stands for those), and the odin executable.
read_deps :: proc(path: string, odin_root := ODIN_ROOT) -> (files: []string, odin: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log("uni: cannot read %s", path)
		os.exit(1)
	}
	Deps :: struct {
		source_files: []string,
		load_files:   []string,
	}
	parsed: Deps
	if json.unmarshal(data, &parsed) != nil {
		log("uni: cannot parse %s", path)
		os.exit(1)
	}
	odin = which("odin")
	out: [dynamic]string
	for file in parsed.source_files {
		if !path_under(file, odin_root) {
			append(&out, file)
		}
	}
	for file in parsed.load_files {
		if !path_under(file, odin_root) {
			append(&out, file)
		}
	}
	slice.sort(out[:])
	return out[:], odin
}

@(private)
path_under :: proc(path, dir: string) -> bool {
	norm :: proc(path: string) -> string {
		slashed, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
		return strings.to_lower(slashed, context.temp_allocator)
	}
	trimmed := strings.trim_right(norm(dir), "/")
	return trimmed != "" && strings.has_prefix(norm(path), trimmed)
}

// The hash of the sources' contents (with their names relative to the project, so a moved checkout keeps it).
@(private)
content_hash :: proc(files: []string) -> string {
	builder := strings.builder_make()
	for file in files {
		data, err := os.read_entire_file(file, context.allocator)
		if err != nil {
			return "missing"
		}
		strings.write_string(&builder, rel(file))
		strings.write_byte(&builder, 0)
		strings.write_string(&builder, sha256_hex(data))
		strings.write_byte(&builder, '\n')
		delete(data)
	}
	return sha256_hex(transmute([]byte)strings.to_string(builder))
}

// Writes a manifest (the format above): the key, then the size and time of the odin executable, every source
// file and their directories. For the CLI itself and every build `stale` checks.
write_manifest :: proc(manifest, hash: string, files: []string, odin: string) {
	builder := strings.builder_make()
	fmt.sbprintf(&builder, "hash\t%s\n", hash)
	stat_line :: proc(builder: ^strings.Builder, kind, path: string) {
		info, err := os.stat(path, context.temp_allocator)
		if err != nil {
			return
		}
		fmt.sbprintf(
			builder,
			"%s\t%d\t%d\t%s\n",
			kind,
			info.size,
			time.to_unix_nanoseconds(info.modification_time),
			path,
		)
	}
	if odin != "" {
		stat_line(&builder, "odin", odin)
	}
	dirs: [dynamic]string
	for file in files {
		stat_line(&builder, "file", file)
		file_dir := os.dir(file)
		if !slice.contains(dirs[:], file_dir) {
			append(&dirs, file_dir)
		}
	}
	for dir in dirs {
		stat_line(&builder, "dir", dir)
	}
	write_text(manifest, strings.to_string(builder))
}

// Reads a manifest write_manifest wrote; ok only when it has a key and at least one entry.
read_manifest :: proc(path: string) -> (entries: []Manifest_Entry, hash: string, ok: bool) {
	text := read_text(path) or_return
	out: [dynamic]Manifest_Entry
	for line in strings.split_lines_iterator(&text) {
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) == 2 && fields[0] == "hash" {
			hash = fields[1]
		} else if len(fields) == 4 {
			size, _ := strconv.parse_i64(fields[1])
			mtime, _ := strconv.parse_i64(fields[2])
			append(&out, Manifest_Entry{fields[0], fields[3], size, mtime})
		}
	}
	return out[:], hash, hash != "" && len(out) > 0
}

@(private)
entry_current :: proc(entry: Manifest_Entry) -> bool {
	info, err := os.stat(entry.path, context.temp_allocator)
	if err != nil {
		return false
	}
	return(
		(entry.kind == "dir" || info.size == entry.size) &&
		time.to_unix_nanoseconds(info.modification_time) == entry.mtime \
	)
}

// Whether every entry of a manifest still has its recorded time (and size, but for a directory): the ~1 ms
// check that lets a build, or the CLI's self-rebuild, be skipped.
entries_current :: proc(entries: []Manifest_Entry) -> bool {
	for entry in entries {
		if !entry_current(entry) {
			return false
		}
	}
	return true
}

@(private)
dirs_current :: proc(entries: []Manifest_Entry) -> bool {
	for entry in entries {
		if entry.kind == "dir" && !entry_current(entry) {
			return false
		}
	}
	return true
}

@(private)
odin_changed :: proc(entries: []Manifest_Entry) -> bool {
	for entry in entries {
		if entry.kind == "odin" {
			return !entry_current(entry) || which("odin") != entry.path
		}
	}
	return true
}

// Keeps the newest CLI_KEEP binaries (and their manifests); a binary still running (Windows) stays until later.
@(private)
prune_binaries :: proc(cli_dir: string) {
	infos, err := os.read_all_directory_by_path(cli_dir, context.allocator)
	if err != nil {
		return
	}
	bins: [dynamic]os.File_Info
	for info in infos {
		if strings.has_prefix(info.name, "uni-") &&
		   !strings.has_suffix(info.name, ".inputs") &&
		   !strings.has_suffix(info.name, ".json") &&
		   !strings.has_prefix(info.name, "uni-bootstrap") &&
		   !strings.has_prefix(info.name, "uni-build-") {
			append(&bins, info)
		}
	}
	slice.sort_by(bins[:], proc(first, second: os.File_Info) -> bool {
		return time.diff(first.modification_time, second.modification_time) < 0
	})
	for info in bins[min(CLI_KEEP, len(bins)):] {
		if os.remove(info.fullpath) == nil {
			os.remove(tprint("%s.inputs", info.fullpath))
		}
	}
}

// Whether the binary was built with the pinned Odin's commit (a build without a commit hash counts: it only warns).
@(private)
built_with_pinned_odin :: proc() -> bool {
	return ODIN_VERSION_HASH == "" || strings.has_prefix(pin("odin", "commit"), ODIN_VERSION_HASH)
}

// The binary was built with the pinned Odin (tag and commit), or it refuses to run: Odin has no semver, and a
// build from master reports the month's tag too. Refusing drops the shims' stamp (.out/cli/odin-on-path: this
// odin on PATH is the pinned one), so the next run checks the odin on PATH again and downloads the pinned release.
@(private)
check_odin_version :: proc() {
	tag := pin("odin", "tag")
	commit := pin("odin", "commit")
	built := ODIN_VERSION_HASH
	if built == "" {
		log("uni: warning: this Odin build has no commit hash; the pin is %s (%s)", tag, commit[:9])
		return
	}
	if !built_with_pinned_odin() {
		os.remove(join(state.project.out, "cli", "odin-on-path"))
		log(
			"uni: Odin %s (commit %s) is not the pinned %s (commit %s): run uni again, and the shim downloads that release",
			ODIN_VERSION,
			built,
			tag,
			commit[:9],
		)
		os.exit(1)
	}
}
