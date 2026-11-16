package cli

import "core:os"
import "core:slice"
import "core:strings"

@(private)
Init_Opts :: struct {
	dir:     string `args:"pos=0,required" usage:"the new game repo, or games/<name> with --in-repo; its name is the game's"`,
	in_repo: bool `usage:"a game inside this unified checkout, at games/<name> (no submodule, shims or tools/)"`,
	unified: string `usage:"where to clone unified from (default: this checkout's origin; a GitHub SSH URL becomes HTTPS)"`,
	ref:     string `usage:"the unified commit, tag or branch to pin (default: the source's default branch, main)"`,
}

// `init <dir>`: a new game from the template (template/, every file a .tmpl with __GAME__ for the game's name, the
// directory's): a complete small game, each player moving a capsule: its sim, headless binary, extension, Godot
// scenes and tests, and its view index.
//
// By default a new game repo: the game at the repo's root, plus template/repo/ (a README, .gitattributes, the repo's
// .gitignore, tools/: the game's CLI), the shims, and unified as a git submodule at unified/. The template and the
// shims come from the submodule, so they always match the library they build against.
//
// `--in-repo`: a game inside this unified checkout, at games/<name>: the game's files only (not template/repo/),
// and its tests imported in tests/tests.odin, the one test compile (the lint test fails without it).
@(private)
cmd_init :: proc(args: []string) -> Result {
	opts: Init_Opts
	parse(&opts, args)
	dir := opts.dir
	if !os.is_absolute_path(dir) {
		cwd, _ := os.get_working_directory(context.allocator)
		dir = join(cwd, dir)
	}
	dir = strings.trim_right(dir, "/\\")
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
	games := join(state.project.root, "games")
	if opts.in_repo {
		if !is_unified_repo() {
			usage("--in-repo makes a game inside a unified checkout; this is a game repo")
		}
		if opts.unified != "" || opts.ref != "" {
			usage("--unified and --ref pin a game repo's submodule; an --in-repo game builds against this checkout")
		}
		if path_key(os.dir(dir)) != path_key(games) {
			usage("--in-repo: a game goes in games/<name> of this checkout, not %s", dir)
		}
		return init_in_repo(dir, name)
	}
	if is_unified_repo() && strings.has_prefix(path_key(dir), aprintf("%s/", path_key(state.project.root))) {
		usage("%s is inside this unified checkout: --in-repo makes a game at games/<name>", dir)
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
		// a commit, tag or branch, also one the default branch doesn't reach
		must_run({
				cmd     = strs(
					git(),
					"-C",
					submodule,
					"-c",
					"protocol.file.allow=always",
					"fetch",
					"-q",
					"origin",
					ref,
				),
				capture = true,
			}, aprintf("fetching %s from %s", ref, source))
		must_run(
			{cmd = strs(git(), "-C", submodule, "checkout", "-q", "--detach", "FETCH_HEAD"), capture = true},
			aprintf("checking out %s", ref),
		)
		must_run({cmd = strs(git(), "-C", dir, "add", "unified")}, "staging the pinned submodule")
	}
	pinned := strings.trim_space(must_run({
				cmd     = strs(git(), "-C", submodule, "rev-parse", "HEAD"),
				capture = true,
				quiet   = true,
			}, "git rev-parse").stdout)
	template := join(submodule, "src", "cli", "template")
	if !os.is_directory(template) {
		fatal("unified at %s has no src/cli/template: too old for this CLI's init", pinned)
	}
	count := write_game(template, dir, name, repo = true)
	write_text(join(dir, "tools", ".gdignore"), "")
	for shim in ([]string{"uni", "uni.cmd"}) {
		copy_file(join(dir, shim), join(submodule, shim))
	}
	os.change_mode(join(dir, "uni"), os.perm_number(0o755))
	shim := ODIN_OS == .Windows ? "uni.cmd" : "./uni"
	return {
		ok      = true,
		summary = aprintf(
			"init: %s, a new game repo (%d files from the template; unified at unified/: %s at %s); next: cd %s && %s run",
			name,
			count,
			source,
			pinned[:min(len(pinned), 12)],
			typed_dir,
			shim,
		),
	}
}

// A game inside this checkout at `dir` (games/<name>), from this checkout's template, its tests imported in
// tests/tests.odin.
@(private)
init_in_repo :: proc(dir, name: string) -> Result {
	count := write_game(join(state.project.root, "src", "cli", "template"), dir, name, repo = false)
	tests := join(state.project.root, "tests", "tests.odin")
	text, added := import_game_tests(must_read(tests), name)
	if added {
		write_text(tests, text)
	}
	shim := ODIN_OS == .Windows ? "uni.cmd" : "./uni"
	return {
		ok      = true,
		summary = aprintf(
			"init: %s, a new game in games/%s (%d files from the template%s); next: %s run %s",
			name,
			name,
			count,
			added ? "; its tests imported in tests/tests.odin" : "",
			shim,
			name,
		),
	}
}

// Writes the template's game into `dir` (`repo`: and template/repo/, a game repo's own files, at its root), formats
// its Odin files (the game's name changes line lengths) and writes its view index the way every build does, so the
// new game passes fmt --check and its first build rewrites nothing. Returns how many files it wrote.
@(private)
write_game :: proc(template, dir, name: string, repo: bool) -> int {
	count := write_template(template, dir, name, repo = repo)
	odin_files: [dynamic]string
	append(&odin_files, ..find_files(join(dir, "simulation"), ".odin"))
	if repo {
		append(&odin_files, ..find_files(join(dir, "tools"), ".odin"))
	}
	fmt_files(ensure_odinfmt(), odin_files[:], false)
	bake_view_index({name, dir}, check = false, quiet = true)
	return count + 1
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

// Writes the template's files ending in `suffix` (every file by default) into `dir`, __GAME__ replaced by `name`, LF
// line endings whatever the checkout has, and returns how many. template/repo/ (a game repo's own files) goes to
// `dir`'s root when `repo`, else nowhere; its .gitignore replaces the game's. `vet` writes only the Odin ones, to
// type-check them (vet_template).
write_template :: proc(template, dir, name: string, repo: bool, suffix := ".tmpl") -> int {
	REPO :: "repo"
	count := 0
	files := find_files(template, suffix)
	// the game's files first, then the repo's, which may replace them
	slice.stable_sort_by(files, proc(a, b: string) -> bool {
		return !is_repo_file(a) && is_repo_file(b)
	})
	for file in files {
		rel_path := file[len(template) + 1:len(file) - len(".tmpl")]
		rel_path, _ = strings.replace_all(rel_path, "\\", "/")
		if strings.has_prefix(rel_path, REPO + "/") {
			if !repo do continue
			rel_path = rel_path[len(REPO) + 1:]
		}
		if rel_path == "gitignore" || rel_path == "gitattributes" {
			rel_path = aprintf(".%s", rel_path)
		}
		target, _ := strings.replace_all(rel_path, "__GAME__", name)
		text, _ := strings.replace_all(must_read(file), "__GAME__", name)
		text, _ = strings.replace_all(text, "\r\n", "\n")
		path := join(dir, target)
		if !os.exists(path) do count += 1
		write_text(path, text)
	}
	return count
}

@(private = "file")
is_repo_file :: proc(path: string) -> bool {
	return strings.contains(path, "/template/repo/") || strings.contains(path, "\\template\\repo\\")
}

// tests/tests.odin's text with `name`'s sim tests imported among the other games' (sorted), and whether that changed
// it (false: already imported).
import_game_tests :: proc(text, name: string) -> (string, bool) {
	line := aprintf(`@(require) import %s_tests "../games/%s/simulation/tests"`, name, name)
	lines := strings.split_lines(strings.trim_right(text, "\n"))
	at := -1 // before the first game import that sorts after it, else after the last one
	for existing, i in lines {
		if existing == line {
			return text, false
		}
		if !strings.has_prefix(existing, "@(require) import ") || !strings.contains(existing, `"../games/`) {
			continue
		}
		if existing > line {
			at = i
			break
		}
		at = i + 1
	}
	out: [dynamic]string
	if at == -1 {
		append(&out, ..lines)
		append(&out, "", line)
	} else {
		append(&out, ..lines[:at])
		append(&out, line)
		append(&out, ..lines[at:])
	}
	return aprintf("%s\n", strings.join(out[:], "\n")), true
}

// A path to compare: / separators, no trailing one, and (on Windows) lowercase.
@(private = "file")
path_key :: proc(path: string) -> string {
	key, _ := strings.replace_all(path, "\\", "/")
	key = strings.trim_right(key, "/")
	return ODIN_OS == .Windows ? strings.to_lower(key) : key
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
