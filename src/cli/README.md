# `unified:cli`: the `uni` CLI as a library

`uni` builds, tests, checks and runs games, in this repo and in a game repo that has `unified` as a git submodule.
`unified:cli` is the library every project's CLI is made of: the project's `tools/` (package main) calls `cli.run`
with the public commands and its own, and the shims (`uni`, `uni.cmd`) build and run that binary. The commands and
their options are `uni help` and `uni <command> -h`; a package's API, this one's included, is `uni doc <pkg>`. This
file is how the CLI works.

`unified:cli` and a project's `tools/` import only `core:` (and each other), so editing the rest of the library never
rebuilds the CLI.

## Requirements

The developer installs what Odin needs (clang on macOS and Linux; Visual Studio Build Tools on Windows: its linker
and the Windows SDK), git and curl (shipped with macOS, Windows 10+ and Linux), nothing else. Everything else the CLI
or its shims fetch or build, pinned and hash-checked: Odin, Godot, export templates, odinfmt, Box3D. Nothing it builds
is C or C++. The EOS SDK is the exception: Epic's licence keeps it out of the repo and CI, so a machine that plays
online downloads it from Epic and names it with `UNIFIED_EOS_SDK` (`docs/EOS.md`).

## Layout

A project is this repo, or a game repo: a Godot project at its root with `unified` as a submodule, always at
`unified/`. Its root holds the shims, `tools/` and `.out/`, where everything generated goes (git-ignored, safe to
delete): the CLI binaries, odinfmt, the headless binaries per build mode, the unpacked unified-box3d release. Only
this repo has `pins.cfg`; a game repo reads its submodule's.

A game is a directory with `project.godot` and `simulation/`: the project root, else every `examples/*/`. Commands take
the game by name, optional when there is one. In a game repo, `test`, `vet`, `fmt` and `verify` cover the game only,
never the submodule, which `unified`'s own CI proves. Every Odin build gets two collections: `unified` (`src/`) and
`box3d` (unified-box3d's bindings).

**The per-user cache** (`user_cache`) holds the pinned downloads every checkout on the machine shares, a directory or
file per version and SHA-256, so two pins never share a path: the shims' Odin, the Godot editor (one path for the OS
to remember, e.g. Windows Firewall), the unified-box3d zips each project unpacks. A download goes to a part file of
the process's own and is renamed into place: checkouts fetching the same pin at once each finish, and the first rename
wins.

## What a project adds

The conventions above are all a game repo needs: its `tools/main.odin`, which `init` writes, passes the public
commands to `cli.run`. A project with more registers it before `run`: `cli.configure` (`Project_Config`) for its test
root, extra headless binaries, packages `vet` checks, directories `fmt` formats, Box3D outside the games, `bench` rows
and level scenes `bake` exports; `cli.add_suites` for its own test suites; its own commands as another command set
to `run`. This repo registers its `tests/` root (compiled with `-all-packages`; `uni` writes its `games.gen.odin`,
importing every in-repo game's tests, so a new game edits no shared file), the toy game, its Godot test projects and
the Box3D bench. The library knows nothing of this repo's layout but where `init --in-repo` writes a game.

## Bootstrap and self-rebuild

- **The shims** (POSIX sh and cmd, nothing else) read `pins.cfg`'s `[odin]` with shell builtins and put the pinned
  release first on PATH, downloading it into the per-user cache once per machine and pin (curl), its SHA-256 checked,
  unpacked beside its final directory and renamed into place. No other Odin is used. Then they run the binary
  `.out/cli/current` names, or, when there is none, build `tools/` into `uni-bootstrap` and run that; it installs
  itself under its hash.
- **The binary checks itself** before every command against its manifest (`self_check`): unchanged inputs run at
  once, the same content refreshes the times, anything else rebuilds and runs the new binary with the same arguments.
  A binary's name holds its source hash and the Odin commit that built it, so another Odin's build of the same
  sources is another binary, and switching branches back and forth needs no rebuild (`CLI_KEEP`).
- **The Odin version:** the binary refuses to run when it was built with an Odin other than the pin
  (`check_odin_version`). Through the shims it always matches: a pin change changes the `odin` executable in the
  manifest, which rebuilds the binary.

## Pins

`pins.cfg` holds every pin: Odin, Godot and its export templates, OLS (odinfmt), unified-box3d, the EOS SDK's
version. It is Godot's ConfigFile syntax with one value per line, so the shims read it with shell builtins before any
Odin exists (`Config`, `pin`). Odin is pinned by tag (the release) and commit (what `odin version` reports). Every
download that ends up in a toolchain or a shipped build is pinned by SHA-256. CI's caches are keyed by the file's
hash: any pin change refetches everything once.

## Commands

A command (`Command`) names the options struct of each form it parses, and `parse` refuses another, so `uni help`'s
usage lines and each `-h` are made from the same fields and tags that parse the arguments and cannot drift from what
the command accepts. Every command rejects unknown arguments. Progress goes to stderr, the result to stdout: one line,
or one JSON object (`Result`). The command lines it runs are echoed only when verbose, and when one fails. Exit 0 ok,
1 failed, 2 usage.

**Timings.** Every command prints how long it took, and `test` each suite's time: that is how a slowdown shows
(AGENTS.md, Non-negotiables). Nothing is held to a wall-clock budget: one machine's busy minute or a slower CI runner
would make it noise. The simulation's own speed is `bench`'s, judged against the frame (`BENCH_TARGET_US`).

**Builds** go through manifests: an output records the sizes and times of every source file and directory it was
built from, the odin executable, and its command line as the key (`stale`, `finish_build`). Every command builds only
what is stale, `build` included, and starts its builds at once.

**Game windows.** A game window can be muted, placed on a screen and kept from taking focus (`Window_Opts`,
`with_window`). `run` leaves each to its caller; a check's window (a tool script's, coop's, this repo's view bench) is
always all three, on the leftmost screen (`AGENT_WINDOW`). The editor ignores the project override that keeps focus
away, and takes focus.

## Local settings

A git-ignored `.env` at the project root holds this checkout's `UNIFIED_*` variables: local paths (`UNIFIED_GODOT`,
`UNIFIED_EOS_SDK`, `UNIFIED_BOX3D`) and the runtime's own knobs (`UNIFIED_EOS_LOG`, ...). One `KEY=value` per line,
`#` comments and blank lines; no quotes, `export` or expansion; any other key is an error (`env_parse`). The file wins
over the shell's environment, and every process the CLI starts inherits the merged environment (`env_load`). A game
opened in Godot directly, not through `uni editor`, doesn't see it.

## Line endings

LF everywhere (`.gitattributes`), CRLF for batch files, which cmd.exe misreads with LF. The config readers
(`pins.cfg`, `.env`) accept either.

## Tool scripts

unified's own Godot tooling (`src/godot/tools`: the tool base, validate, coop, the level exporter) is mirrored into
every Godot project the CLI runs Godot on, as `addons/unified/`, before every Godot run (`sync_tools`). A game's own
Godot code is all in the game; nothing else is mirrored. Everything else is where the game likes it, but for two
fixed places: its tool scripts are `game/tools/<name>.gd` (`tool_script`), and a new level scene goes in
`game/levels/` (`level_scenes`).

A tool script prints one `UNIFIED_RESULT {json}` line (`ok`, `errors`, its own data). The godot suite's steps, `tool`,
`coop` and `bake` run tool scripts strictly (`Tool_Run`, `judge_tool`): a failing exit, a missing or `ok: false`
result, or what `godot_problems` names (an `ERROR` line, a leak at exit, a GDScript warning, a warning from a
`res://game/` script) fails the run; the editor and session steps judge their output by `godot_problems` too. `run`
and `editor` only report. A
headless run has Godot's debugger on and a `quit` line on its stdin, so a script error ends it at once (`Run`).

## Test suites

`test` runs suites (`Suite`): the public ones (`public_suites`) and a project's own (`add_suites`), each optionally
with a long variant (by hand, never in CI). `test` passes each the run's options (`Test_Options`), so a `test` that
`verify` nests keeps its own. A suite that mostly waits (`Suite.beside`) runs beside the others in a child `uni test
--suite <name>`, started once its `prepare` has made current what it shares with them. Suites are quiet on success: a passing one prints only warnings, and a passing
child's log is cut to its warnings (`child_log`).

- `odin`: every test package, or the named game's tests only (the inner loop of game work), built through their
  manifests so an unchanged tree only runs (`suite_odin`). The test root compiles optimised: the sim tests need it.
  A project's unoptimised root (`Project_Config.unoptimized_tests`: this repo's tooling tests) compiles beside it on
  a quarter of the cores, since its tests run as fast without optimisation and optimising them would be a third of
  the optimised compile; both binaries then run at once. A binary never runs bare: Odin's runner freezes a crashed
  test's thread, so a lock it held stays held and the run never ends; a watchdog kills it shortly after a crash or
  when it has hung (`TEST_HANG_TIMEOUT`), and names the crashed and still-running tests (`run_test_binaries`).
- `box3d-debug`: the odin suite's binaries again, against Box3D's debug library, whose asserts trap what the release
  library lets through.
- `godot`: each game under headless Godot, the games in parallel (`suite_godot`, `GODOT_STEPS`), without the EOS
  SDK, as on CI. A headless editor run (an import, the `editor` step) has the project's own editor settings and
  cache (`editor_env`): editors on several projects at once never share Godot's per-user files.

Benchmarks are no suite: `bench` runs each game's standard benchmark and its sessions on the virtual clock, plus the
project's own rows, into `.out/bench.json`, reported and never gated by time (`uni bench -h`, `BENCH_TARGET_US`).

## The template game

`init` makes a game from `examples/minimal_3d`, the smallest complete game, which CI builds, tests and runs on every
push: a new game passes its own `verify` at once. In a game repo it adds `unified` as a submodule pinned at a pushed
commit, never a local one, so the repo clones anywhere, and writes the game and the shims from that submodule, never
from this checkout, so they always match the library they build against (`cmd_init`).

## Dependencies

Every dependency is pinned, checked against its SHA-256 and written to a temp path, then renamed into place.

- **Downloads:** the system curl (`download`); SHA-256 in Odin; our own zip reader and writer (`zip.odin`), which
  reads only the members it needs out of a remote archive over HTTP byte ranges.
- **Godot:** the pinned editor in the per-user cache; `UNIFIED_GODOT` may name a local install that reports exactly
  the pinned version (`godot`).
- **Box3D:** unified-box3d, Box3D ported to Odin, as a shared library with upstream's C API, headers and Odin
  bindings, unpacked into `.out/unified-box3d/`, or the local checkout `UNIFIED_BOX3D` names (`ensure_box3d`). A
  program loads the library from its own directory: the CLI copies it next to each output that links it
  (`stage_box3d`), and keeps each game's `.gdextension` `[dependencies]` section listing what the extension links, so
  Godot loads it with the extension and an export ships it (`write_dependencies`).
- **EOS SDK:** never fetched; read where `UNIFIED_EOS_SDK` names it (`eos.odin`). Without it a game builds and plays
  single player and LAN.
- **odinfmt:** built from the pinned OLS commit; no other odinfmt is used, so CI and the format hook agree
  (`ensure_odinfmt`, `fmt_hook`).

## Testing

`tests/cli/` tests the library parts in `uni test`. `uni selftest` (this repo) proves the bootstrap, `init`, the
template and the test watchdog end to end, from a fresh clone of the committed HEAD with an empty per-user cache. It
runs only when called (before tooling PRs, after a pin or toolchain change), never in `verify` or CI. CI runs every
command through the shims, as a developer does.
