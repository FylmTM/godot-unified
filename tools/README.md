# tools

This repo's CLI, `uni` (`src/cli/SPEC.md`): `main.odin` runs unified:cli's public commands plus this repo's private
ones, which no game needs yet. The shims at the root (`./uni`, `uni.cmd`) run it and the binary rebuilds itself when
a source changes, so there is no build step. `./uni help` lists every command, `-h` on a command its options and
budget; every command rejects arguments it doesn't know and takes `--json`.

| File | What |
|---|---|
| `main.odin` | The entry point: the public commands, the private ones below, this repo's test suites. |
| `suites.odin` | The `net` suite (the toy's relay and 3 clients over real UDP), the `godot-bindings` suite (`tests/godot`, `tests/godot_views`), `godot-gen`. |
| `release.odin` | `release`: playable builds (the `release` skill), and `release notes`. |
| `eos.odin` | `eos upload`: packs the pruned EOS SDK, one reproducible zip per platform, onto the draft release (`docs/EOS.md`). |
| `board.odin` | `board list\|set`: the work board (GitHub Project 2) through `gh` (needs the `project` scope). |
| `ci.odin` | `ci summary` (the job summary from `.out/`) and `ci cache-key <dep>`. |
| `selftest.odin` | `selftest`: a fresh clone, bootstrapped with only Odin, `init` a game outside it, its build, tests and `verify`. |

A command is a `cli.Command` (name, usage, summary, budget, `run`), a suite a `cli.Suite`; `tools/` imports only
`core:` and `unified:cli`, so library edits never rebuild the CLI. A command moves into `src/cli/` when a game
needs it.

## Budgets

Every command has a time budget: seconds for a warm run, dependencies already built (`-h` shows it; `test`'s is its
suites' sum). CI allows 3x. A run over budget prints an `OVER BUDGET` line and is marked in `.out/timings.json` and
CI's job summary; it doesn't fail, since machines vary, but it is a bug to find (AGENTS.md). A cold run (it built
odinfmt, imported a Godot project, or downloaded Godot, unified-box3d or the EOS SDK first) isn't held
to the budget, and says so. Interactive, windowed and networked commands have none.

## A game in its own repository

`./uni init <dir>` makes one: the template game (a dot per player), the shims, `tools/main.odin` (the public
commands; the game adds its own there), `.gitignore`, and unified as a git submodule at `unified/` (its root
`.gdignore` keeps Godot from importing it). In the game repo, the same `./uni` builds, tests and runs that game;
`test`, `vet`, `fmt` and `verify` cover the game, not the submodule.
