# unified

A purpose-built core for **cooperative games with deterministic rollback netcode**, written in **Odin**, with
**Godot** as the host for rendering, audio, UI and the editor. Inspired by Photon Quantum's model (deterministic
sim, input relay, prediction and rollback), built for speed, code-first workflows and AI-agent development. The first
game is `games/survivor/`, a co-op survivor prototype; larger 3D co-op games follow.

## Roles

- **The developer is the architect and stakeholder.** Every design decision goes through them. Never settle an open
  design question on your own: explain the options, recommend one, and ask.
- **Every module gets a concise spec**: its intended API and a short overview of how it works. The developer signs it
  off **before** the module is built or substantially changed. Keep specs short; don't bloat the repo with prose.
- How the developer likes to be engaged, in order of preference:
  1. Explain in chat, then ask questions interactively to reach a decision.
  2. A one-off, self-contained `.html` page that goes deep on a topic (e.g. a module's architecture). Make one when
     the explanation would be too large for chat, or when asked.
  3. A Markdown doc they read in VS Code.

## Non-negotiables

- **Fast.** Everything we build, run and ship must be fast: builds, tests, checks, tooling, runtime. We left Unity
  for speed and efficiency. Main subsystems have benchmarks. A step that is slower than its budget (`uni <command> -h`;
  an over-budget run says so) is a bug: find out why and fix it.
- **Correct, proven by tests at every layer.** Each module, including every third-party dependency we rely on (the
  Box3D library and its bindings first), has independent tests covering everything we use: determinism, save/restore,
  rollback, replays. Upgrading a dependency must be safe because the tests say so.
- **Deterministic simulation.** f32 only. No FMA contraction. No transcendentals except our own deterministic ones
  (hardware `+ − × ÷ sqrt` only). No `matrix` types, no `core:math` transcendentals, no wall-clock time, no
  unordered iteration that affects state, no pointers or heap data in sim state. The state block is pointer-free and
  padding-free, so a snapshot is a memcpy and the bytes are the checksum. Physics state lives in Box3D and is
  snapshotted through unified-box3d (our Odin port).
- **Minimal third-party code.** The ideal number of dependencies is zero. Every dependency needs a reason and tests.
- **Narrow, purpose-built tooling.** No random scripts in random languages: one CLI, `uni`, in Odin
  (`src/cli/SPEC.md`). Agents must know exactly how to operate everything: keep `uni help` and each command's `-h`
  current.
- **Don't name products we take ideas from, or the developer's other games, in repo files** (the one line above
  aside). Describe designs on their own terms. Dependencies we use (Godot, Box3D, EOS, ...) are named normally.
- **Design for the library, not the demo.** Every change considers how `unified` will be used as a library by
  several co-op games with Godot, now and later.

## Workflow

- Iterate locally first. CI is the final check, and the cross-check of every reference run:
  Linux x64 and arm64 on every PR, Windows x64 after each push to `main`, macOS ARM64 nightly when `main` moved
  (the top of `.github/workflows/ci.yml`). `gh workflow run ci.yml --ref <branch>` runs all four on a branch.
- **CI is in minimal mode for now** (Actions minutes): only pushes to `main` run, only format + vet and test on
  linux-arm64; the rest is commented out at the top of `ci.yml`, not removed. Run `./uni verify` locally.
- CI must stay fast. A small set of key benchmarks runs on every platform in CI; the full set runs on demand.
- Commit messages end with the co-author line. Docs stay lean: fold what we learn into the right doc, delete what
  stops being true. History lives in git.
- **Never disturb the developer's main screen.** Any game or editor window an agent opens (to look at it or as a
  check) starts muted on the leftmost screen: `--mute --screen left` (`run`, `editor`, `tool --window`,
  `coop --window`; the `godot-game` skill).

## The board

Planned work is on the GitHub Project [unified](https://github.com/users/FylmTM/projects/2), one issue per reviewable
piece of work. Issues are the developer's memory of what to do; how a piece of work is handled (merge it or not) is
said in chat, not with labels. The `board-work` skill has the statuses and the procedure. The rules:

- **Agents take work only from Todo** (or what the developer hands them directly), never Backlog or Design items.
- **Work the developer asks for in chat is done in that session**, not filed first.
- **Every change is a PR** from its own branch. It says `Closes #N` for each issue it finishes (merging closes them)
  and `Part of #N` for one it only advances. Agents push and open PRs without asking; only merging is gated.
- **Done means closed.** An issue moved to Done is closed too (`./uni board set N --status Done` does both).
- **New findings** outside the current request become Backlog issues, not notes in docs or reports.

## Current phase: the foundations review

- **No new features or big changes** until the review sittings are done (the `review` label, foundations up: #5
  tooling, #6 sim, #7 physics, #8 netcode, #9 Godot host, then the games). Bugs, review follow-ups and small fixes
  are fine; file ideas as Backlog issues.
- A review sitting: the developer goes through one part of the project with an agent (explanation, a hands-on task,
  decisions); its decisions and follow-ups are written into the issue. Check the issue's comments for notes added
  since it was filed.
- **A sitting's follow-ups ship as one PR per sitting** (or per large part of one): one side session on one branch
  does them all while the next sitting continues. Issues stay one per decision.

## Conventions

- `src/` is the `unified` collection, one package per directory. Imports point one way and always go through the
  collection (`unified:<pkg>`), the way games and tests import it. Deterministic packages never import real-time or
  host ones. The graph lives in `tests/lint/lint_test.odin` (an import allowlist per package): a new package in
  `src/` needs a rule there (the lint test fails otherwise). A game's `simulation/` is linted by its layout
  (`lint.check_game`: `headless/`, `extension/`, `tests/`, every other directory a sim package).
- A game is a Godot project in `games/<game>/`; its Odin code is in `simulation/`: the sim package (linted like the
  core), its headless binary, its GDExtension and its sim tests.
- Library tests are black-box packages in `tests/<module>/`, importing `unified:<pkg>` like a game does. A game's
  sim tests, end-to-end suite and reference run live with the game, in `simulation/tests/`. `uni test` runs them all in one compile.
- Specs live next to what they specify: `src/<pkg>/SPEC.md` per module, `games/<game>/SPEC.md` per game.
- Generated output goes to `.out/` (the root's and each game's), git-ignored and safe to delete.
- Each fact has one home. README.md: what, why, requirements, setup. This file: roles, rules, workflow. Commands and
  options: `./uni help`. Packages: their `SPEC.md`. Procedures (how to do a recurring task):
  `.claude/skills/<name>/SKILL.md`. Rules for one kind of file: `.claude/rules/` (they load when Claude touches a
  matching file). No layout trees, test counts or measured times in docs: the tools print them.

## Commands

Everything runs through `./uni` (`uni.cmd` on Windows), from the repo root, on any OS; `./uni help` lists every
command and `-h` on a command its options and budget. Every command rejects unknown arguments. Before handing work
back:

```
./uni fmt                      # odinfmt (pinned; a hook formats each .odin file Claude edits)
./uni vet                      # odin check, strict flags, every target
./uni test                     # the odin suite: every test package and end-to-end suite in one compile, the lint included
./uni test --suite net         # when netcode or the headless modes changed (real UDP, separate processes)
./uni bench                    # when the sim, physics or rollback changed: step and re-sim times
./uni test --suite godot       # when Godot-side code or GDScript changed (`--only <step>`, `uni tool` for one script)
./uni verify                   # everything CI runs; before merging
./uni test --long              # when a game's rules, physics, netcode or rollback changed: the full-length suites
```

## Where things are

- The board (above): current and upcoming work. `docs/WORK.md`: phases and decisions taken so far (they move into
  the specs during the foundations review, then the file goes).
- `README.md`: what `unified` is, why, the developer's requirements, the toolchain and first commands.
- `SPEC.md` next to each module and game; `src/README.md`: how the core works inside; `tools/README.md`: the tools.
- `docs/EOS.md` (online setup), `docs/research/` (open research).
- `docs/archive/`: phase 2 results kept for reference; the research on the stacks we didn't choose is in git
  history (`docs/archive/README.md`).
