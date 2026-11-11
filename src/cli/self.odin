package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// The self-rebuild (SPEC.md, Bootstrap and self-rebuild). Each binary .out/cli/unified-<hash> has a manifest,
// <binary>.manifest: the content hash, then one line per input with its size and modification time: every source
// file it was built from (outside the Odin install), the directories they sit in (a new file changes its
// directory's time) and the odin executable. Before every command the binary checks them: all the same, it runs.
// Else it hashes the sources: the same content, it refreshes the times and runs; different, it rebuilds itself to
// unified-<new hash>, points .out/cli/current at it and runs that with the same arguments.

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
	if strings.has_prefix(name, "unified-bootstrap") {
		// Built by a shim: install this binary under its hash, then go on running it.
		deps := join(cli_dir, "unified-bootstrap.deps.json")
		files, odin := read_deps(deps)
		hash := content_hash(files)
		target := join(cli_dir, tprint("unified-%s%s", hash[:12], EXE))
		if !os.exists(target) {
			copy_file(target, exe)
		}
		write_manifest(tprint("%s.manifest", target), hash, files, odin)
		write_text(join(cli_dir, "current"), tprint("%s\n", os.base(target)))
		os.remove(deps)
		return
	}
	entries, hash, ok := read_manifest(tprint("%s.manifest", exe))
	if ok && entries_current(entries) {
		return
	}
	if ok && !odin_changed(entries) {
		files: [dynamic]string
		for e in entries {
			if e.kind == "file" {
				append(&files, e.path)
			}
		}
		if dirs_current(entries) && content_hash(files[:]) == hash {
			odin := ""
			for e in entries {
				if e.kind == "odin" {
					odin = e.path
				}
			}
			write_manifest(tprint("%s.manifest", exe), hash, files[:], odin)
			return
		}
	}
	rebuild(cli_dir, args)
}

// Rebuilds the CLI from source, installs it and runs it with our arguments in our place.
@(private)
rebuild :: proc(cli_dir: string, args: []string) -> ! {
	odin := which("odin")
	if odin == "" {
		log("unified: odin is not on PATH: install the Odin release pinned in pins.cfg (README.md, Requirements)")
		os.exit(1)
	}
	p := state.project
	tmp := join(cli_dir, tprint("unified-build-%d%s", os.get_pid(), EXE))
	deps := tprint("%s.deps.json", tmp)
	log("unified: the CLI's sources changed: rebuilding it")
	ran := run_proc(
		{
			cmd = {
				odin,
				"build",
				join(p.root, "tools"),
				tprint("-collection:unified=%s", join(p.unified, "src")),
				"-o:minimal",
				tprint("-out:%s", tmp),
				"-export-dependencies:json",
				tprint("-export-dependencies-file:%s", deps),
			},
			quiet = true,
		},
	)
	if !ran.ok {
		log("unified: the CLI does not build (above)")
		os.exit(1)
	}
	files, odin_path := read_deps(deps)
	os.remove(deps)
	hash := content_hash(files)
	target := join(cli_dir, tprint("unified-%s%s", hash[:12], EXE))
	if os.exists(target) {
		os.remove(tmp)
	} else if os.rename(tmp, target) != nil {
		log("unified: cannot install %s", target)
		os.exit(1)
	}
	write_manifest(tprint("%s.manifest", target), hash, files, odin_path)
	write_text(join(cli_dir, "current"), tprint("%s\n", os.base(target)))
	prune_binaries(cli_dir)
	cmd := make([dynamic]string)
	append(&cmd, target)
	append(&cmd, ..args)
	child := run_proc({cmd = cmd[:], interactive = true, quiet = true})
	os.exit(child.exit_code)
}

// The source files of a build from Odin's dependency export, minus the Odin install's own (the odin executable
// stands for those), and the odin executable.
read_deps :: proc(path: string) -> (files: []string, odin: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log("unified: cannot read %s", path)
		os.exit(1)
	}
	Deps :: struct {
		source_files: []string,
		load_files:   []string,
	}
	d: Deps
	if json.unmarshal(data, &d) != nil {
		log("unified: cannot parse %s", path)
		os.exit(1)
	}
	odin = which("odin")
	odin_root := ODIN_ROOT
	out: [dynamic]string
	for f in d.source_files {
		if !path_under(f, odin_root) {
			append(&out, f)
		}
	}
	for f in d.load_files {
		if !path_under(f, odin_root) {
			append(&out, f)
		}
	}
	slice.sort(out[:])
	return out[:], odin
}

@(private)
path_under :: proc(path, dir: string) -> bool {
	norm :: proc(s: string) -> string {
		slashed, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
		return strings.to_lower(slashed, context.temp_allocator)
	}
	d := strings.trim_right(norm(dir), "/")
	return d != "" && strings.has_prefix(norm(path), d)
}

// The hash of the sources' contents (with their names relative to the project, so a moved checkout keeps it).
@(private)
content_hash :: proc(files: []string) -> string {
	b := strings.builder_make()
	for f in files {
		data, err := os.read_entire_file(f, context.allocator)
		if err != nil {
			return "missing"
		}
		strings.write_string(&b, rel(f))
		strings.write_byte(&b, 0)
		strings.write_string(&b, sha256_hex(data))
		strings.write_byte(&b, '\n')
		delete(data)
	}
	return sha256_hex(transmute([]byte)strings.to_string(b))
}

write_manifest :: proc(manifest, hash: string, files: []string, odin: string) {
	b := strings.builder_make()
	fmt.sbprintf(&b, "hash\t%s\n", hash)
	stat_line :: proc(b: ^strings.Builder, kind, path: string) {
		fi, err := os.stat(path, context.temp_allocator)
		if err != nil {
			return
		}
		fmt.sbprintf(b, "%s\t%d\t%d\t%s\n", kind, fi.size, time.to_unix_nanoseconds(fi.modification_time), path)
	}
	if odin != "" {
		stat_line(&b, "odin", odin)
	}
	dirs: [dynamic]string
	for f in files {
		stat_line(&b, "file", f)
		d := os.dir(f)
		if !slice.contains(dirs[:], d) {
			append(&dirs, d)
		}
	}
	for d in dirs {
		stat_line(&b, "dir", d)
	}
	write_text(manifest, strings.to_string(b))
}

read_manifest :: proc(path: string) -> (entries: []Manifest_Entry, hash: string, ok: bool) {
	text := read_text(path) or_return
	out: [dynamic]Manifest_Entry
	for line in strings.split_lines_iterator(&text) {
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) == 2 && fields[0] == "hash" {
			hash = fields[1]
		} else if len(fields) == 4 {
			size, _ := strconv.parse_i64(fields[1])
			mt, _ := strconv.parse_i64(fields[2])
			append(&out, Manifest_Entry{fields[0], fields[3], size, mt})
		}
	}
	return out[:], hash, hash != "" && len(out) > 0
}

@(private)
entry_current :: proc(e: Manifest_Entry) -> bool {
	fi, err := os.stat(e.path, context.temp_allocator)
	if err != nil {
		return false
	}
	return (e.kind == "dir" || fi.size == e.size) && time.to_unix_nanoseconds(fi.modification_time) == e.mtime
}

entries_current :: proc(entries: []Manifest_Entry) -> bool {
	for e in entries {
		if !entry_current(e) {
			return false
		}
	}
	return true
}

@(private)
dirs_current :: proc(entries: []Manifest_Entry) -> bool {
	for e in entries {
		if e.kind == "dir" && !entry_current(e) {
			return false
		}
	}
	return true
}

@(private)
odin_changed :: proc(entries: []Manifest_Entry) -> bool {
	for e in entries {
		if e.kind == "odin" {
			return !entry_current(e) || which("odin") != e.path
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
	for fi in infos {
		if strings.has_prefix(fi.name, "unified-") &&
		   !strings.has_suffix(fi.name, ".manifest") &&
		   !strings.has_suffix(fi.name, ".json") &&
		   !strings.has_prefix(fi.name, "unified-bootstrap") &&
		   !strings.has_prefix(fi.name, "unified-build-") {
			append(&bins, fi)
		}
	}
	slice.sort_by(bins[:], proc(a, b: os.File_Info) -> bool {
		return time.diff(a.modification_time, b.modification_time) < 0
	})
	for fi in bins[min(CLI_KEEP, len(bins)):] {
		if os.remove(fi.fullpath) == nil {
			os.remove(tprint("%s.manifest", fi.fullpath))
		}
	}
}

// The binary was built with the pinned Odin (tag and commit), or it refuses to run: Odin has no semver, and a
// build from master reports the month's tag too.
@(private)
check_odin_version :: proc() {
	tag := pin("odin", "tag")
	commit := pin("odin", "commit")
	built := ODIN_VERSION_HASH
	if built == "" {
		log("unified: warning: this Odin build has no commit hash; the pin is %s (%s)", tag, commit[:9])
		return
	}
	if !strings.has_prefix(commit, built) {
		log(
			"unified: Odin %s (commit %s) is not the pinned %s (commit %s): install that release (README.md, Requirements)",
			ODIN_VERSION,
			built,
			tag,
			commit[:9],
		)
		os.exit(1)
	}
}
