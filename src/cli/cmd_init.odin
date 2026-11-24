package cli

import "core:os"
import "core:slice"
import "core:strings"

@(private)
Init_Opts :: struct {
	dir:     string `args:"pos=0,required" usage:"the new game repo (outside this unified checkout, or under its .out/ for a scratch game), or examples/<name> with --in-repo; its name is the game's"`,
	in_repo: bool `usage:"a game inside this unified checkout, at examples/<name> (no submodule, shims or tools/)"`,
	unified: string `hint:"<url>" usage:"where to clone unified from (default: this checkout's origin; a GitHub SSH URL becomes HTTPS)"`,
	ref:     string `usage:"the unified commit (a full or short hash), tag or branch to pin (default: the source's default branch, main)"`,
}

// `init <dir>`: a new game, a copy of unified's examples/minimal_3d named after the directory (minimal_3d replaced by
// the name in paths and text): its sim, headless binary, extension, Godot scenes and tests.
//
// By default a new game repo: the game at the repo's root, plus template/repo/ (a README, .gitattributes, the repo's
// .gitignore, tools/: the game's CLI; .tmpl files with __GAME__ for the name), the shims, and unified as a git
// submodule at unified/. The game and the shims come from the submodule, so they always match the library they build
// against.
//
// `--in-repo`: a game inside this unified checkout, at examples/<name>: the game's files only (not template/repo/). Its
// tests join the optimised test compile through tests/games.gen.odin, which uni writes.
@(private)
cmd_init :: proc(args: []string) -> Result {
	opts: Init_Opts
	parse(&opts, args)
	cwd, _ := os.get_working_directory(context.allocator)
	dir := absolute_path(cwd, opts.dir)
	name := os.base(dir)
	if !valid_game_name(name) {
		usage("%q is not a game name: lowercase letters, digits and _, starting with a letter", name)
	}
	if os.exists(dir) {
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		if len(entries) > 0 {
			usage("%s exists and is not empty", dir)
		}
	}
	init_undo(dir)
	examples := join(state.project.root, EXAMPLES)
	if opts.in_repo {
		if !is_unified_repo() {
			usage("--in-repo makes a game inside a unified checkout; this is a game repo")
		}
		if opts.unified != "" || opts.ref != "" {
			usage("--unified and --ref pin a game repo's submodule; an --in-repo game builds against this checkout")
		}
		if path_key(os.dir(dir)) != path_key(examples) {
			usage("--in-repo: a game goes in examples/<name> of this checkout, not %s", dir)
		}
		return init_in_repo(dir, name)
	}
	// a game repo inside this checkout only under .out/ (git-ignored, safe to delete): a scratch game
	inside := strings.has_prefix(path_key(dir), aprintf("%s/", path_key(state.project.root)))
	scratch := strings.has_prefix(path_key(dir), aprintf("%s/", path_key(state.project.out)))
	if is_unified_repo() && inside && !scratch {
		usage(
			"%s is inside this unified checkout: a game repo goes outside it (or under .out/ for a scratch game); --in-repo makes a game at examples/<name>",
			dir,
		)
	}
	return init_game_repo(dir, name, opts.dir, opts.unified, opts.ref)
}

// A game repo at `dir`: unified as its submodule, then the template and the shims from that submodule.
@(private)
init_game_repo :: proc(dir, name, typed_dir, source_arg, ref: string) -> Result {
	source := source_arg
	if source == "" {
		result := run_proc({
			cmd     = strs(git(), "-C", state.project.unified, "remote", "get-url", "origin"),
			capture = true,
			quiet   = true,
		})
		source = public_url(strings.trim_space(result.stdout))
		if source == "" {
			usage("this checkout has no origin: pass --unified <url or path>")
		}
	}
	make_dirs(dir)
	must_run({cmd = strs(git(), "-C", dir, "init", "-q")}, "git init")
	// protocol.file.allow: a local path is allowed as the source (selftest clones from one)
	must_run({
			cmd     = strs(
				git(),
				"-C",
				dir,
				"-c",
				"protocol.file.allow=always",
				"submodule",
				"add",
				"-q",
				source,
				"unified",
			),
			capture = true,
		}, aprintf("adding %s as the unified submodule", source))
	submodule := join(dir, "unified")
	if ref != "" {
		pin_ref(submodule, source, ref)
		must_run({cmd = strs(git(), "-C", dir, "add", "unified")}, "staging the pinned submodule")
	}
	pinned := strings.trim_space(must_run({
				cmd     = strs(git(), "-C", submodule, "rev-parse", "HEAD"),
				capture = true,
				quiet   = true,
			}, "git rev-parse").stdout)
	if !os.is_directory(join(submodule, TEMPLATE_GAME)) {
		fatal("unified at %s has no %s: too old for this CLI's init", pinned, TEMPLATE_GAME)
	}
	count := write_game(submodule, dir, name, repo = true)
	if os.exists(join(submodule, AGENTS_SECTION)) { 	// an older unified pin ships no agent guidance
		write_agents(submodule, dir)
	}
	write_text(join(dir, "tools", ".gdignore"), "")
	if !os.is_file(join(submodule, SHIM_TEMPLATES, "uni.tmpl")) { 	// an older unified pin: its full shims
		for shim in SHIMS do copy_file(join(dir, shim), join(submodule, shim))
	}
	os.change_mode(join(dir, "uni"), os.perm_number(0o755)) // template/repo's shims: they run unified's own
	shim := ODIN_OS == .Windows ? "uni.cmd" : "./uni"
	return {
		ok      = true,
		summary = aprintf(
			"init: %s, a new game repo (%d files, a copy of minimal_3d; unified at unified/: %s at %s); next: cd %s && %s test --suite all",
			name,
			count,
			source,
			pinned[:min(len(pinned), 12)],
			typed_dir,
			shim,
		),
	}
}

// A game inside this checkout at `dir` (examples/<name>), from this checkout's minimal_3d. Its tests join the one test
// compile by themselves (uni writes tests/games.gen.odin): no shared file changes.
@(private)
init_in_repo :: proc(dir, name: string) -> Result {
	count := write_game(state.project.root, dir, name, repo = false)
	shim := ODIN_OS == .Windows ? "uni.cmd" : "./uni"
	return {
		ok      = true,
		summary = aprintf(
			"init: %s, a new game in examples/%s (%d files, a copy of minimal_3d); next: %s test %s --suite all",
			name,
			name,
			count,
			shim,
			name,
		),
	}
}

// What a new game is a copy of, in unified's checkout: the smallest complete game.
TEMPLATE_GAME :: "examples/" + TEMPLATE_NAME
TEMPLATE_NAME :: "minimal_3d"
// Its files a copy leaves out: its README (template/README.md.tmpl, a draft skeleton of the new game's design, takes
// its place). The `.uid` files are copied: the scenes name their scripts by UID, so
// a copy without them warns on every load until Godot rewrites them.
TEMPLATE_SKIP :: []string{"README.md"}
// Its folders a copy leaves out: its replay regressions are recordings of minimal_3d's play (a new game records its
// own: src/headless/README.md, Replay regressions).
TEMPLATE_SKIP_DIRS :: []string{"simulation/tests/replays/"}

// The template's reference run, which a copy keeps unpinned: its parameters without minimal_3d's results, so a new
// game's first `uni test` warns with its own run, which `uni test <game> --bless` pins once its rules settle
// (scenarios.reference_reproduces).
TEMPLATE_REFERENCE :: "simulation/tests/reference_test.odin"

// The Reference fields a copy of TEMPLATE_REFERENCE leaves out: minimal_3d's results.
TEMPLATE_REFERENCE_RESULTS :: []string{"checkpoints", "trace", "snapshot", "log", "compat"}

// Writes the game: unified's minimal_3d (at `unified`, a checkout) with `name` for minimal_3d in paths and text
// (`repo`: and template/repo/, a game repo's own files, at its root) and formats its Odin files (the name changes line
// lengths), so the new game passes fmt --check. Returns how many files it wrote.
@(private)
write_game :: proc(unified, dir, name: string, repo: bool) -> int {
	source := join(unified, TEMPLATE_GAME)
	listed := must_run(
		{cmd = strs(git(), "-C", source, "ls-files"), capture = true, quiet = true},
		aprintf("listing %s's files", TEMPLATE_GAME),
	)
	count := 0
	for rel_path in strings.split_lines(strings.trim_space(listed.stdout)) {
		if slice.contains(TEMPLATE_SKIP, rel_path) do continue
		skipped := false
		for skip in TEMPLATE_SKIP_DIRS do skipped ||= strings.has_prefix(rel_path, skip)
		if skipped do continue
		target, _ := strings.replace_all(rel_path, "minimal_3d", name)
		text, _ := strings.replace_all(must_read(join(source, rel_path)), "minimal_3d", name)
		text, _ = strings.replace_all(text, "\r\n", "\n")
		text = template_text(rel_path, text, name, repo)
		path := join(dir, target)
		if !os.exists(path) do count += 1
		write_text(path, text)
	}
	template := join(unified, "src", "cli", "template")
	if repo {
		count += write_repo_files(join(template, "repo"), dir, name)
	}
	if skeleton, found := read_text(join(template, "README.md.tmpl")); found { 	// an older unified pin has none
		readme, _ := strings.replace_all(skeleton, "__GAME__", name)
		readme, _ = strings.replace_all(readme, "\r\n", "\n")
		path := join(dir, "README.md")
		if repo {
			// The game is the repo: its README is the repo's (written above) with the skeleton's sections after it.
			_, _, sections := strings.partition(readme, "\n## ")
			readme = aprintf("%s\n## %s", must_read(path), sections)
		} else {
			count += 1
		}
		write_text(path, readme)
	}
	odin_files: [dynamic]string
	append(&odin_files, ..find_files(join(dir, "simulation"), ".odin"))
	if repo {
		append(&odin_files, ..find_files(join(dir, "tools"), ".odin"))
	}
	fmt_files(ensure_odinfmt(), odin_files[:], false)
	return count + 1
}

// A copied file's text for the new game (minimal_3d already renamed): its game.odin starts at `VERSION :: "1"`, without
// minimal_3d's version history; its reference run is unpinned (TEMPLATE_REFERENCE); in a game repo the paths its
// code's comments name are the repo's: the game's own files at the root (examples/<name>/ goes) and unified's under
// unified/ (src/, examples/, docs/). The Markdown is written for both.
@(private)
template_text :: proc(rel_path, text, name: string, repo: bool) -> string {
	out := text
	if rel_path == aprintf("simulation/%s/game.odin", TEMPLATE_NAME) {
		lines := strings.split(out, "\n")
		for &line in lines {
			if strings.has_prefix(line, "VERSION :: ") do line = `VERSION :: "1"`
		}
		out = strings.join(lines, "\n")
	}
	if rel_path == TEMPLATE_REFERENCE {
		kept: [dynamic]string
		for line in strings.split(out, "\n") {
			field, _, _ := strings.partition(strings.trim_space(line), " ")
			if !slice.contains(TEMPLATE_REFERENCE_RESULTS, field) do append(&kept, line)
		}
		out = strings.join(kept[:], "\n")
	}
	if repo && (strings.has_suffix(rel_path, ".odin") || strings.has_suffix(rel_path, ".gd")) {
		out, _ = strings.replace_all(out, aprintf("examples/%s/", name), "")
		out = prefix_paths(out, "src/", "unified/src/")
		out = prefix_paths(out, "examples/", "unified/examples/")
		out = prefix_paths(out, "docs/", "unified/docs/")
	}
	return out
}

// `text` with `with` in place of `path` (a top-level directory, "src/") wherever it starts a path: not after a letter,
// a digit, `_`, `/`, `:` or `.`.
@(private)
prefix_paths :: proc(text, path, with: string) -> string {
	out := strings.builder_make()
	rest := text
	for {
		i := strings.index(rest, path)
		if i < 0 {
			strings.write_string(&out, rest)
			break
		}
		strings.write_string(&out, rest[:i])
		before := i > 0 ? rest[i - 1] : ' '
		inside :=
			(before >= 'a' && before <= 'z') ||
			(before >= 'A' && before <= 'Z') ||
			(before >= '0' && before <= '9') ||
			strings.index_byte("_/:.", before) >= 0
		strings.write_string(&out, inside ? path : with)
		rest = rest[i + len(path):]
	}
	return strings.to_string(out)
}

// Checks out `ref` in the fresh submodule: any commit-ish (a full or short hash, a tag, a branch). The clone already
// holds every branch and tag of the source, so most refs resolve at once; one it lacks (a commit no branch reaches) is
// fetched by name, which needs the full hash.
@(private)
pin_ref :: proc(submodule, source, ref: string) {
	resolve :: proc(submodule, name: string) -> string {
		found := run_proc({
			cmd     = strs(git(), "-C", submodule, "rev-parse", "--verify", "--quiet", aprintf("%s^0", name)),
			capture = true,
			quiet   = true,
		})
		return found.ok ? strings.trim_space(found.stdout) : ""
	}
	commit := resolve(submodule, ref)
	if commit == "" do commit = resolve(submodule, aprintf("origin/%s", ref))
	if commit == "" {
		// protocol.file.allow: a local path is allowed as the source (selftest clones from one)
		fetched := run_proc({
			cmd     = strs(git(), "-C", submodule, "-c", "protocol.file.allow=always", "fetch", "-q", "origin", ref),
			capture = true,
			quiet   = true,
		})
		if fetched.ok do commit = resolve(submodule, "FETCH_HEAD")
	}
	if commit == "" {
		fatal(
			"--ref %s: no commit, tag or branch of that name in %s (a commit no branch reaches needs its full hash)",
			ref,
			source,
		)
	}
	must_run(
		{cmd = strs(git(), "-C", submodule, "checkout", "-q", "--detach", commit), capture = true},
		aprintf("checking out %s", ref),
	)
}

// On a failed init, removes what it made at `dir` (leaving an empty directory that was there before), so a retry
// starts clean instead of finding the directory "not empty".
@(private)
init_undo :: proc(dir: string) {
	@(static) target: string
	@(static) existed: bool
	target, existed = dir, os.exists(dir)
	state.on_fatal = proc() {
		remove_tree(target)
		if existed do make_dirs(target)
	}
}

// A GitHub SSH URL as HTTPS, which anyone (and any CI) can clone without keys: unified is public. Other URLs and
// local paths stay as they are.
public_url :: proc(url: string) -> string {
	path: string
	switch {
	case strings.has_prefix(url, "git@github.com:"):
		path = url[len("git@github.com:"):]
	case strings.has_prefix(url, "ssh://git@github.com/"):
		path = url[len("ssh://git@github.com/"):]
	case:
		return url
	}
	path = strings.trim_suffix(strings.trim_right(path, "/"), ".git")
	return aprintf("https://github.com/%s.git", path)
}

// Writes template/repo/ (a game repo's own files, every one a .tmpl with __GAME__ for `name`) at `dir`'s root, LF line
// endings whatever the checkout has; its .gitignore replaces the game's. Returns how many files are new.
write_repo_files :: proc(template, dir, name: string) -> int {
	count := 0
	for file in find_files(template, ".tmpl") {
		rel_path := file[len(template) + 1:len(file) - len(".tmpl")]
		rel_path, _ = strings.replace_all(rel_path, "\\", "/")
		if rel_path == "gitignore" || rel_path == "gitattributes" {
			rel_path = aprintf(".%s", rel_path)
		}
		text, _ := strings.replace_all(must_read(file), "__GAME__", name)
		text, _ = strings.replace_all(text, "\r\n", "\n")
		path := join(dir, rel_path)
		if !os.exists(path) do count += 1
		write_text(path, text)
	}
	return count
}

// Whether a name can be a game's (`init` takes it from the directory): lowercase letters, digits and _,
// starting with a letter, so it can name the game's Odin packages and library.
valid_game_name :: proc(name: string) -> bool {
	if name == "" || name[0] < 'a' || name[0] > 'z' {
		return false
	}
	for character in name {
		if !(character >= 'a' && character <= 'z' || character >= '0' && character <= '9' || character == '_') {
			return false
		}
	}
	return true
}
