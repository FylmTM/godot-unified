package cli

import "core:os"
import "core:strings"

// `init <dir>`: a new game repo. The template (template/, every file a .tmpl with __GAME__ for the game's name, the
// directory's) is a complete small game, each player moving a dot: its sim, headless binary, extension, Godot
// scenes and tests. Plus the shims, tools/ (the game's CLI), .gitignore, and unified as a git submodule at unified/.
// The template and the shims come from the submodule, so they always match the library they build against.
@(private)
cmd_init :: proc(args: []string) -> Result {
	Opts :: struct {
		dir:     string `args:"pos=0,required" usage:"the new game repo; its name is the game's"`,
		unified: string `usage:"where to clone unified from (default: this checkout's origin; a GitHub SSH URL becomes HTTPS)"`,
		ref:     string `usage:"the unified commit, tag or branch to pin (default: the source's default branch, main)"`,
	}
	opts: Opts
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
	source := opts.unified
	if source == "" {
		result := run_proc(
			{
				cmd = strs(git(), "-C", state.project.unified, "remote", "get-url", "origin"),
				capture = true,
				quiet = true,
			},
		)
		source = public_url(strings.trim_space(result.stdout))
		if source == "" {
			usage("this checkout has no origin: pass --unified <url or path>")
		}
	}
	make_dirs(dir)
	must_run({cmd = strs(git(), "-C", dir, "init", "-q")}, "git init")
	// protocol.file.allow: a local path is allowed as the source (selftest clones from one)
	must_run(
		{
			cmd = strs(
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
		},
		tprint("adding %s as the unified submodule", source),
	)
	submodule := join(dir, "unified")
	if opts.ref != "" {
		// a commit, tag or branch, also one the default branch doesn't reach
		must_run(
			{
				cmd = strs(
					git(),
					"-C",
					submodule,
					"-c",
					"protocol.file.allow=always",
					"fetch",
					"-q",
					"origin",
					opts.ref,
				),
				capture = true,
			},
			tprint("fetching %s from %s", opts.ref, source),
		)
		must_run(
			{cmd = strs(git(), "-C", submodule, "checkout", "-q", "--detach", "FETCH_HEAD"), capture = true},
			tprint("checking out %s", opts.ref),
		)
		must_run({cmd = strs(git(), "-C", dir, "add", "unified")}, "staging the pinned submodule")
	}
	pinned := strings.trim_space(
		must_run({cmd = strs(git(), "-C", submodule, "rev-parse", "HEAD"), capture = true, quiet = true}, "git rev-parse").stdout,
	)
	template := join(submodule, "src", "cli", "template")
	if !os.is_directory(template) {
		fatal("unified at %s has no src/cli/template: too old for this CLI's init", pinned)
	}
	count := 0
	for file in find_files(template, ".tmpl") {
		rel_path := file[len(template) + 1:len(file) - len(".tmpl")]
		if rel_path == "gitignore" {
			rel_path = ".gitignore"
		}
		target, _ := strings.replace_all(rel_path, "__GAME__", name)
		text, _ := strings.replace_all(must_read(file), "__GAME__", name)
		write_text(join(dir, target), text)
		count += 1
	}
	write_text(join(dir, "tools", ".gdignore"), "")
	// The game's name changes line lengths: format what the template wrote, so the new repo passes fmt --check.
	generated: [dynamic]string
	append(&generated, ..find_files(join(dir, "simulation"), ".odin"))
	append(&generated, ..find_files(join(dir, "tools"), ".odin"))
	fmt_files(ensure_odinfmt(), generated[:], false)
	for shim in ([]string{"uni", "uni.cmd"}) {
		copy_file(join(dir, shim), join(submodule, shim))
	}
	os.change_mode(join(dir, "uni"), os.perm_number(0o755))
	shim := ODIN_OS == .Windows ? "uni.cmd" : "./uni"
	return {
		ok = true,
		summary = tprint(
			"init: %s, a new game repo (%d files from the template; unified at unified/: %s at %s); next: cd %s && %s run",
			name,
			count,
			source,
			pinned[:min(len(pinned), 12)],
			opts.dir,
			shim,
		),
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
	return tprint("https://github.com/%s.git", path)
}

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
