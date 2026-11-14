package main

import "core:os"
import "core:strings"
import "core:time"

import "unified:cli"

// `selftest`: proves the bootstrap and `init` end to end. A fresh clone of this checkout's HEAD in .out/selftest/,
// bootstrapped by its shim with no pinned Odin to find and an empty per-user cache, so the shim downloads the
// pinned Odin, checks its SHA-256, unpacks it and builds the CLI with it. Then `init` a game outside it with the
// clone as its submodule, then build it and run every test suite in that game repo. Only when called (before tooling
// PRs, after a pin or toolchain change); never by `verify`. `--shims` stops after the bootstrap (CI runs that on
// every platform). It tests the committed HEAD, so it refuses uncommitted changes.
cmd_selftest :: proc(args: []string) -> cli.Result {
	Opts :: struct {
		shims: bool `usage:"only the clone's bootstrap: the shim's Odin download, checked and unpacked, and the CLI built with it"`,
	}
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
		what: string,
		cmd:  []string,
		dir:  string,
		env:  []string,
	}
	steps: [dynamic]Step
	append(
		&steps,
		Step{"clone", cli.strs("git", "clone", "-q", root, clone), "", env},
		Step {
			"bootstrap: the shim downloads the pinned Odin (none to find, an empty cache) and builds the CLI with it",
			shim(clone, "version"),
			clone,
			download_env(work, cache),
		},
	)
	if !opts.shims {
		append(
			&steps,
			Step{"init a game outside the repo", shim(clone, "init", game, "--unified", clone), work, env},
			Step{"build the game", shim(game, "build"), game, env},
			Step{"every test suite of the game", shim(game, "test", "--suite", "all"), game, env},
			Step{"the game repo's gate", shim(game, "verify"), game, env},
		)
	}
	start := time.tick_now()
	for s, i in steps {
		t := time.tick_now()
		cli.log("selftest: == %s", s.what)
		r := cli.run_proc({cmd = s.cmd, dir = s.dir, env = s.env})
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
		if i == 1 { 	// the bootstrap: the Odin it ran with is the download
			odin := cli.join(cache, "unified", "odin", cli.pin("odin", "tag"), cli.tprint("odin%s", cli.EXE))
			if !os.is_file(odin) {
				return {
					ok = false,
					summary = cli.tprint("selftest: the bootstrap ran, but the shim downloaded no %s", odin),
				}
			}
		}
		cli.log("selftest: %s: ok (%.1fs)", s.what, cli.seconds_since(t))
	}
	return {
		ok = true,
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
