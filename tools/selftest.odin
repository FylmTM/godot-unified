package main

import "core:os"
import "core:strings"
import "core:time"

import "unified:cli"

Selftest_Opts :: struct {
	shims: bool `usage:"only the clone's bootstrap: the shim's Odin download, checked and unpacked, and the CLI built with it"`,
}

// `selftest`: proves the bootstrap and `init` end to end. A fresh clone of this checkout's HEAD in .out/selftest/,
// bootstrapped by its shim with no pinned Odin to find and an empty per-user cache, so the shim downloads the
// pinned Odin, checks its SHA-256, unpacks it and builds the CLI with it. Then `init` a game outside it with the
// clone as its submodule pinned to HEAD (checking the pin and the commands and links its files name), then check its
// view index, build it, run a headless mode and every test suite in that game repo. Then `init --in-repo` the same
// game inside the clone (checking it wrote only the game and its tests import), its index, build, a headless mode,
// the clone's odin suite and the game's godot suite. Only when called (before tooling PRs, after a pin or toolchain
// change); never by `verify`, nor by CI. `--shims` stops after the bootstrap. It tests the committed HEAD, so it
// refuses uncommitted changes.
cmd_selftest :: proc(args: []string) -> cli.Result {
	opts: Selftest_Opts
	cli.parse(&opts, args)
	root := cli.state.project.root
	st := cli.run_proc({
		cmd     = cli.strs("git", "-C", root, "status", "--porcelain"),
		capture = true,
		quiet   = true,
	})
	if strings.trim_space(st.stdout) != "" {
		cli.fatal("selftest tests the committed HEAD: commit first")
	}
	work := cli.join(cli.state.project.out, "selftest")
	cli.remove_tree(work)
	cli.make_dirs(work)
	head := strings.trim_space(cli.run_proc({
			cmd     = cli.strs("git", "-C", root, "rev-parse", "HEAD"),
			capture = true,
			quiet   = true,
		}).stdout)
	clone := cli.join(work, "unified")
	game := cli.join(work, "selftest_game")
	cache := cli.join(work, "cache")
	env := cli.env_with() // the game repo finds the pinned Godot in the per-user cache, as every checkout does
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
		env:    []string,
		check:  proc(game, head: string) -> string, // after cmd: what is wrong with the game repo ("": nothing)
		expect: string, // what cmd's stdout must contain
	}
	steps: [dynamic]Step
	append(&steps, Step {
		what = "clone",
		cmd  = cli.strs("git", "clone", "-q", root, clone),
		env  = env,
	}, Step {
		what = "bootstrap: the shim downloads the pinned Odin (none to find, an empty cache) and builds the CLI with it",
		cmd  = shim(clone, "version"),
		dir  = clone,
		env  = download_env(work, cache),
	})
	if !opts.shims {
		append(
			&steps,
			Step {
				what  = "init a game outside the repo",
				cmd   = shim(clone, "init", game, "--unified", clone, "--ref", head),
				dir   = work,
				env   = env,
				check = check_init,
			},
			Step {
				what = "its view index is what the build writes",
				cmd  = shim(game, "bake", "--check"),
				dir  = game,
				env  = env,
			},
			// the first build generates the Godot bindings: a cold run, not one over its budget
			Step {
				what   = "build the game",
				cmd    = shim(game, "build", "--json"),
				dir    = game,
				env    = env,
				expect = `"Godot bindings"`,
			},
			Step {
				what   = "the headless binary through uni",
				cmd    = shim(game, "headless", "--", "synctest", "--ticks", "64", "--window", "8"),
				dir    = game,
				env    = env,
				expect = `"mismatches":0`,
			},
			Step {
				what = "every test suite of the game",
				cmd  = shim(game, "test", "--suite", "all"),
				dir  = game,
				env  = env,
			},
			Step {
				what = "the game repo's gate",
				cmd  = shim(game, "verify"),
				dir  = game,
				env  = env,
			},
			// the same game inside the clone (init --in-repo), against the clone itself
			Step {
				what  = "init a game inside the checkout",
				cmd   = shim(clone, "init", cli.join("games", IN_REPO_GAME), "--in-repo"),
				dir   = clone,
				env   = env,
				check = check_in_repo,
			},
			Step {
				what = "its view index is what the build writes",
				cmd  = shim(clone, "bake", IN_REPO_GAME, "--check"),
				dir  = clone,
				env  = env,
			},
			Step {
				what = "build it",
				cmd  = shim(clone, "build", IN_REPO_GAME),
				dir  = clone,
				env  = env,
			},
			Step {
				what   = "its headless binary through uni",
				cmd    = shim(clone, "headless", IN_REPO_GAME, "--", "synctest", "--ticks", "64", "--window", "8"),
				dir    = clone,
				env    = env,
				expect = `"mismatches":0`,
			},
			Step {
				what = "the checkout's odin suite, the game's tests and lint in it",
				cmd  = shim(clone, "test"),
				dir  = clone,
				env  = env,
			},
			Step {
				what = "the game under headless Godot",
				cmd  = shim(clone, "test", IN_REPO_GAME, "--suite", "godot"),
				dir  = clone,
				env  = env,
			},
		)
	}
	start := time.tick_now()
	for s, i in steps {
		t := time.tick_now()
		cli.log("selftest: == %s", s.what)
		r := cli.run_proc({
			cmd     = s.cmd,
			dir     = s.dir,
			env     = s.env,
			capture = s.expect != "",
		})
		if s.expect != "" {
			cli.log("%s%s", r.stderr, r.stdout)
		}
		if !r.ok {
			return {
				ok      = false,
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
					ok      = false,
					summary = cli.tprint("selftest: %s: %s; the work is in %s", s.what, problem, cli.rel(work)),
				}
			}
		}
		if i == 1 { 	// the bootstrap: the Odin it ran with is the download
			odin := cli.join(cache, "unified", "odin", cli.pin("odin", "tag"), cli.tprint("odin%s", cli.EXE))
			if !os.is_file(odin) {
				return {
					ok      = false,
					summary = cli.tprint("selftest: the bootstrap ran, but the shim downloaded no %s", odin),
				}
			}
		}
		cli.log("selftest: %s: ok (%.1fs)", s.what, cli.seconds_since(t))
	}
	return {
		ok      = true,
		summary = cli.tprint(
			"selftest%s passed in %.0fs (%s)",
			opts.shims ? " --shims" : "",
			cli.seconds_since(start),
			cli.rel(work),
		),
	}
}

// The environment of the shim's download path: the per-user cache is `cache` (empty), and no odin on PATH is the
// pinned one. Windows: every PATH directory holding an odin.exe is dropped (curl, tar and certutil come from
// System32 by full path). Elsewhere a stand-in `odin` reporting another commit goes first on PATH, the case of a
// developer with another Odin installed; dropping directories there could drop curl or clang with it.
download_env :: proc(work, cache: string) -> []string {
	cli.make_dirs(cache)
	env, _ := os.environ(context.allocator)
	out: [dynamic]string
	path := ""
	cache_key := ODIN_OS == .Windows ? "LOCALAPPDATA" : "XDG_CACHE_HOME"
	for entry in env {
		eq := strings.index_byte(entry, '=')
		if eq > 0 {
			key := strings.to_upper(entry[:eq]) // Windows spells it Path
			if key == "PATH" {
				path = entry[eq + 1:]
				continue
			}
			if key == cache_key {
				continue
			}
		}
		append(&out, entry)
	}
	when ODIN_OS == .Windows {
		kept: [dynamic]string
		for dir in strings.split(path, ";") {
			if dir != "" && !os.is_file(cli.join(dir, "odin.exe")) {
				append(&kept, dir)
			}
		}
		path = strings.join(kept[:], ";")
	} else {
		stand_in := cli.join(work, "other-odin")
		cli.write_text(cli.join(stand_in, "odin"), "#!/bin/sh\necho 'odin version dev-2000-01:0000000'\n")
		os.change_mode(cli.join(stand_in, "odin"), os.perm_number(0o755))
		path = cli.tprint("%s:%s", stand_in, path)
	}
	append(&out, cli.tprint("PATH=%s", path), cli.tprint("%s=%s", cache_key, cache))
	return out[:]
}

// The game `init --in-repo` makes inside the clone, at games/<it>.
IN_REPO_GAME :: "selftest_game"

// What `init --in-repo` changed in the clone (next to `game`'s repo): the game's directory and tests/tests.odin,
// nothing else.
check_in_repo :: proc(game, head: string) -> string {
	clone := cli.join(os.dir(game), "unified")
	status := cli.run_proc({
		cmd     = cli.strs("git", "-C", clone, "status", "--porcelain", "--untracked-files=normal"),
		capture = true,
		quiet   = true,
	})
	changes := strings.split_lines(strings.trim_right(status.stdout, "\r\n"))
	want := []string{" M tests/tests.odin", cli.tprint("?? games/%s/", IN_REPO_GAME)}
	if len(changes) != len(want) || changes[0] != want[0] || changes[1] != want[1] {
		return cli.tprint("the clone's changes are not just the game and its tests import:\n%s", status.stdout)
	}
	return ""
}

// What `init` wrote: the submodule is pinned to `head` (--ref), and the commands and links the game repo's files
// name are the current ones (the shims are `uni` and `uni.cmd`, the repo is godot-unified).
check_init :: proc(game, head: string) -> string {
	pinned := cli.run_proc({
		cmd     = cli.strs("git", "-C", game, "ls-files", "--stage", "unified"),
		capture = true,
		quiet   = true,
	})
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
