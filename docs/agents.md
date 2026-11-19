# Agents

The entrypoint for a coding agent working on a game built on unified, and how unified gets it there. Paths are as a
game repo sees them, with unified at `unified/`; inside unified's own checkout, drop the `unified/` prefix.

## Learning to write a game

Read in this order; each holds its facts once, so look there rather than for a summary:

1. `unified/README.md`: the programming model and the principles.
2. `unified/examples/minimal_3d/`: the reference game (a new game repo starts as a copy of it), and its `GUIDE.md`:
   the patterns that survive rollback, and the gotchas by symptom.
3. `./uni doc` lists the packages; `./uni doc <pkg>` prints one's API.
4. `unified/src/<pkg>/README.md`: how a package works and the decisions behind it.

The determinism lint (in `./uni test`) and `./uni vet` enforce the simulation's rules: fix what they name.

## The tools, by job

Everything runs through `./uni` (`uni.cmd` on Windows): `./uni help` lists the commands, `./uni <command> -h` has
one's options. A game repo holds one game, so no command needs its name.

- Test the sim (rules, lint, reference run, replay regressions): `./uni test`; bless a meant change: `--bless`
- Sync-test, offline runs, traces, replays: `./uni headless -- synctest | sim | replay` (`-- help`: every mode)
- A session with many clients on a virtual clock behind a network profile: `./uni headless -- session`
- The game under headless Godot: `./uni test --suite godot`
- Play it: `./uni run`; a host and a joiner: `./uni coop`
- Drive a running game (input, exact steps, state, screenshots, menus): `./uni drive`
- Tool scripts (validate, the game's own): `./uni tool <script>`
- Levels and the view index: `./uni bake`
- Speed: `./uni bench`
- The API: `./uni doc`
- Before handing work back: `./uni verify`

The multi-step procedures are skills in `.claude/skills/unified-*/SKILL.md` (plain Markdown, for any agent):
`unified-godot` (checking and play-checking in Godot), `unified-sim-change` (a change that moves the sim's results)
and `unified-desync` (finding a determinism bug).

## How the integration works

`./uni init` writes two things into a new game repo, both from the submodule, so they match the pinned unified:

- **A marked section of `AGENTS.md`**, a few lines pointing here, between `<!-- unified: begin ... -->` and
  `<!-- unified: end -->`. Its text is `unified/src/cli/template/agents.md`; the rest of the file is the game's.
- **unified's skills**: every `unified-*` directory of `unified/.claude/skills/`, copied into the repo's
  `.claude/skills/`. The prefix marks them as unified's; the game's own skills take other names.

After a submodule bump, `./uni agents` rewrites both: the marked section, and the `unified-*` skills (added,
rewritten, or removed when unified no longer ships one). Nothing else is touched. Until then `./uni vet` fails,
naming each difference. Inside unified, the `unified-*` skills are the source and also its own; its other skills are
for working on unified itself.

**Why copies, not a Claude Code plugin.** A plugin loaded from the submodule as a directory marketplace does load,
but Claude Code registers marketplaces per user, by name: every checkout of unified (each game repo, each worktree)
shares one registration, and a session starts with the skills of whichever checkout registered last, another version
or none once that checkout is deleted. Copied project skills load per repo.
