package main

import "core:strings"
import "core:time"

import "unified:cli"

// `selftest`: proves the bootstrap and `init` end to end. A fresh clone of this checkout's HEAD in .out/selftest/,
// bootstrapped with only Odin (its shim builds its CLI), then `init` a game outside it with the clone as its
// submodule, then build it and run every test suite in that game repo. Only when called (before tooling PRs, after
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
	clone := cli.join(work, "unified")
	game := cli.join(work, "selftest_game")
	// The game repo uses this checkout's Godot: the pinned version either way, without a second download.
	env := cli.env_with(cli.tprint("UNIFIED_GODOT=%s", cli.godot()))
	shim :: proc(dir: string, args: ..string) -> []string {
		cmd: [dynamic]string
		when ODIN_OS == .Windows {
			append(&cmd, "cmd", "/c", cli.join(dir, "unified.cmd"))
		} else {
			append(&cmd, cli.join(dir, "unified"))
		}
		append(&cmd, ..args)
		return cmd[:]
	}
	Step :: struct {
		what: string,
		cmd:  []string,
		dir:  string,
	}
	steps := []Step {
		{"clone", cli.strs("git", "clone", "-q", root, clone), ""},
		{"bootstrap (the shim builds the CLI with only Odin)", shim(clone, "version"), clone},
		{"init a game outside the repo", shim(clone, "init", game, "--unified", clone), work},
		{"build the game", shim(game, "build"), game},
		{"every test suite of the game", shim(game, "test", "--suite", "all"), game},
		{"the game repo's gate", shim(game, "verify"), game},
	}
	start := time.tick_now()
	for s in steps {
		t := time.tick_now()
		cli.log("selftest: == %s", s.what)
		r := cli.run_proc({cmd = s.cmd, dir = s.dir, env = env})
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
		cli.log("selftest: %s: ok (%.1fs)", s.what, cli.seconds_since(t))
	}
	return {ok = true, summary = cli.tprint("selftest passed in %.0fs (%s)", cli.seconds_since(start), cli.rel(work))}
}
