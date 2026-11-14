package main

import "core:strings"
import "core:time"

import "unified:cli"

// `selftest`: proves the bootstrap and `init` end to end. A fresh clone of this checkout's HEAD in .out/selftest/,
// bootstrapped with only Odin (its shim builds its CLI), then `init` a game outside it with the clone as its
// submodule pinned to HEAD (checking the pin and the commands and links its files name), then build it and run every test suite in that game
// repo. Only when called (before tooling PRs, after
// a pin or toolchain change); never by `verify`. It tests the committed HEAD, so it refuses uncommitted changes.
cmd_selftest :: proc(args: []string) -> cli.Result {
	Opts :: struct {}
	opts: Opts
	cli.parse(&opts, args)
	root := cli.state.project.root
	st := cli.run_proc({cmd = cli.strs("git", "-C", root, "status", "--porcelain"), capture = true, quiet = true})
	if strings.trim_space(st.stdout) != "" {
		cli.fatal("selftest tests the committed HEAD: commit first")
	}
	work := cli.join(cli.state.project.out, "selftest")
	cli.remove_tree(work)
	cli.make_dirs(work)
	head := strings.trim_space(
		cli.run_proc({cmd = cli.strs("git", "-C", root, "rev-parse", "HEAD"), capture = true, quiet = true}).stdout,
	)
	clone := cli.join(work, "unified")
	game := cli.join(work, "selftest_game")
	// The game repo uses this checkout's Godot: the pinned version either way, without a second download.
	env := cli.env_with(cli.tprint("UNIFIED_GODOT=%s", cli.godot()))
	shim :: proc(dir: string, args: ..string) -> []string {
		cmd: [dynamic]string
		when ODIN_OS == .Windows {
			append(&cmd, "cmd", "/c", cli.join(dir, "uni.cmd"))
		} else {
			append(&cmd, cli.join(dir, "uni"))
		}
		append(&cmd, ..args)
		return cmd[:]
	}
	Step :: struct {
		what:   string,
		cmd:    []string,
		dir:    string,
		check:  proc(game, head: string) -> string, // after cmd: what is wrong with the game repo ("": nothing)
		expect: string, // what cmd's stdout must contain (it runs with --json)
	}
	steps := []Step {
		{what = "clone", cmd = cli.strs("git", "clone", "-q", root, clone)},
		{what = "bootstrap (the shim builds the CLI with only Odin)", cmd = shim(clone, "version"), dir = clone},
		{
			what = "init a game outside the repo",
			cmd = shim(clone, "init", game, "--unified", clone, "--ref", head),
			dir = work,
			check = check_init,
		},
		// the first build generates the Godot bindings: a cold run, not one over its budget
		{what = "build the game", cmd = shim(game, "build", "--json"), dir = game, expect = `"Godot bindings"`},
		{what = "every test suite of the game", cmd = shim(game, "test", "--suite", "all"), dir = game},
		{what = "the game repo's gate", cmd = shim(game, "verify"), dir = game},
	}
	start := time.tick_now()
	for s in steps {
		t := time.tick_now()
		cli.log("selftest: == %s", s.what)
		r := cli.run_proc({cmd = s.cmd, dir = s.dir, env = env, capture = s.expect != ""})
		if s.expect != "" {
			cli.log("%s%s", r.stderr, r.stdout)
		}
		if !r.ok {
			return {
				ok = false,
				summary = cli.tprint(
					"selftest: %s failed (exit %d); the work is in %s",
					s.what,
					r.exit_code,
					cli.rel(work),
				),
			}
		}
		if s.expect != "" && !strings.contains(r.stdout, s.expect) {
			return {ok = false, summary = cli.tprint("selftest: %s: its output has no %s", s.what, s.expect)}
		}
		if s.check != nil {
			if problem := s.check(game, head); problem != "" {
				return {
					ok = false,
					summary = cli.tprint("selftest: %s: %s; the work is in %s", s.what, problem, cli.rel(work)),
				}
			}
		}
		cli.log("selftest: %s: ok (%.1fs)", s.what, cli.seconds_since(t))
	}
	return {ok = true, summary = cli.tprint("selftest passed in %.0fs (%s)", cli.seconds_since(start), cli.rel(work))}
}

// What `init` wrote: the submodule is pinned to `head` (--ref), and the commands and links the game repo's files
// name are the current ones (the shims are `uni` and `uni.cmd`, the repo is godot-unified).
check_init :: proc(game, head: string) -> string {
	pinned := cli.run_proc(
		{cmd = cli.strs("git", "-C", game, "ls-files", "--stage", "unified"), capture = true, quiet = true},
	)
	if !strings.contains(pinned.stdout, head) {
		return cli.tprint("the unified submodule is not pinned to %s: %s", head, strings.trim_space(pinned.stdout))
	}
	STALE :: []string{"./unified", "unified.cmd", "`unified ", "unified init", "github.com/FylmTM/unified)"}
	for file in cli.find_files(game, "") {
		in_repo := file[len(game) + 1:]
		if strings.has_prefix(in_repo, "unified/") || strings.has_prefix(in_repo, "unified\\") {
			continue // the submodule
		}
		text, _ := cli.read_text(file)
		for stale in STALE {
			if strings.contains(text, stale) {
				return cli.tprint("%s names %q", cli.rel(file), stale)
			}
		}
	}
	return ""
}
