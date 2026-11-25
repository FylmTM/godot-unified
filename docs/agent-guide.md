# Agents

The entrypoint for a coding agent working on a game built on unified, and how unified gets it there. Paths are as a
game repo sees them, with unified at `unified/`; inside unified's own checkout, drop the `unified/` prefix.

## Learning to write a game

Read in this order; each holds its facts once, so look there rather than for a summary:

1. `unified/README.md`: the programming model and the principles.
2. `unified/docs/gameplay.md`: the patterns that survive rollback, and the gotchas by symptom.
3. `unified/examples/minimal_3d/`: the reference game (a new game repo starts as a copy of it).
4. `./uni doc` lists the packages; `./uni doc <pkg>` prints one's API.
5. `unified/src/<pkg>/README.md`: how a package works and the decisions behind it.

The determinism lint (in `./uni test`) and `./uni vet` enforce the simulation's rules: fix what they name.

## The tools, by job

Everything runs through `./uni` (`uni.cmd` on Windows): `./uni help` lists the commands, `./uni <command> -h` has
one's options. A game repo holds one game, so no command needs its name.

- Test the sim (rules, lint, reference run, replay regressions): `./uni test`; bless a meant change: `--bless`;
  pin the reference run the first time, once the rules settle: `./uni test <game> --bless`
- Sync-test, offline runs, traces, replays: `./uni headless -- synctest | sim | replay` (`-- help`: every mode)
- A session with many clients on a virtual clock behind a network profile: `./uni headless -- session`
- The game under headless Godot: `./uni test --suite godot`
- Play it: `./uni run`; a host and a joiner: `./uni coop`
- Drive a running game (input, exact steps, state, screenshots, menus): `./uni drive`
- The developer's playtest notes (F3, freezes): `./uni feedback`
- Tool scripts (validate, the game's own): `./uni tool <script>`
- Levels: `./uni bake`
- Speed: `./uni bench`
- A playable build (a zip for testers): `./uni release`
- The API: `./uni doc`
- Before handing work back: `./uni verify`

The multi-step procedures are skills in `.claude/skills/unified-*/SKILL.md` (plain Markdown, for any agent):
`unified-godot` (checking and play-checking in Godot), `unified-godot-authoring` (scenes, levels, input maps and UI
without the editor), `unified-sim-change` (a change that moves the sim's results), `unified-desync` (finding a
determinism bug), `unified-feedback` (the developer's playtest notes) and `unified-release` (a playable build and the
rules of the game's export).

## Odin traps

What the compiler and `./uni vet` say about these is no help:

- A `_test.odin` file is compiled into normal builds (and pulls in `core:testing`): tests live in their own package
  (`simulation/tests/`), never beside the code.
- Package names must be unique across the program and unlike Odin's own (`net`, `log`, `bytes`, ...): `core:net` is
  package `net`, which is why unified's is `netcode`.
- A generic proc is type-checked only where it is instantiated, so `-vet` flags an import used only inside generic
  procs as unused in a package that never calls them. Keep such an import behind a small non-generic helper.
- A struct field named like an imported package shadows the package inside generic code: import it under another
  name (`import usim "unified:sim"`).
- A range's end is evaluated before every iteration: `for _ in 0 ..< read_count(&reader)` reads each time round.
  Read the count into a local first.
- Never edit `*.gen.odin`: `uni` generates them when stale. Every `.odin` file an agent edits is formatted by
  odinfmt (the hook in `.claude/settings.json`); `./uni fmt --check` in `verify` is the gate.

## How the integration works

`./uni init` writes the game (a copy of `unified/examples/minimal_3d`) and, from the submodule, so they match the
pinned unified:

- **A marked section of `AGENTS.md`**, a few lines pointing here, between `<!-- unified: begin ... -->` and
  `<!-- unified: end -->`. Its text is `unified/src/cli/template/agents-section.md`; the rest of the file is the
  game's.
- **unified's skills**: every `unified-*` directory of `unified/.claude/skills/`, copied into the repo's
  `.claude/skills/`. The prefix marks them as unified's; the game's own skills take other names.
- **The shims**, `uni` and `uni.cmd`: two lines each that run the submodule's own shim for this repo, `uni` tracked
  executable.
- **`odinfmt.json`**, unified's format, at the root where the editor looks for it.
- **The starters**, the game's once written: `.claude/settings.json` (an agent's every Odin edit formatted) and
  `ols.json` (the editor's language server); `uni doc cli STARTERS` says what each does.

Nothing else of unified's is in the repo: the docs stay in `unified/docs/`, and Godot reads unified's tool scripts in
place at `res://unified/tools_godot/` (every other directory of unified holds a `.gdignore`). After a submodule bump,
`./uni refresh` brings the repo in line: the marked section, the `unified-*` skills (added, rewritten, or removed when
unified no longer ships one), the shims (`uni` marked executable in the git index, which a Windows checkout drops),
`odinfmt.json`, a missing starter (never one the game has), and what an older unified copied in (`GUIDE.md`,
`unified_index.tres`, an `addons/unified/` mirror, its `.gitignore` line and export filter) retired. Nothing else is
touched, and nothing is staged but the shim's mode. Until then `./uni vet` fails, naming each difference. Inside
unified, the `unified-*` skills are the source and also its own; its other skills are for working on unified itself.

**Why copies, not a Claude Code plugin.** A plugin loaded from the submodule as a directory marketplace does load,
but Claude Code registers marketplaces per user, by name: every checkout of unified (each game repo, each worktree)
shares one registration, and a session starts with the skills of whichever checkout registered last, another version
or none once that checkout is deleted. Copied project skills load per repo.
