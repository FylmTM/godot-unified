# cli

Signed off 2026-11-11 (#20, PR #98; the reasoning behind each decision is in #98's description). Built in #20.

`uni`, the unified CLI: one Odin binary per project that builds, tests and runs games, in this repo and in a game
repo that has `unified` as a git submodule. `unified:cli` is the public part, a library: each project compiles it
with its own commands into its CLI (`tools/`). The only requirements are Odin and what it needs anyway.

## Requirements

Installed by the developer, nothing else: what Odin needs (clang on macOS and Linux; Visual Studio Build Tools on
Windows: its linker and the Windows SDK), **git** and **curl** (shipped with macOS, Windows 10+ and Linux). **Odin**
is the exact pinned release (`pins.cfg`): the odin on PATH when it is that one, else the shims download it (below).
A CLI built with another Odin is refused with the pin. CI gets Odin the same way, through the shims (their
download cached). Everything else (Godot, export templates, odinfmt, Box3D) the CLI
fetches or builds, pinned and hash-checked. Nothing it builds is C or C++. The EOS SDK is the exception: Epic's
licence keeps it out of the repo and CI, so a machine that plays online downloads it from Epic and names it with
`UNIFIED_EOS_SDK` (`docs/EOS.md`).

## Layout

```
<project>/            this repo, or a game repo (a Godot project at its root)
  uni, uni.cmd        the shims (committed; `init` writes them in a game repo)
  tools/              the project's CLI: package main, imports unified:cli, adds the project's commands
                      (this repo: the private commands; a game repo: main.odin and a .gdignore from `init`)
  unified/            game repo only: the submodule, always at this path
  pins.cfg            this repo only: every pin (Odin, Godot, templates, OLS, unified-box3d, EOS SDK)
  .env                git-ignored: this checkout's UNIFIED_* settings (below)
  .out/               everything generated, git-ignored, safe to delete
    cli/              the CLI binaries (uni-<hash>-<odin commit>), `current`, their manifests (`<binary>.inputs`),
                      `odin-on-path` (the shims' stamp: the pinned commit and the odin on PATH that reported it)
    odinfmt/          odinfmt built from the pinned OLS commit
    <mode>/           the headless binaries (dev, release, debug), each with a build manifest
    unified-box3d/    Box3D: the pinned release's library, headers and Odin bindings (the `box3d` collection),
                      unpacked from the cached zip (each project has its own: ols.json names it)
    timings.json      each command line's last time against its budget

<per-user cache>/unified/   pinned downloads shared by every checkout, a directory or file per version and SHA-256
                      (%LOCALAPPDATA% on Windows, ${XDG_CACHE_HOME:-~/.cache} elsewhere; `uni help` and `setup` say
                      where; `clean` leaves it, `clean --cache` removes godot/ and downloads/)
  odin/<tag>/         the pinned Odin release the shims downloaded
  godot/<version>-<sha256>/   the pinned Godot editor: one download per machine, one path for the OS to remember
                      (Windows Firewall); export templates stay in Godot's user directory
  downloads/          unified-box3d-<tag>-<platform>-<sha256>.zip, the pinned release each project unpacks
```

A download into the cache goes to a part file of the process's own, then is renamed into place: checkouts fetching
the same pin at once each finish, and the first rename wins.

Box3D lives in the project's `.out/unified-box3d/` (each project unpacks its own from the cached zip); the EOS SDK stays where
`UNIFIED_EOS_SDK` points (its library is loaded at run time, never linked). Every Odin build gets two collections:
`unified` (`src/`) and `box3d` (unified-box3d, imported as `box3d:bindings`). A game is a directory with
`project.godot` and `simulation/`: the project root, else every `games/*/`. Commands take `[game]`, optional
when there is one. In a game repo, `test`, `vet`, `fmt` and `verify` cover the game only: never the submodule, which
`unified`'s own CI proves.

## Bootstrap and self-rebuild

- **Shims** (POSIX sh and cmd, nothing else): first the pinned Odin, then the binary. They read `pins.cfg`'s
  `[odin]` with shell builtins. The pinned release downloaded into the per-user cache (`<cache>/unified/odin/<tag>`)
  goes first on PATH. Else the stamp `.out/cli/odin-on-path` (`<commit> <path>`) naming the pinned commit and the
  odin on PATH (found by a builtin PATH search): use it. Both checks start no process. Else the odin on PATH, when
  `odin version` reports the pinned commit, gets the
  stamp; else the shim downloads this platform's release asset (curl), checks its SHA-256 against `pins.cfg`
  (`sha256sum`/`shasum`; `certutil`), unpacks it next to its final directory (`tar`; the system `tar.exe` reads the
  Windows zip; Git Bash: `unzip`), renames its top folder into place and puts it first on PATH. That first run
  costs the download (60-160 MB, Windows the largest). Then: if `.out/cli/current` names an
  existing binary, run it with the arguments; else `odin build tools -collection:unified=<unified>/src
  -o:minimal` into `.out/cli/uni-bootstrap`, with its dependency list, then run it. The bootstrap binary installs
  itself as `uni-<hash>-<odin commit>`.
- **The binary checks itself** before every command: its manifest (from `-export-dependencies:json`: every source
  file outside the Odin install, their directories and the `odin` executable) holds sizes, times and a content hash.
  Sizes and times match: run (~1 ms). Else hash; same hash and no new file: refresh the times, run. Else rebuild to a
  temp file, rename it to `uni-<hash>-<odin commit>` (the hash leaves the Odin install out: the building odin's,
  from `odin root`; the commit keeps another Odin's build of the same sources apart), write `current`, and run it
  with the same arguments. A rebuild keeps the
  newest four binaries (switching branches back and forth needs none); a binary still running on Windows stays until
  a later rebuild. No lock: concurrent rebuilds write the same file. A CLI source that doesn't compile stops with the
  compiler's error.
- **Odin version:** the binary compares the tag and commit it was built with (`ODIN_VERSION`, `ODIN_VERSION_HASH`)
  against the pin, at no cost, and refuses a mismatch (a build without a commit hash: a warning). The tag alone isn't
  enough: a build from Odin's master reports the month's tag. A changed `odin` executable shows in the manifest and
  leads to a rebuild, so the check follows the installed Odin; so does a binary built with another Odin while PATH
  names a different odin (the shim put the pinned one first). A refusal deletes the shims' stamp, so the next run
  checks the odin on PATH again and downloads the pinned release.
- **Imports:** `unified:cli` and the project's `tools/` import only `core:` (and each other; the lint holds it):
  library edits never rebuild the CLI. The one planned exception: the control socket's message types.
- **Build mode `-o:minimal`**: ~0.3 s builds, SHA-256 at 186 ms/100 MB; measure again when the CLI does real CPU
  work.

## Pins

`pins.cfg`, Godot's ConfigFile syntax: `[section]` and `key = "value"` lines, one value per line, so the shims read it
with shell builtins before any Odin exists. Odin is pinned by tag (the release) and commit (what `odin version`
reports). CI cache keys come from `uni ci cache-key <dep>` (the dependency's pins, the recipe version and, for what we
compile, the compiler's version), never from tool sources; Odin's own cache is keyed by `pins.cfg` in the workflow.

## Commands

Every command rejects unknown arguments; `-h` on any command prints its options and budget; `uni help` lists them
all. Progress goes to stderr, the result to stdout: one line, or with `--json` (any command) one object
`{command, ok, summary, seconds, cold, data}`. The command lines it runs are echoed only with `--verbose` (any
command; a `uni` it starts inherits it), and when one fails. Exit 0 ok, 1 failed, 2 usage. A warm run over its budget prints
`OVER BUDGET` (not a failure; CI allows 3x); a cold run (it fetched or built a dependency, generated the Godot bindings, or imported a project) is
exempt and says so. Commands that need a game library or headless binary rebuild it when its build manifest is
stale; `build` always builds.

Public (`unified:cli`, every project):

| Command | What |
|---|---|
| `setup [--check]` | fetch and build everything this project needs; print each dependency's version and source (pinned download, `.env`, environment; with `UNIFIED_BOX3D`, builds that unified-box3d checkout) (`--check`: report only) |
| `clean [--check] [--cache]` | remove what the CLI built or fetched: every `.out/` and `.godot/` outside hidden directories, the generated bindings; not the running CLI, `.env`, the per-user cache (`--cache`: its Godot and unified-box3d downloads too, never the shims' Odin) or Godot's export templates (`--check`: list only). Fails on what a running process holds (Windows) |
| `build [game] [--mode dev\|release\|debug]` | the game's (or every game's) headless binary and extension, in parallel (this repo: `toy` builds no extension) |
| `headless [game] [--mode m] -- <mode> [options]` | the game's headless binary (`src/headless/SPEC.md`; this repo: also `toy`), built when stale, run with the terminal's stdin, stdout and stderr: its JSON is the command's stdout |
| `run [game] [--background] [-- args]`, `editor [game]` | the game in a window, the Godot editor on it; both take `--mute` (Godot's dummy audio driver) and `--screen <n\|left\|right\|primary>` (Godot's screen index, or one the CLI finds from the OS: Windows only for now), as do `tool --window` and `coop --window`. `--background`: the window never takes focus, as `tool` and `coop` windows never do (Godot's `display/window/size/no_focus`, set through an `override.cfg` the CLI writes into the project for the run and removes after; it opens without activation and clicks don't activate it). The editor ignores the override and takes focus |
| `test [game] [--suite s,...] [--only name,...] [--long] [--crash] [--box3d-debug]` | the test suites (below); plain `test` runs the `odin` suite, `--suite all` every one; `--only` picks tests (`odin`) or steps (`godot`); `--long` runs each suite's long variant; `--crash` proves a crashing test fails the run fast; `--box3d-debug` runs the `odin` suite against Box3D's debug library |
| `vet` | `odin check`, strict flags, every target and define variant, the CLI included; in this repo also the template game's Odin (below) |
| `fmt [--check] [path...]`, `fmt --hook` | odinfmt (pinned), and every text file's line endings (below); `--hook`: the one file a Claude Code edit names (the hook's JSON on stdin) |
| `tool [game] <script> [--window [--mute] [--screen s]] [--shots] [--cold] [-- args]` | run a tool script (below), headless unless `--window`; `--cold` clears the shader caches first |
| `coop [game] [--window [--mute] [--screen s]] [--rejoin \| --crash] [--lan]` | host and joiner processes, a real lobby; `--rejoin`: the joiner leaves and joins again; `--crash`: it kills itself mid-match and the same player rejoins (timed; with `--lan` in a new seat, as direct UDP has no player identity). `--lan` uses a free port (parallel runs never meet). A game without a coop tool script gets unified's default (`--lan` only): a headless host (`--host-port`) and joiner (`--join`) with scripted input for 600 ticks, their checksums compared |
| `bake [game] [--check]` | write the view index (`unified_index.tres`: every scene with a UnifiedView marker, by kind; src/godot/SPEC.md) and bake `.level` files from their scenes (`--check`: fail if one is stale); builds the game library first. Every build of a game's library (so every command that runs the game) refreshes its view index too, except in CI |
| `bench [game...]` | each game's standard benchmark, alone, on a release build, and the sim's sparse-table walk (`.out/bench.json`) |
| `record-reference <game>` | record a game's reference run anew (the committed log, trace and snapshot `test` replays); "nothing changed" when it reproduces byte for byte |
| `init <dir> [--unified <url>] [--ref <ref>]` | a new game repo from the template game (below), the shims, `tools/`, `.gitignore`, `.gitattributes`, the submodule (below) |
| `init games/<name> --in-repo` | in this repo: the template game at `games/<name>` (its files only), its tests imported in `tests/tests.odin` |
| `verify [--long]` | the gate before handing work back or merging: `fmt --check`, `vet`, `test --suite all`, `test --box3d-debug`, `bench` (this repo: everything CI runs; never `selftest`); `--long` passes `--long` to `test` |
| `version` | the CLI's source hash, Odin, and the pins |

Private (this repo's `tools/`; promoted to public only when a game needs one):

| Command | What |
|---|---|
| `godot-gen [--force]` | the Godot bindings, `src/gdext/*.gen.odin` (every command that needs them generates them when stale) |
| `release [game] [--tag <game>-v<version> \| --version V] [--no-smoke]`, `release notes [game] --tag T` | a playable build (the `release` skill): export, version stamp (into `project.godot` and `export_presets.cfg` in place, restored byte for byte), sign, zip, smoke test; requires the EOS IDs when the extension imports `unified:eos` |
| `board list\|set` | the work board through `gh` |
| `ci summary`, `ci cache-key <dep>` | the job summary (markdown); a dependency's cache key |
| `selftest [--shims]` | run only when asked for, never by `verify`: a fresh clone of HEAD in `.out/selftest/`, bootstrapped by its shim with no pinned Odin to find and an empty per-user cache (the shim downloads, checks and unpacks Odin, then builds the CLI; `--shims` stops there; CI doesn't run it, its own download runs whenever its Odin cache misses), `init` a game outside it with the clone as its submodule pinned to HEAD (checked, and the commands and links its files name), then that game's `bake --check`, `build` (it must report a cold run: the bindings), a sync-test through `headless`, `test --suite all` and `verify`; then `init --in-repo` the same game inside the clone (checked: only the game and the `tests/tests.odin` import), its `bake --check`, `build`, a sync-test, the clone's `test` and the game's `test --suite godot` |

## Line endings

LF in every text file, in the index and the working tree; CRLF only for batch files (`.cmd`, `.bat`: cmd.exe
misreads labels and `goto` in an LF one). `.gitattributes` says so (`* text=auto eol=lf`, `*.cmd text eol=crlf`),
so a checkout is LF whatever `core.autocrlf` says, and everything the CLI writes is LF. `fmt --check` fails on a text
file (git's attributes and detection decide what is text: one `git ls-files --eol` over the tracked and untracked
files, run alongside odinfmt) with CRLF or mixed endings, an LF batch file, or CRLF committed to the index; `fmt`
rewrites the working-tree file. The CLI's config readers (`pins.cfg`, `.env`) accept either.

## Local settings

A git-ignored `.env` at the project root holds this checkout's `UNIFIED_*` variables: local paths (`UNIFIED_GODOT`,
`UNIFIED_EOS_SDK`, `UNIFIED_BOX3D`) and the runtime's own knobs (`UNIFIED_EOS_LOG`, ...). One `KEY=value` per line, `#` comments and
blank lines; no quotes, `export` or expansion. Any key not starting with `UNIFIED_` is an error. The file wins over
the shell's environment, and the CLI passes the merged environment to every process it starts (Godot, headless
binaries, `coop`). A game opened in Godot directly, not through `uni editor`, doesn't see it. `init` git-ignores it.

## Test suites and tool scripts

- **Shared Godot code**: a project's `games/shared` (this repo: the demo games' code, its SPEC.md; not the library)
  is mirrored into a game that uses it (its `project.godot` names `res://addons/shared/`) as `addons/shared/` before
  every Godot run (git-ignored there; a copy edited in place stops the run; a `.uid` Godot writes for a new shared
  script is copied back). `games/shared` is no game: a game has `project.godot` and `simulation/`.
- **Library tool scripts**: unified's `src/godot/tools` (`UnifiedTool`, `UnifiedValidate`) is mirrored the same way
  into every game (a project with `game/`) as `addons/unified/`.
- **Tool scripts** are a game's `game/tools/<name>.gd`, else `games/shared/tools/<name>.gd` (ui_walk, coop), else
  unified's `src/godot/tools/<name>.gd` (validate); a game's own script extends them. Run with Godot's `-s`. Each prints one
  `UNIFIED_RESULT {json}` line (`ok`, `errors`, its own data); the CLI passes `--no-settings`,
  `--shots=res://.out/shots/<name>` with `--shots`, and the arguments after `--`. Headless runs have the debugger on
  (`-d`), which prints GDScript warnings; a child's stdin holds one line, `quit`, so a run stopped at the debugger
  prompt (a script or parse error) quits at once. A script quits through the game's own quit (audio stopped first):
  a live playback at exit is a leak.
- **Strict:** in `godot` suite steps, `tool`, `coop` and `bake`, a failing exit, a missing or `ok: false` result, an
  `ERROR` line, a leak at exit or a GDScript warning fails. `run` and `editor` only report. Windowed runs give focus
  back to the frontmost app on macOS.
- **Test suites**, each with its own budget (`test`'s budget is the sum of its suites'; in a run of several, one over
  its own is reported); a project's `tools/` adds its own with `cli.add_suites` (this repo: `net`, `godot-bindings`).
  A suite that mostly waits (`Suite.beside`: `net`, `godot-bindings`), run with others, runs beside them in a child
  `uni test --suite <name>`, once its `prepare` has made current what it shares. By default a suite runs the least that shows
  the library correct and each game working; `test --long` (`Suite.long_budget`, `cli.state.long`) runs the longer
  variant, by hand, never in CI:
  - `odin`: the test packages in one compile (this repo: every package under `tests/`, the games' suites included;
    a game repo: its `simulation/tests`): unit tests, the library's black-box tests, end-to-end suites, the
    reference-run replays, the Box3D golden trace, the determinism and import lint. The inner loop. `--long`
    builds with `-define:UNIFIED_LONG_TESTS=true` (`scenarios.LONG`): every standard scenario of each game at full
    length, and the tests a game keeps for it (`src/headless/SPEC.md`, Running). The binary runs under a watchdog
    (`testrun.odin`), as does `record-reference`'s: Odin's runner freezes a crashed test's thread, so a lock it held
    stays held and a test waiting for it would hang the run. The watchdog kills the binary 3s after a crash, or at
    the suite's CI allowance (budget × 3), and names the crashed and still-running tests (the runner logs state
    changes for it; they stay out of the terminal). The whole output is kept in `.out/test/unified_tests.exe.log`.
    `--crash` (this repo) adds `tests/cli`'s test that crashes while holding a lock another test waits for: the
    run must fail within seconds and name both.
    `--box3d-debug` builds into `.out/test-box3d-debug/` against Box3D's debug library (`-define:BOX3D_LIB_DEBUG=true`),
    whose asserts trap what the release library lets through (a stale id destroying another body); `verify` runs it
    (about twice the release run's time: its physics is unoptimised).
  - `godot`: each game under headless Godot, each step run when the game has what it needs: `import` (stale imports
    only; every step, `--only` too, first re-imports a missing or stale class cache, as `tool`, `run`, `coop` and
    `bake` do), `editor` (the extension loads, no errors), `session` (a 64-tick headless session, `--long` 256; its
    checksums equal the offline headless binary's), `bake` (`--check`), then each tool script the game has of
    `validate`, `walk` (`ui_walk.gd`), `tour` (quick). `bake` checks the view index too. A step the game can't run prints `skipped: <why>`. Several
    games run in parallel, each in a child `uni test <game> --suite godot` (its log printed when it ends); the
    parent first makes current what they share (Godot, the bindings, Box3D, the `session` step's headless binaries
    in `.out/release/`). The tool scripts run without the EOS SDK, as on CI: they never wait on the lobby service.
  - `net` (this repo): the toy's relay and 3 clients (one on a bad-network profile) over real UDP on the real clock,
    320 ticks at 64 Hz (5 s; `--long` 960, 15 s; never in the inner loop); checksums agree every 16th tick, 0
    desyncs (`.out/net.json`, `.out/net/`).
  - `godot-bindings` (this repo): `tests/godot` and `tests/godot_views` under headless Godot; `tests/godot_views`
    also runs `session_check.gd`, unified:godot's session lifecycle. The extensions build at once, then the three
    Godot runs go at once: the session check (its waits for goodbyes and timers) is the suite's time.
- **Benchmarks:** a game's headless descriptor names its standard benchmark (`Headless.bench`: entities held,
  rollback window (default: the netcode's prediction cap, 14 ticks at 64 Hz), ticks), which its `bench` mode runs
  with no arguments; the target, a forward step plus a re-sim at the prediction cap within 6 ms, is unified's (the
  same re-sim of final ticks, saving only the last, is reported beside it). `bench` also runs each game's
  `net-bench` (a session of 4 clients under `bad` on the virtual clock: time, rollbacks, stalls, replaced inputs,
  bytes per second; `net` in `.out/bench.json`, no target) and the headless `table-bench` mode once (any game's
  binary): a walk of a sparse 65,536-slot table against a dense one (`table`), without a target.

## The template game

`init` adds unified as a git submodule at `unified/`, from `--unified` or this checkout's `origin`, a GitHub SSH
URL rewritten to HTTPS (unified is public: anyone and any CI clones it without keys). It pins the source's default
branch at its current commit (`main`, which CI proves), or `--ref` (a commit, tag or branch, fetched by name); a
pushed commit, never a local one, so the game repo clones anywhere. Then it writes the template and the shims from
that submodule, never from this checkout, so they always match the library they build against.

`init` writes `template/`: every file a `.tmpl` with `__GAME__` for the game's name (the directory's: lowercase
letters, digits and `_`), LF whatever the checkout has. It is the most basic 3D game, each player a capsule moved
by the arrow keys, with the core wiring only: its sim package (`game.odin`: the Game and its tick; `state.odin`;
`players.odin`; `scripted_input.odin`), headless binary (with a standard benchmark), extension (`input.odin`,
`frame.odin`: one scene view, its colour as view data), main scene with a `UnifiedSession`, and tests (sync-test
under rollback, a repeatable run, the determinism lint), so the new game passes its own `verify` at once. It
doesn't use the demo games' shared code. `template/repo/` is a game repo's own (a README, `.gitattributes`, the
repo's `.gitignore`, `tools/main.odin`); `--in-repo` leaves it out, and its wording fits both layouts ("unified's
`src/...`"). The Odin files are formatted after the name is put in (it changes line lengths), and the view index is
written by the build's own code, so the first build rewrites nothing. In this repo `vet` writes the template's Odin files
for a game named `template_game` into `.out/template/` and type-checks its packages (one target), so a library API
change that breaks a new game fails `verify`.

## Dependencies

- **Downloads:** `curl` (HTTPS, retries, byte ranges: only the needed members of the 1.3 GB templates archive),
  SHA-256 in Odin, our own zip reader and writer (`core:compress`: stored and deflated members, Zip64 sizes, Unix
  modes and symlinks), written to a temp path and renamed into place.
- **Godot:** the pinned editor in the per-user cache (`godot/<version>-<sha256>/`), shared by every checkout; `UNIFIED_GODOT` may name a local install that reports the
  exact pinned version (anything else is refused; the check is remembered per file). Export templates (`release`
  only) go where Godot looks for them, its user directory (`export_templates/<version>.stable`), checked against
  their pinned hashes.
- **Box3D:** unified-box3d, Box3D ported to Odin, as a shared library (static Odin-in-Odin linking clashes) with
  upstream's C API, headers and Odin bindings. By default this platform's zip of the pinned release (`[box3d]`: repo,
  tag, a SHA-256 per platform), checked, kept in the per-user cache and unpacked with its top folder flattened into `.out/unified-box3d/`
  (a stamp of the pin makes the warm check free). `UNIFIED_BOX3D` may name a local unified-box3d checkout instead:
  the `box3d` collection points there, and `setup` runs its `b3 build` and `b3 build --debug` (other commands only
  build a missing library). Programs link `lib/<platform>/` (`--mode debug`: `-define:BOX3D_LIB_DEBUG=true` and
  `lib/<platform>-debug/`) and load the library from their own directory: the CLI copies it next to each output that
  links it (`.out/test/`, `.out/<mode>/`, `.out/record-reference/`, a game's `.out/bin/`), where Odin's default rpath
  (`$ORIGIN`, `@loader_path`; the library's install name is `@rpath/libbox3d.dylib`, its soname `libbox3d.so`) and
  the Windows DLL search find it. A game's `.gdextension` lists it under `[dependencies]`: Godot loads it from the
  extension's folder and an export ships it.
- **EOS SDK:** never fetched: the SDK `UNIFIED_EOS_SDK` names (downloaded from Epic's portal), its
  `SDK/Include/eos_version.h` checked against `[eos_sdk] version`; a game's build copies this host's library next
  to the game library. Missing: online play is off (a note for `build`; `setup` lists it as optional); `release`
  fails unless `--no-eos` (CI's LAN-only packages).
- **odinfmt:** built from the pinned OLS commit into `.out/odinfmt/`; no other odinfmt is used.

## Testing

`tests/cli/` tests the library parts (the config and `.env` parsers, zip, build manifests, SHA-256, small parsers,
the test watchdog's reading of the runner's output) in `uni test`; `uni test --crash` runs its crash test. `uni selftest` proves the bootstrap, `init` and the template end to end; it runs only when called
(before tooling PRs, after a pin or toolchain change), locally. It tests the committed HEAD, so it refuses a working
tree with uncommitted changes. CI runs every command through the shims, as a developer does (`uni.cmd` on Windows).
