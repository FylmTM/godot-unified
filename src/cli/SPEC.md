# cli

Signed off 2026-11-11 (#20, PR #98; the reasoning behind each decision is in #98's description). Built in #20.

`uni`, the unified CLI: one Odin binary per project that builds, tests and runs games, in this repo and in a game
repo that has `unified` as a git submodule. `unified:cli` is the public part, a library: each project compiles it
with its own commands into its CLI (`tools/`). The only requirements are Odin and what it needs anyway.

## Requirements

Installed by the developer, nothing else: **Odin** at the exact pinned version (`pins.cfg`), what Odin needs anyway
(clang on macOS and Linux; Visual Studio Build Tools with the C++ Clang tools on Windows), **git** and **curl**
(shipped with macOS, Windows 10+ and Linux). An Odin other than the pinned tag and commit is refused with the pin;
nothing downloads Odin locally (a downloading shim is #95). CI installs the pinned Odin with
`.github/actions/odin`, which reads `pins.cfg`. Everything else (Godot, export templates, odinfmt, Box3D, Dear
ImGui, the EOS SDK) the CLI fetches or builds, pinned and hash-checked.

## Layout

```
<project>/            this repo, or a game repo (a Godot project at its root)
  uni, uni.cmd        the shims (committed; `init` writes them in a game repo)
  tools/              the project's CLI: package main, imports unified:cli, adds the project's commands
                      (this repo: the private commands; a game repo: main.odin and a .gdignore from `init`)
  unified/            game repo only: the submodule, always at this path
  pins.cfg            this repo only: every pin (Odin, Godot, templates, OLS, unified-box3d, Dear ImGui, EOS SDK)
  .env                git-ignored: this checkout's UNIFIED_* settings (below)
  .out/               everything generated, git-ignored, safe to delete
    cli/              the CLI binaries (uni-<hash>), `current`, their manifests (`<binary>.inputs`)
    godot/<version>/  the pinned Godot editor (export templates stay in Godot's user directory)
    odinfmt/          odinfmt built from the pinned OLS commit
    <mode>/           the headless binaries (dev, release, debug), each with a build manifest
    timings.json      each command line's last time against its budget
```

Box3D (`third_party/unified-box3d/`), Dear ImGui and the EOS SDK live under `third_party/` in the `unified` checkout
(the submodule in a game repo): their bindings name them by relative path (`foreign import`). Every Odin build gets
two collections: `unified` (`src/`) and `box3d` (unified-box3d, imported as `box3d:bindings`). A game is a directory
with `project.godot` and `simulation/`: the project root, else every `games/*/`. Commands take `[game]`, optional
when there is one. In a game repo, `test`, `vet`, `fmt` and `verify` cover the game only: never the submodule, which
`unified`'s own CI proves.

## Bootstrap and self-rebuild

- **Shims** (sh and cmd, a few lines each): if `.out/cli/current` names an existing binary, run it with the
  arguments; else check `odin` is on PATH and `odin build tools -collection:unified=<unified>/src -o:minimal`
  into `.out/cli/uni-bootstrap`, with its dependency list, then run it. The bootstrap binary installs itself as
  `uni-<hash>`.
- **The binary checks itself** before every command: its manifest (from `-export-dependencies:json`: every source
  file outside the Odin install, their directories and the `odin` executable) holds sizes, times and a content hash.
  Sizes and times match: run (~1 ms). Else hash; same hash and no new file: refresh the times, run. Else rebuild to a
  temp file, rename it to `uni-<hash>`, write `current`, and run it with the same arguments. A rebuild keeps the
  newest four binaries (switching branches back and forth needs none); a binary still running on Windows stays until
  a later rebuild. No lock: concurrent rebuilds write the same file. A CLI source that doesn't compile stops with the
  compiler's error.
- **Odin version:** the binary compares the tag and commit it was built with (`ODIN_VERSION`, `ODIN_VERSION_HASH`)
  against the pin, at no cost, and refuses a mismatch (a build without a commit hash: a warning). The tag alone isn't
  enough: a build from Odin's master reports the month's tag. A changed `odin` executable shows in the manifest and
  leads to a rebuild, so the check follows the installed Odin.
- **Imports:** `unified:cli` and the project's `tools/` import only `core:` (and each other; the lint holds it):
  library edits never rebuild the CLI. The one planned exception: the control socket's message types.
- **Build mode `-o:minimal`**: ~0.3 s builds, SHA-256 at 186 ms/100 MB; measure again when the CLI does real CPU
  work.

## Pins

`pins.cfg`, Godot's ConfigFile syntax: `[section]` and `key = "value"` lines, one value per line, so a workflow that
runs no repository code (`eos-sdk.yml`, `.github/actions/odin`) reads it with `sed`. Odin is pinned by tag and
commit. CI cache keys come from `uni ci cache-key <dep>` (the dependency's pins, the recipe version and, for what we
compile, the compiler's version), never from tool sources.

## Commands

Every command rejects unknown arguments; `-h` on any command prints its options and budget; `uni help` lists them
all. Progress goes to stderr, the result to stdout: one line, or with `--json` (any command) one object
`{command, ok, summary, seconds, cold, data}`. Exit 0 ok, 1 failed, 2 usage. A warm run over its budget prints
`OVER BUDGET` (not a failure; CI allows 3x); a cold run (it fetched or built a dependency, or imported a project) is
exempt and says so. Commands that need a game library or headless binary rebuild it when its build manifest is
stale; `build` always builds.

Public (`unified:cli`, every project):

| Command | What |
|---|---|
| `setup [--check]` | fetch and build everything this project needs; print each dependency's version and source (pinned download, `.env`, environment; with `UNIFIED_BOX3D`, builds that unified-box3d checkout) (`--check`: report only) |
| `clean [--check]` | remove what the CLI built or fetched: every `.out/` and `.godot/` outside hidden directories, the `third_party/` dependencies, the generated bindings; not the running CLI, `.env` or Godot's export templates (`--check`: list only). Fails on what a running process holds (Windows) |
| `build [game] [--mode dev\|release\|debug]` | every headless binary and the game's (or every game's) extension |
| `run [game] [-- args]`, `editor [game]` | the game in a window, the Godot editor on it |
| `test [game] [--suite s,...] [--only name,...]` | the test suites (below); plain `test` runs the `odin` suite, `--suite all` every one; `--only` picks tests (`odin`) or steps (`godot`) |
| `vet` | `odin check`, strict flags, every target and define variant, the CLI included |
| `fmt [--check] [path...]`, `fmt --hook` | odinfmt (pinned); `--hook`: the one file a Claude Code edit names (the hook's JSON on stdin) |
| `tool [game] <script> [--window] [--shots] [--cold] [-- args]` | run `game/tools/<script>.gd`, headless unless `--window`; `--cold` clears the shader caches first |
| `coop [game] [--window] [--rejoin] [--lan]` | host and joiner processes, a real lobby |
| `bake [game] [--check]` | bake `.level` files from their scenes (`--check`: fail if one is stale) |
| `bench [game...]` | each game's standard benchmark, alone, on a release build (`.out/bench.json`) |
| `record-reference <game>` | record a game's reference run anew (the committed log, trace and snapshot `test` replays) |
| `init <dir> [--unified <url>]` | a new game repo from the template game (below), the shims, `tools/`, `.gitignore`, the submodule |
| `verify` | the gate before handing work back or merging: `fmt --check`, `vet`, `test --suite all`, `bench` (this repo: everything CI runs; never `selftest`) |
| `version` | the CLI's source hash, Odin, and the pins |

Private (this repo's `tools/`; promoted to public only when a game needs one):

| Command | What |
|---|---|
| `godot-gen [--force]` | the Godot bindings, `src/gdext/*.gen.odin` (every command that needs them generates them when stale) |
| `release [game] [--tag <game>-v<version> \| --version V] [--no-smoke]`, `release notes [game] --tag T` | a playable build (the `release` skill): export, version stamp (into `project.godot` and `export_presets.cfg` in place, restored byte for byte), sign, zip, smoke test; requires the EOS IDs when the extension imports `unified:eos` |
| `eos upload` | pack the pruned EOS SDK per platform (reproducible zips) and upload it to the draft release |
| `board list\|set` | the work board through `gh` |
| `ci summary`, `ci cache-key <dep>` | the job summary (markdown); a dependency's cache key |
| `selftest` | run only when asked for, never by `verify`: a fresh clone of HEAD in `.out/selftest/`, bootstrapped with only Odin, `init` a game outside it with the clone as its submodule, then that game's `build`, `test --suite all` and `verify` |

## Local settings

A git-ignored `.env` at the project root holds this checkout's `UNIFIED_*` variables: local paths (`UNIFIED_GODOT`,
`UNIFIED_EOS_SDK`, `UNIFIED_BOX3D`) and the runtime's own knobs (`UNIFIED_EOS_LOG`, ...). One `KEY=value` per line, `#` comments and
blank lines; no quotes, `export` or expansion. Any key not starting with `UNIFIED_` is an error. The file wins over
the shell's environment, and the CLI passes the merged environment to every process it starts (Godot, headless
binaries, `coop`). A game opened in Godot directly, not through `uni editor`, doesn't see it. `init` git-ignores it.

## Test suites and tool scripts

- **Tool scripts** are a game's `game/tools/<name>.gd`, run with Godot's `-s`. Each prints one
  `UNIFIED_RESULT {json}` line (`ok`, `errors`, its own data); the CLI passes `--no-settings`,
  `--shots=res://.out/shots/<name>` with `--shots`, and the arguments after `--`. Headless runs have the debugger on
  (`-d`), which prints GDScript warnings. A script quits through the game's own quit (audio stopped first): a live
  playback at exit is a leak.
- **Strict:** in `godot` suite steps, `tool`, `coop` and `bake`, a failing exit, a missing or `ok: false` result, an
  `ERROR` line, a leak at exit or a GDScript warning fails. `run` and `editor` only report. Windowed runs give focus
  back to the frontmost app on macOS.
- **Test suites**, each with its own budget (`test`'s budget is the sum of its suites'); a project's `tools/` adds
  its own with `cli.add_suites` (this repo: `net`, `godot-bindings`):
  - `odin`: the test packages in one compile (this repo: every package under `tests/`, the games' suites included;
    a game repo: its `simulation/tests`): unit tests, the library's black-box tests, end-to-end suites, the
    reference-run replays, the Box3D golden trace, the determinism and import lint. The inner loop.
  - `godot`: each game under headless Godot, each step run when the game has what it needs: `import` (stale imports
    only), `editor` (the extension loads, no errors), `session` (a headless session; its checksums equal the offline
    headless binary's), `bake` (`--check`), then each tool script the game has of `validate`, `session_check`,
    `walk` (`ui_walk.gd`), `tour` (quick). A step the game can't run prints `skipped: <why>`.
  - `net` (this repo): the toy's relay and 3 clients (one on a bad-network profile) over real UDP on the real clock,
    960 ticks at 64 Hz (at least 15 s, so never in the inner loop); checksums agree every 16th tick, 0 desyncs
    (`.out/net.json`, `.out/net/`).
  - `godot-bindings` (this repo): `tests/godot` and `tests/godot_views` under headless Godot.
- **Benchmarks:** a game's headless descriptor names its standard benchmark (`Headless.bench`: entities held,
  rollback window, ticks), which its `bench` mode runs with no arguments; the target, a forward step plus an 8-tick
  re-sim within 6 ms, is unified's.

## The template game

`init` writes `template/`: every file a `.tmpl` with `__GAME__` for the game's name (the directory's: lowercase
letters, digits and `_`). It is a complete small game, each player moving a dot: its sim package, headless binary
(with a standard benchmark), extension (one scene view), main scene with a `UnifiedSession`, and tests (sync-test
under rollback, a repeatable run, the determinism lint), so the new repo passes its own `verify` at once. The
Odin files are formatted after the name is put in (it changes line lengths).

## Dependencies

- **Downloads:** `curl` (HTTPS, retries, byte ranges: only the needed members of the 1.3 GB templates archive),
  SHA-256 in Odin, our own zip reader and writer (`core:compress`: stored and deflated members, Zip64 sizes, Unix
  modes and symlinks), written to a temp path and renamed into place.
- **Godot:** the pinned editor in `.out/godot/<version>/`; `UNIFIED_GODOT` may name a local install that reports the
  exact pinned version (anything else is refused; the check is remembered per file). Export templates (`release`
  only) go where Godot looks for them, its user directory (`export_templates/<version>.stable`), checked against
  their pinned hashes.
- **Box3D:** unified-box3d, Box3D ported to Odin, as a shared library (static Odin-in-Odin linking clashes) with
  upstream's C API, headers and Odin bindings. By default this platform's zip of the pinned release (`[box3d]`: repo,
  tag, a SHA-256 per platform), checked and unpacked with its top folder flattened into `third_party/unified-box3d/`
  (a stamp of the pin makes the warm check free). `UNIFIED_BOX3D` may name a local unified-box3d checkout instead:
  the `box3d` collection points there, and `setup` runs its `b3 build` and `b3 build --debug` (other commands only
  build a missing library). Programs link `lib/<platform>/` (`--mode debug`: `-define:BOX3D_LIB_DEBUG=true` and
  `lib/<platform>-debug/`) and load the library from their own directory: the CLI copies it next to each output that
  links it (`.out/test/`, `.out/<mode>/`, `.out/record-reference/`, a game's `.out/bin/`), where Odin's default rpath
  (`$ORIGIN`, `@loader_path`; the library's install name is `@rpath/libbox3d.dylib`, its soname `libbox3d.so`) and
  the Windows DLL search find it. A game's `.gdextension` lists it under `[dependencies]`: Godot loads it from the
  extension's folder and an export ships it.
- **Dear ImGui:** git fetches the pinned commit and dear_bindings' release files; the CLI calls clang (clang-cl and
  llvm-lib on Windows, with the MSVC environment from vswhere and vcvarsall passed to the child processes) on every
  source in parallel and archives them, `-O2 -DNDEBUG`, the static CRT `/MT` on Windows, macOS 11.0 minimum. Its
  stamp: pins, recipe, flags, platform and compiler identity.
- **EOS SDK:** from the local SDK `UNIFIED_EOS_SDK` names, else this host's part of the draft release (needs `gh`),
  staged in `third_party/eos/`; the library is copied next to the game library. Missing: a warning for `build`, an
  error for `release`.
- **odinfmt:** built from the pinned OLS commit into `.out/odinfmt/`; no other odinfmt is used.

## Testing

`tests/cli/` tests the library parts (the config and `.env` parsers, zip, build manifests, SHA-256, small parsers)
in `uni test`. `uni selftest` proves the bootstrap, `init` and the template end to end; it runs only when called
(before tooling PRs, after a pin or toolchain change), locally. It tests the committed HEAD, so it refuses a working
tree with uncommitted changes. CI runs every command through the shims, as a developer does (`uni.cmd` on Windows).
