# cli

Status: signed off 2026-11-18 (#329)

`uni`, the unified CLI: one Odin binary per project that builds, tests and runs games, in this repo and in a game repo
that has `unified` as a git submodule. `unified:cli` is the public part, a library: each project compiles it with its
own commands into its CLI (`tools/`). The commands and their options are `uni help` and `uni <command> -h`; this spec
is how the CLI works.

## Requirements

Installed by the developer, nothing else: what Odin needs (clang on macOS and Linux; Visual Studio Build Tools on
Windows: its linker and the Windows SDK), **git** and **curl** (shipped with macOS, Windows 10+ and Linux). Everything
else the CLI or its shims fetch or build, pinned and hash-checked: Odin, Godot, export templates, odinfmt, Box3D.
Nothing it builds is C or C++. The EOS SDK is the exception: Epic's licence keeps it out of the repo and CI, so a
machine that plays online downloads it from Epic and names it with `UNIFIED_EOS_SDK` (`docs/EOS.md`).

## Layout

```
<project>/            this repo, or a game repo (a Godot project at its root)
  uni, uni.cmd        the shims (committed; `init` writes them in a game repo)
  tools/              the project's CLI: package main, imports unified:cli, adds the project's commands
  unified/            game repo only: the submodule, always at this path
  pins.cfg            this repo only: every pin (Odin, Godot, templates, OLS, unified-box3d, EOS SDK)
  .env                git-ignored: this checkout's UNIFIED_* settings (below)
  .out/               everything generated, git-ignored, safe to delete
    cli/              the CLI binaries (uni-<hash>-<odin commit>), `current`, their manifests (`<binary>.inputs`)
    odinfmt/          odinfmt built from the pinned OLS commit
    <mode>/           the headless binaries (dev, release, debug), each with a build manifest
    unified-box3d/    the pinned release's library, headers and Odin bindings (the `box3d` collection)

<per-user cache>/unified/   pinned downloads shared by every checkout, a directory or file per version and SHA-256
                      (%LOCALAPPDATA% on Windows, ${XDG_CACHE_HOME:-~/.cache} elsewhere; `clean --cache` removes
                      godot/ and downloads/)
  odin/<tag>/         the pinned Odin release, downloaded by the shims
  godot/<version>-<sha256>/   the pinned Godot editor: one path for the OS to remember (Windows Firewall)
  downloads/          unified-box3d-<tag>-<platform>-<sha256>.zip, the pinned release each project unpacks
```

A download into the cache goes to a part file of the process's own, then is renamed into place: checkouts fetching
the same pin at once each finish, and the first rename wins. Every Odin build gets two collections: `unified`
(`src/`) and `box3d` (unified-box3d's bindings, `box3d:bindings`). A game is a directory with `project.godot` and
`simulation/`: the project root, else every `games/*/`. Commands take `[game]`, optional when there is one. In a game
repo, `test`, `vet`, `fmt` and `verify` cover the game only, never the submodule, which `unified`'s own CI proves.

**What a project adds.** The conventions above are all a game repo needs. A project with more registers it in its
`tools/main.odin` with `cli.configure` (`Project_Config`): this repo's test root (`tests/`, compiled with
`-all-packages`), the toy game's headless binary and end-to-end suite, the Godot test extensions `vet` checks, the
directories `fmt` formats, that its tests link Box3D, `vet`'s check of `uni init`'s template, and `bench`'s physics
row. Its own test suites go in with `cli.add_suites`, its commands with `cli.run`. The public library knows nothing of
this repo's layout but `init --in-repo`.

## Bootstrap and self-rebuild

- **Shims** (POSIX sh and cmd, nothing else) read `pins.cfg`'s `[odin]` with shell builtins, then put the pinned
  release first on PATH: `<cache>/unified/odin/<tag>`, downloaded once when missing (curl), its SHA-256 checked
  against `pins.cfg` (`sha256sum`/`shasum`; `certutil`), unpacked next to its final directory (`tar`; the system
  `tar.exe` reads the Windows zip; Git Bash: `unzip`) and renamed into place (once per machine and pin).
  No other Odin is used. Then: if `.out/cli/current` names an existing binary, run it with the arguments; else `odin
  build tools -collection:unified=<unified>/src -o:minimal` into `.out/cli/uni-bootstrap`, with its dependency list,
  and run that; it installs itself as `uni-<hash>-<odin commit>`.
- **The binary checks itself** before every command: its manifest (from `-export-dependencies:json`: every source
  file outside the Odin install, their directories and the `odin` executable) holds sizes, times and a content hash.
  Sizes and times match: run. Else hash; same hash and no new file: refresh the times, run. Else rebuild to a temp
  file, rename it to `uni-<hash>-<odin commit>` (the hash leaves the Odin install out; the commit keeps another
  Odin's build of the same sources apart), write `current`, and run it with the same arguments. A rebuild keeps the
  newest four binaries; one still running on Windows stays until a later rebuild. No lock: concurrent rebuilds write
  the same file. A CLI source that doesn't compile stops with the compiler's error.
- **Odin version:** the binary compares the tag and commit it was built with (`ODIN_VERSION`, `ODIN_VERSION_HASH`)
  against the pin and refuses a mismatch (a build without a commit hash: a warning). Through the shims it always
  matches: a pin change changes the `odin` executable in the manifest, which rebuilds the binary.
- **Imports:** `unified:cli` and the project's `tools/` import only `core:` (and each other): library edits never
  rebuild the CLI.

## Pins

`pins.cfg`, Godot's ConfigFile syntax: `[section]` and `key = "value"` lines, one value per line, so the shims read it
with shell builtins before any Odin exists. Odin is pinned by tag (the release) and commit (what `odin version`
reports). CI's caches are keyed by `hashFiles('pins.cfg')`: any pin change refetches everything once.

## Commands

Every command rejects unknown arguments. A command names the options struct of each form it parses (`Command.options`,
`parse` refuses another); `uni help`'s usage lines and each `-h` (usage, budget, every option with what it does, the
command's details) are made from those structs' fields and tags, so they cannot drift from what the command accepts.
Progress goes to stderr, the result to stdout: one line, or with `--json` (any command) one object `{command, ok,
summary, seconds, cold, data}`. The command lines it runs are echoed only with `--verbose` (any command; a `uni` it
starts inherits it), and when one fails. Exit 0 ok, 1 failed, 2 usage.

**Budgets.** Every command has a budget, seconds for a warm run (`-h` says it; `test`'s is its suites' sum), or says
why it has none (interactive, networked, the mode decides). A warm run over its budget prints `OVER BUDGET`: not a
failure (machines vary; CI allows 3x), but a bug to find (AGENTS.md). A cold run is exempt and says so: it fetched a
dependency, generated the Godot bindings, imported a project, or built something it needed first (any build through
`finish_build` but the command's own product: the test binary is `test`'s work and counts).

**Builds** go through manifests: an output's sizes and times of every source file and directory, the odin
executable, and the command line as the key (an extension's build tag is outside it). Every command builds only what
is stale, `build` included (it can be told to build everything), and starts its builds at once.

**Windows.** A game window can be muted (Godot's dummy audio driver), placed on a screen (Godot's index, or left,
right or primary, which the CLI finds from the OS in Godot's order: Windows' monitors; macOS' displays through
CoreGraphics, loaded only then; Linux' `xrandr --listmonitors`) and kept from taking focus (Godot's
`display/window/size/no_focus` through an `override.cfg` the CLI writes into the project for the run; on Windows it
opens without activation; on macOS Godot activates itself anyway, so the CLI hands the focus straight back). `run`
leaves each to its caller; a check's window (a tool script's, coop's, this repo's view bench) is always all three, on
the leftmost screen. The editor ignores the override and takes focus.

## Local settings

A git-ignored `.env` at the project root holds this checkout's `UNIFIED_*` variables: local paths (`UNIFIED_GODOT`,
`UNIFIED_EOS_SDK`, `UNIFIED_BOX3D`) and the runtime's own knobs (`UNIFIED_EOS_LOG`, ...). One `KEY=value` per line,
`#` comments and blank lines; no quotes, `export` or expansion. Any key not starting with `UNIFIED_` is an error. The
file wins over the shell's environment, and the CLI passes the merged environment to every process it starts. A game
opened in Godot directly, not through `uni editor`, doesn't see it. Line endings are git's (`.gitattributes`: LF, CRLF
for batch files); the config readers (`pins.cfg`, `.env`) accept either.

## Test suites and tool scripts

- **Shared Godot code**: a project's `games/shared` (this repo: the demo games' code) is mirrored into a game that
  uses it (its `project.godot` names `res://addons/shared/`) as `addons/shared/` before every Godot run (git-ignored
  there; a copy edited in place stops the run; a `.uid` Godot writes for a new shared script is copied back).
  unified's `src/godot/tools` (`UnifiedTool`, `UnifiedValidate`, the level exporter) is mirrored the same way into
  every Godot project the CLI runs Godot on, as `addons/unified/`. `bake` without a game also exports the project's
  own level scenes (`Project_Config.bake`; this repo: the 2D fixture `tests/level` reads).
- **Tool scripts** are a game's `game/tools/<name>.gd`, else `games/shared/tools/<name>.gd`, else unified's
  `src/godot/tools/<name>.gd`; run with Godot's `-s`. Each prints one `UNIFIED_RESULT {json}` line (`ok`, `errors`,
  its own data). Headless runs have the debugger on (`-d`, which prints GDScript warnings); a child's stdin holds
  `quit`, so a run stopped at the debugger prompt quits at once. A run killed at its timeout is killed with what it
  started. **Strict:** in `godot` suite steps, `tool`, `coop` and `bake`, a failing exit, a missing or `ok: false`
  result, an `ERROR` line, a leak at exit or a GDScript warning fails. `run` and `editor` only report.
- **Suites**, each with its own budget and, optionally, a long variant (`test --long`, by hand, never in CI).
  `test` passes each its options (`Test_Options`: `only`, `long`, `game`) and reports its budget in its Result, so a
  `test` that `verify` nests keeps its own. A suite that mostly waits (`Suite.beside`) runs, with others, in a child
  `uni test --suite <name>` beside them, started once its `prepare` has made current what it shares. Quiet on
  success: a suite prints only failures and warnings, a child `uni`'s log is cut to its warnings when it passed.
  - `odin`: the test packages in one compile (the project's test root, or the named game's `simulation/tests`: the
    inner loop of game work, without the import lint), built through its manifest so an unchanged tree only runs.
    Unit tests, the black-box tests, the end-to-end suites, the reference-run replays, the Box3D golden trace, the
    determinism and import lint. `--long` builds with `-define:UNIFIED_LONG_TESTS=true`. The binary runs under a
    watchdog (`testrun.odin`): Odin's runner freezes a crashed test's thread, so a lock it held stays held; the
    watchdog kills the binary shortly after a crash, or at the suite's CI allowance, and names the crashed and
    still-running tests. A passing run prints the runner's `[WARN]`/`[ERROR]` lines and its `Finished` line; a
    failing one the whole output (kept in `<binary>.log`).
  - `box3d-debug`: the odin suite's binary again, copied next to Box3D's debug library (same file name and ABI),
    whose asserts trap what the release library lets through (a stale id destroying another body).
  - `godot` (beside): each game under headless Godot, the games in parallel (a child `uni test <game> --suite godot`
    each), and on a machine with cores to spare a game's steps in two lanes (`editor`, `bake`, `tour` beside the
    rest; on fewer, the doubled Godot processes gain nothing). Steps, each run when the game has
    what it needs: `import` (stale imports only; every Godot run first re-imports a stale class cache), `editor` (the
    extension loads, no errors), `session` (a short headless session, longer with `--long`; its checksums equal the
    offline headless binary's), `bake` (`--check`, the view index too), then the tool scripts `validate`, `walk`
    (`ui_walk.gd`), `tour` (quick). Its `prepare` makes current what the games share: Godot, the bindings, Box3D, the
    `session` step's release headless binaries. The tool scripts run without the EOS SDK, as on CI.
- **Benchmarks:** a game's headless descriptor names its standard benchmark (`Headless.bench`: entities held,
  rollback window (default: the netcode's prediction cap), ticks), which its `bench` mode runs: every tick a step, a
  save, a checksum, then a rollback at the window and a re-sim (the worst case the netcode makes: a bound, not a
  typical frame). The first window + 64 ticks run untimed. unified's target: a step, a restore, that re-sim and a
  deep checksum within 6 ms at their p99. `bench` also runs each game's `session` on the virtual clock twice, 4
  clients whose inputs change every tick (`--script churn`: rollbacks on most ticks, a bound of real play from above)
  under `bad` (the stress case) and under `wan` with the 4th connecting halfway and joining as a player does (the
  common case and a late join), each row timing every client step that stepped the sim (the measure the target
  models), and the project's own rows (this repo: Box3D on a fixed scene, `tests/physics/bench`, what a Box3D
  upgrade compares); `.out/bench.json`, not gated by time.

## The template game

`init` adds unified as a git submodule at `unified/`, from `--unified` or this checkout's `origin`, a GitHub SSH URL
rewritten to HTTPS (unified is public: anyone and any CI clones it without keys). It pins the source's default branch
at its current commit, or `--ref` (a commit, tag or branch, fetched by name); a pushed commit, never a local one, so
the game repo clones anywhere. Then it writes the template and the shims from that submodule, never from this
checkout, so they always match the library they build against.

`init` writes `template/`: every file a `.tmpl` with `__GAME__` for the game's name (the directory's: lowercase
letters, digits and `_`), LF whatever the checkout has. It is the most basic 3D game, each player a capsule moved by
the arrow keys, with the core wiring only: its sim package, headless binary (with a standard benchmark), extension,
main scene with a `UnifiedSession`, and tests (sync-test under rollback, a repeatable run, the determinism lint), so
the new game passes its own `verify` at once. `template/repo/` is a game repo's own (a README, `.gitattributes`,
`.gitignore`, `tools/main.odin`); `--in-repo` leaves it out. The Odin files are formatted after the name is put in,
and the view index is written by the build's own code, so the first build rewrites nothing. This repo's `vet` writes
the template's Odin files for a game named `template_game` into `.out/template/` and type-checks them, so a library
API change that breaks a new game fails `verify`.

## Dependencies

- **Downloads:** `curl` (HTTPS, retries, byte ranges: only the needed members of the templates archive),
  SHA-256 in Odin, our own zip reader and writer (`core:compress`: stored and deflated members, Zip64 sizes, Unix
  modes and symlinks), written to a temp path and renamed into place.
- **Godot:** the pinned editor in the per-user cache; `UNIFIED_GODOT` may name a local install that reports the exact
  pinned version (anything else is refused; the check is remembered per file). Export templates (`release` only) go
  where Godot looks for them, its user directory, checked against their pinned hashes.
- **Box3D:** unified-box3d, Box3D ported to Odin, as a shared library with upstream's C API, headers and Odin
  bindings: this platform's zip of the pinned release, checked, kept in the per-user cache and unpacked into
  `.out/unified-box3d/` (a stamp of the pin makes the warm check free). `UNIFIED_BOX3D` may name a local
  unified-box3d checkout instead (`setup` builds it). Programs link `lib/<platform>/` (`--mode debug`:
  `lib/<platform>-debug/`) and load the library from their own directory: the CLI copies it next to each output that
  links it, where Odin's default rpath and the Windows DLL search find it. A game's `.gdextension` lists it under
  `[dependencies]`: Godot loads it from the extension's folder and an export ships it.
- **EOS SDK:** never fetched: the SDK `UNIFIED_EOS_SDK` names, its `SDK/Include/eos_version.h` checked against
  `[eos_sdk] version`; a game's build copies this host's library next to the game library. Missing: online play is
  off; `release` fails unless `--no-eos` (CI's LAN-only packages).
- **odinfmt:** built from the pinned OLS commit into `.out/odinfmt/`; no other odinfmt is used. The format hook
  (`fmt --hook`) finds the edited file's project by the nearest `uni` shim above it, so a git worktree's edits are
  formatted with its own `odinfmt.json`.

## Testing

`tests/cli/` tests the library parts (the config and `.env` parsers, zip, build manifests, SHA-256, small parsers,
the test watchdog's reading of the runner's output, the generated help, the screen lists) in `uni test`. `uni
selftest` (this repo) proves the bootstrap, `init`, the template and the watchdog end to end: a fresh clone of the
committed HEAD bootstrapped by its shim with an empty per-user cache, a game `init`ed outside it and inside it, their
builds, tests and `verify`, and a test that crashes holding a lock (`UNIFIED_TEST_CRASH=1`) failing its run within
seconds. It runs only when called (before tooling PRs, after a pin or toolchain change), never in `verify` or CI.
CI runs every command through the shims, as a developer does (`uni.cmd` on Windows).
