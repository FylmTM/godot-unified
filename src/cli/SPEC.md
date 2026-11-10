# cli

Draft for sign-off (#20, PR #98). Decisions from the tooling sitting (#5) and the spec review; the reasoning behind
them is in #98's description.

The `unified` CLI: one Odin binary per project that builds, tests, checks and runs games, in this repo and in a game
repo that pins `unified` as a submodule. It replaces every `tools/*.py` script; Python is no longer a requirement.
`unified:cli` is the public part, a library: each project compiles it with its own commands into its CLI. (The
headless binary's command line, formerly `unified:headless/cli`, is `unified:headless/modes`: package names are
unique program-wide.)

## Requirements

Installed by the developer, nothing else: **Odin** at the exact pinned version (`pins.cfg`), what Odin needs anyway
(clang on macOS and Linux; Visual Studio Build Tools with the C++ Clang tools on Windows), **git** (+ LFS) and
**curl** (shipped with macOS, Windows 10+ and Linux). A different Odin is refused with the pinned version and how to
install it; nothing downloads Odin locally (a downloading shim is #95). CI downloads the pinned Odin in a workflow
step that reads `pins.cfg`. Everything else (Godot, export templates, odinfmt, Box3D, Dear ImGui, the EOS SDK) the
CLI fetches or builds, pinned and hash-checked.

## Layout

```
<project>/            this repo, or a game repo (a Godot project at its root)
  unified, unified.cmd  shims (committed; `init` writes them in a game repo)
  tools/              the project's CLI: package main, imports unified:cli, adds the project's commands
                      (this repo: the private commands; a game repo: `init` writes main.odin and a .gdignore)
  unified/            game repo only: the submodule, always at this path
  pins.cfg            this repo only: every pin (Odin, Godot, templates, OLS, Box3D, Dear ImGui, EOS SDK)
  .out/               everything generated, git-ignored, safe to delete (this repo's root `out/` becomes `.out/`)
    cli/              the CLI binaries (unified-<hash>), `current`, build manifests
    godot/<version>/  the pinned Godot editor (export templates stay in Godot's user directory)
    odinfmt/          odinfmt built from the pinned OLS commit
    timings.json      each command's last time against its budget
```

Box3D, Dear ImGui and the EOS SDK stay under `third_party/<dep>/` in the `unified` checkout (the submodule in a game
repo): their bindings name them by relative path (`foreign import`). A game is a directory with `project.godot` and
`simulation/`: the project root, else every `games/*/`. Commands take `[game]`, optional when there is one.

## Bootstrap and self-rebuild

- **Shims** (sh and cmd, a few lines each): if `.out/cli/current` names an existing binary, run it with the
  arguments; else check `odin` is on PATH (else say how to install the pinned one) and
  `odin build tools -collection:unified=<unified>/src -o:minimal -out:.out/cli/unified-bootstrap[.exe]`, then run it.
- **The binary checks itself** before every command: its manifest (built with
  `-export-dependencies:json`: every source file outside the Odin install, plus the `odin` executable) holds sizes,
  times and a content hash. Sizes and times match: run (~1 ms). Else hash; same hash: refresh the times, run. Else
  rebuild to a temp file, rename it to `unified-<hash>`, write `current`, run it with the same arguments. On
  Windows the running `.exe` is renamed aside and deleted on a later run. No lock: concurrent rebuilds write the same
  file. A CLI source that doesn't compile stops with the compiler's error.
- **Odin version:** the binary compares the version it was built with (`ODIN_VERSION`) against the pin, at no cost;
  a changed `odin` executable shows in the manifest and leads to a rebuild, so the check follows the installed Odin.
- **Imports:** `unified:cli` and the project's `tools/` import only `core:` (and each other); library edits never
  rebuild the CLI. The one planned exception: the control socket's message types.
- **Build mode `-o:minimal`**: 0.27 s builds, SHA-256 at 186 ms/100 MB; measure again when the CLI does real CPU work.

## Pins

`pins.cfg`, Godot's ConfigFile syntax: `[section]` and `key = "value"` lines, one value per line, so a workflow that
runs no repository code (`eos-sdk.yml`) reads it with `sed`. CI cache keys come from `unified ci cache-key <dep>`
(pins, recipe, compiler identity) or `hashFiles('pins.cfg')`, never from tool sources. The workflows' `ODIN_TAG` and
`GODOT_VERSION` copies go.

## Commands

Every command rejects unknown arguments; `-h` on any command prints its options and budget; `unified help` lists
them all. Progress goes to stderr, the result to stdout: one line, or one JSON object with `--json` (every command:
the framework prints the result each command returns). Exit 0 ok, 1 failed, 2 usage. A warm run over its budget
prints `OVER BUDGET` (not a failure; CI allows 3x); a cold run (it fetched or built a dependency) is exempt and says
so. Commands that need a game library or headless binary rebuild it when its manifest is stale; `build` always builds.

Public (`unified:cli`, every project):

| Command | What | Replaces |
|---|---|---|
| `setup [--check]` | fetch and build everything this project needs; print versions (`--check`: report only) | `ci.py odinfmt/godot/ensure-ninja`, `box3d.py`, `imgui.py`, `eos.py ensure` |
| `build [game] [--mode dev\|release\|debug]` | each game's extension and headless binary, in parallel | `build`, `game build` |
| `run [game] [-- args]`, `editor [game]` | the game in a window, the Godot editor on it | `game run`, `game editor` |
| `test [name...]` | every test package in one compile (unit, end-to-end suites, lint); optional test-name filter | `test` |
| `vet` | `odin check`, strict flags, every target and define variant | `vet` |
| `fmt [--check] [path...]`, `fmt --hook` | odinfmt (pinned); `--hook`: the one file in a Claude Code hook's JSON | `fmt` |
| `check [game] [--only step,...]` | the game's headless Godot checks (below) | `godot-checks`, `game headless/editor-check/session-check/validate/walk/tour/import` |
| `tool [game] <script> [--window] [--shots] [-- args]` | run `game/tools/<script>.gd` (headless unless `--window`) | `game play/shots/tour --shots\|--frames` |
| `coop [game] [--window] [--rejoin] [--lan]` | host and joiner processes, a real lobby | `game coop` |
| `levels [game] [--check]` | export `.level` files from their scenes | `game export-level` |
| `bench [game...]` | each game's standard benchmark, alone, on a release build | `bench` |
| `regen <game>` | regenerate a game's reference run | `regen` |
| `init <dir>` | a new game repo: layout, shims, `tools/main.odin`, `.gitignore`, the submodule | new |
| `all` | the project's gate (this repo: everything CI runs; never `selftest`) | `all` |
| `version` | the CLI's source hash, Odin, and the pins | new |

Private (this repo's `tools/`; promoted to public only when a game needs one):

| Command | What | Replaces |
|---|---|---|
| `gen [--force]` | the Godot bindings, `src/gdext/*.gen.odin` | `gen` |
| `bindings-test` | `tests/godot` and `tests/godot_views` under headless Godot | `godot-test` |
| `udp-test` | the toy's relay and 3 clients over real UDP on the real clock | `check` |
| `release [game] (--version V \| --tag T) [--no-smoke]`, `release notes [game] --tag T` | a playable build: export, version stamp (into `project.godot` and `export_presets.cfg` in place, restored byte for byte), sign, zip, smoke test; requires the EOS IDs when the extension imports `unified:eos` | `release.py` |
| `eos upload` | pack the pruned EOS SDK per platform and upload it to the draft release | `eos.py pack/upload` |
| `board list\|set` | the work board through `gh` | `board` |
| `ci summary`, `ci cache-key <dep>` | the job summary; a dependency's cache key | `ci.py summary`, `ci.py compiler-id` |
| `selftest` | run only when asked for, never by `all`: fresh clone in a temp folder, bootstrap with only Odin, `init` a game outside the repo with the clone as its submodule, then build, test, check and run it headless | new |

Dropped: `game import` (every command imports when stale), `eos defines` and the unused `--json` of `eos.py`,
`release.py godot`, `ci.py godot`, `box3d.py --cc/--cxx` (stamps cover the compiler instead), ninja and CMake.

## Checks and tool scripts

- **Tool scripts** are a game's `game/tools/<name>.gd`, run with Godot's `-s`. Each prints one
  `UNIFIED_RESULT {json}` line through a helper in `godot_host` (`ok`, `errors`, its own data); the CLI passes
  `--no-settings`, `--shots=res://.out/shots/<name>` with `--shots`, and the arguments after `--`.
- **Every run is strict:** a failing exit, a missing or `ok: false` result, an `ERROR` line, a leak at exit or a
  GDScript warning fails. Windowed runs restore the frontmost app on macOS.
- **`check` steps**, each run when the game has what it needs: `import` (stale imports only), `editor` (the extension
  loads, no errors), `session` (a headless session; its checksums equal the offline headless binary's), `levels`
  (`--check`), then each tool script the game has of `validate`, `session_check`, `walk`, `tour` (quick). `--only`
  picks steps.
- **Benchmarks:** a headless binary's `bench` mode with no arguments runs the game's standard benchmark (its
  arguments live in the game); the target, a forward step plus an 8-tick re-sim within 6 ms, is unified's.

## Dependencies

- **Downloads:** `curl` (HTTPS, retries, byte ranges: only the needed members of the 1.3 GB templates archive),
  SHA-256 in Odin, our own zip reader and writer (`core:compress`), unpacked to a temp path and renamed into place.
- **Godot:** the pinned editor in `.out/godot/<version>/`; `$GODOT` may name a local install that reports the exact
  pinned version. Export templates (`release` only) go where Godot looks for them, its user directory
  (`export_templates/<version>.stable`), checked against their pinned hashes.
- **Box3D and Dear ImGui:** git fetches the pinned commit (Box3D: plus `third_party/box3d.patch`, exactly); the CLI
  calls clang (clang-cl and llvm-lib on Windows, with the MSVC environment from vswhere and vcvarsall passed to the
  child processes) on every source in parallel and archives them. The flags are ours (`-O2 -DNDEBUG
  -ffp-contract=off -DBOX3D_DISABLE_AVX2`, static CRT `/MT` on Windows, macOS 11.0 minimum), and the build checks
  the source list against Box3D's CMakeLists on a pin change. One stamp scheme: pins, recipe, flags, platform and
  compiler identity. The headers the bindings tests read are kept with the build.
- **EOS SDK:** from a local SDK (`$UNIFIED_EOS_SDK`, `~/tools/eos-sdk`) or the draft release (needs `gh`), staged in
  `third_party/eos/`; the library is copied next to the game library. Missing: a warning for `build`, an error for
  `release`.
- **odinfmt:** built from the pinned OLS commit into `.out/odinfmt/`; no `$ODINFMT` override.

## Testing

`tests/cli/` tests the library parts (manifest and self-check, pins, zip, argument handling, stamps) in
`unified test`. `unified selftest` proves the bootstrap and `init` end to end; it runs only when called explicitly
(before tooling PRs, after a pin or toolchain change), locally, and joins CI only if it's very fast. CI runs every command through the shims, as a developer does.

## The switch

One PR: `src/cli/`, `tools/` (Odin), `pins.cfg`, the shims; `tools/*.py` deleted; workflows, `.claude/` (the
format hook calls `./unified fmt --hook`), skills, AGENTS.md, README.md, `tools/README.md`, specs, game READMEs and
the in-game messages that name `dev.py` move to `unified`; root `out/` becomes `.out/`; the games' tool scripts move
to `UNIFIED_RESULT`; each game's headless descriptor gets its benchmark arguments. Done when `unified all` passes, CI
is green on all four platforms, and `unified selftest` passes on Windows and macOS.
