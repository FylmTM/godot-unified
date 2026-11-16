# tools

This repo's CLI, `uni` (`src/cli/SPEC.md`): `main.odin` runs unified:cli's public commands plus this repo's private
ones, which no game needs yet. The shims at the root (`./uni`, `uni.cmd`) run it and the binary rebuilds itself when
a source changes, so there is no build step. `./uni help` lists every command, `-h` on a command its options and
budget; every command rejects arguments it doesn't know and takes `--json`.

| File | What |
|---|---|
| `main.odin` | The entry point: the public commands, the private ones below, this repo's test suites. |
| `suites.odin` | The `net` suite (the toy's relay and 3 clients over real UDP), the `godot-bindings` suite (`tests/godot`, `tests/godot_views`, a script error under the debugger), `godot-gen`. |
| `release.odin` | `release`: playable builds (the `release` skill), and `release notes`. |
| `board.odin` | `board list\|set`: the work board (GitHub Project 2) through `gh` (needs the `project` scope). |
| `ci.odin` | `ci summary` (the job summary from `.out/`) and `ci cache-key <dep>`. |
| `selftest.odin` | `selftest`: a fresh clone, bootstrapped by its shim downloading the pinned Odin into an empty cache, `init` a game outside it, its build, tests and `verify` (`--shims`: the bootstrap only). |

A command is a `cli.Command` (name, usage, summary, budget, its options structs in `options`, optional `details` for
`-h`, `run`); `uni vet` fails when its usage line and options disagree. A suite is a `cli.Suite`, run with the
`cli.Test_Options` of that `test`. `tools/` imports only
`core:` and `unified:cli`, so library edits never rebuild the CLI. A command moves into `src/cli/` when a game
needs it.

## Budgets

Every command has a time budget: seconds for a warm run, dependencies already built (`-h` shows it; `test`'s is its
suites' sum). CI allows 3x. A run over budget prints an `OVER BUDGET` line and is marked in `.out/timings.json` and
CI's job summary; it doesn't fail, since machines vary, but it is a bug to find (AGENTS.md). A cold run (it built
odinfmt, imported a Godot project, or downloaded Godot or unified-box3d first) isn't held
to the budget, and says so. Interactive, windowed and networked commands have none.

## A game in its own repository

`./uni init <dir>` makes one: the template game (a capsule per player), the shims, `tools/main.odin` (the public
commands; the game adds its own there), `.gitignore`, and unified as a git submodule at `unified/` (its root
`.gdignore` keeps Godot from importing it). In the game repo, the same `./uni` builds, tests and runs that game;
`test`, `vet`, `fmt` and `verify` cover the game, not the submodule.

A game inside this repo starts from the same template: `./uni init games/<name> --in-repo` writes the game's
files only and imports its tests in `tests/tests.odin`.
