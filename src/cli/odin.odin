package cli

import "core:os"
import "core:strings"
import "core:time"

// Building Odin code: the strict flags, the build modes, build manifests (an output rebuilds when stale), and the
// packages each command covers, by convention (SPEC.md, Layout).

VET :: []string{"-vet", "-strict-style", "-vet-tabs", "-warnings-as-errors"}
// Tests build like dev: optimized enough that the sim tests take milliseconds, fast to compile.
TEST_FLAGS :: []string{"-o:speed", "-use-separate-modules", "-debug"}
VET_TARGETS :: []string{"darwin_arm64", "linux_amd64", "linux_arm64", "windows_amd64"}

Mode :: enum {
	dev, // optimized, the fastest to build: the everyday build
	release, // one LLVM module: the fastest binary
	debug, // unoptimized, for stepping in a debugger
}

mode_flags :: proc(m: Mode) -> []string {
	switch m {
	case .dev:
		return strs("-o:speed", "-use-separate-modules", "-debug")
	case .release:
		return strs("-o:speed")
	case .debug:
		return strs("-o:none", "-debug")
	}
	return nil
}

// The collections every Odin build passes: unified's packages, and `box3d:` (unified-box3d's bindings and library,
// box3d_dir()) once it is there (odin refuses a collection that isn't a directory; a project without physics never
// fetches it).
collection :: proc() -> []string {
	unified := tprint("-collection:unified=%s", join(state.project.unified, "src"))
	if dir := box3d_dir(); os.is_directory(dir) {
		return strs(unified, tprint("-collection:box3d=%s", dir))
	}
	return strs(unified)
}

// This repo (unified itself) rather than a game repo: its own tests, the toy game and the Godot test projects.
is_unified_repo :: proc() -> bool {
	return state.project.root == state.project.unified
}

// A headless binary: each game's simulation/headless, and in this repo the toy game's.
Headless :: struct {
	name:  string,
	pkg:   string,
	box3d: bool, // links Box3D
}

headless_packages :: proc() -> []Headless {
	out: [dynamic]Headless
	for g in state.project.games {
		if pkg := join(g.dir, "simulation", "headless"); os.is_directory(pkg) {
			append(&out, Headless{g.name, pkg, game_uses_box3d(g)})
		}
	}
	if is_unified_repo() {
		toy := join(state.project.root, "tests", "toy")
		append(&out, Headless{"toy", join(toy, "headless"), sources_import(toy, `"unified:physics"`, `"box3d:`)})
	}
	return out[:]
}

headless_path :: proc(name: string, m: Mode) -> string {
	return join(state.project.out, tprint("%v", m), tprint("%s%s", name, EXE))
}

// The packages `test` compiles: this repo's tests/ (every package, the games' suites included), or a game repo's
// simulation/tests.
test_root :: proc() -> string {
	if is_unified_repo() {
		return join(state.project.root, "tests")
	}
	return join(state.project.games[0].dir, "simulation", "tests")
}

// Everything `vet` type-checks: the headless binaries, the tests, the extensions, the CLI's own tools/.
Vet_Package :: struct {
	pkg:   string,
	entry: bool, // has an entry point (a program)
	ext:   bool, // a GDExtension (also checked without the dev UI)
}

vet_packages :: proc() -> []Vet_Package {
	out: [dynamic]Vet_Package
	for h in headless_packages() {
		append(&out, Vet_Package{pkg = h.pkg, entry = true})
	}
	append(&out, Vet_Package{pkg = test_root()})
	if is_unified_repo() {
		append(&out, Vet_Package{pkg = join(state.project.root, "tests", "godot", "ext")})
		append(&out, Vet_Package{pkg = join(state.project.root, "tests", "godot_views", "ext")})
	}
	for g in state.project.games {
		if ext := join(g.dir, "simulation", "extension"); os.is_directory(ext) {
			append(&out, Vet_Package{pkg = ext, ext = true})
		}
	}
	append(&out, Vet_Package{pkg = join(state.project.root, "tools"), entry = true})
	return out[:]
}

// The directories `fmt` formats.
fmt_dirs :: proc() -> []string {
	out: [dynamic]string
	if is_unified_repo() {
		append(&out, join(state.project.root, "src"), join(state.project.root, "tests"))
	}
	for g in state.project.games {
		append(&out, join(g.dir, "simulation"))
	}
	append(&out, join(state.project.root, "tools"))
	return out[:]
}

// --- builds with manifests --------------------------------------------------------------------------------------

Build :: struct {
	pkg:   string,
	out:   string,
	flags: []string, // mode, defines, -build-mode:dll ...
	dir:   string, // working directory ("": ours)
}

// The full odin command line of a build.
build_cmd :: proc(b: Build, deps_file := "") -> []string {
	cmd: [dynamic]string
	append(&cmd, odin(), "build", b.pkg, tprint("-out:%s", b.out))
	append(&cmd, ..collection())
	append(&cmd, ..b.flags)
	append(&cmd, ..VET)
	if deps_file != "" {
		append(&cmd, "-export-dependencies:json", tprint("-export-dependencies-file:%s", deps_file))
	}
	return cmd[:]
}

// The manifest key of a build: its command line (another mode or define is another build).
@(private)
build_key :: proc(b: Build) -> string {
	return sha256_hex(transmute([]byte)strings.join(build_cmd(b), "\x00", context.temp_allocator))
}

// Whether `out` is missing or older than its sources (by its manifest: sizes and times of every source file and
// directory, the odin executable, the same command line).
stale :: proc(b: Build, manifest := "") -> bool {
	m := manifest != "" ? manifest : tprint("%s.inputs", b.out)
	if !os.exists(b.out) {
		return true
	}
	entries, key, ok := read_manifest(m)
	return !ok || key != build_key(b) || !entries_current(entries)
}

// Starts a build that records its manifest when it finishes (`finish_build`).
start_build :: proc(b: Build) -> Proc {
	make_dirs(os.dir(b.out))
	return start({cmd = build_cmd(b, tprint("%s.deps.json", b.out)), dir = b.dir})
}

finish_build :: proc(b: Build, p: ^Proc, manifest := "") -> Ran {
	r := wait(p)
	deps := tprint("%s.deps.json", b.out)
	if r.ok {
		files, odin_path := read_deps(deps)
		write_manifest(manifest != "" ? manifest : tprint("%s.inputs", b.out), build_key(b), files, odin_path)
	}
	os.remove(deps)
	return r
}

// Builds one package now; a failure stops the command.
odin_build :: proc(b: Build, what: string, manifest := "") -> f64 {
	p := start_build(b)
	r := finish_build(b, &p, manifest)
	if !r.ok {
		fatal("%s failed (exit %d)", what, r.exit_code)
	}
	return r.seconds
}

// --- the headless binaries --------------------------------------------------------------------------------------

// Builds every headless binary into .out/<mode>/ in parallel (only the stale ones unless `force`), with the Box3D
// library beside them when one links it.
build_headless :: proc(m: Mode, force := false) -> (built: int) {
	ensure_deps_for_headless()
	hs := headless_packages()
	builds := make([]Build, len(hs))
	procs: [dynamic]struct {
		i: int,
		p: Proc,
	}
	for h, i in hs {
		builds[i] = headless_build(h, m)
		if h.box3d {
			stage_box3d(os.dir(builds[i].out), debug = m == .debug)
		}
		if force || stale(builds[i]) {
			append(&procs, struct {
				i: int,
				p: Proc,
			}{i, start_build(builds[i])})
		}
	}
	failed: [dynamic]string
	for &p in procs {
		if r := finish_build(builds[p.i], &p.p); !r.ok {
			append(&failed, hs[p.i].name)
		}
	}
	if len(failed) > 0 {
		fatal("building %s failed", strings.join(failed[:], ", "))
	}
	return len(procs)
}

headless_build :: proc(h: Headless, m: Mode) -> Build {
	flags: [dynamic]string
	append(&flags, ..mode_flags(m))
	append(&flags, ..box3d_defines(m, h.box3d))
	return {pkg = h.pkg, out = headless_path(h.name, m), flags = flags[:]}
}

// Box3D when any headless binary or test may link it (this repo's tests always do).
@(private)
ensure_deps_for_headless :: proc() {
	if project_uses_box3d() {
		ensure_box3d()
	}
}

// The commit, with +dirty when the tree has changes ("" outside a git checkout).
git_commit :: proc(dir := "") -> string {
	d := dir != "" ? dir : state.project.root
	head := run_proc({cmd = {git(), "-C", d, "rev-parse", "HEAD"}, capture = true, quiet = true})
	if !head.ok {
		return ""
	}
	status := run_proc({cmd = {git(), "-C", d, "status", "--porcelain"}, capture = true, quiet = true})
	return tprint("%s%s", strings.trim_space(head.stdout), strings.trim_space(status.stdout) != "" ? "+dirty" : "")
}

seconds_since :: proc(t: time.Tick) -> f64 {
	return time.duration_seconds(time.tick_since(t))
}
