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
  for speed and efficiency. Main subsystems have benchmarks. A step that is slower than its budget (`dev.py -h`;
  an over-budget run says so) is a bug: find out why and fix it.
- **Correct, proven by tests at every layer.** Each module, including every third-party dependency we rely on (the
  Box3D fork and its bindings first), has independent tests covering everything we use: determinism, save/restore,
  rollback, replays. Upgrading a dependency must be safe because the tests say so.
- **Deterministic simulation.** f32 only. No FMA contraction. No transcendentals except our own deterministic ones
  (hardware `+ − × ÷ sqrt` only). No `matrix` types, no `core:math` transcendentals, no wall-clock time, no
  unordered iteration that affects state, no pointers or heap data in sim state. The state block is pointer-free and
  padding-free, so a snapshot is a memcpy and the bytes are the checksum. Physics state lives in Box3D and is
  snapshotted through our fork.
- **Minimal third-party code.** The ideal number of dependencies is zero. Every dependency needs a reason and tests.
- **Narrow, purpose-built tooling.** No random scripts in random languages. Tooling converges on one `unified` CLI
  (design pending sign-off). Agents must know exactly how to operate everything: keep `dev.py -h` current.
- **Don't name products we take ideas from, or the developer's other games, in repo files** (the one line above
  aside). Describe designs on their own terms. Dependencies we use (Godot, Box3D, EOS, ...) are named normally.
- **Design for the library, not the demo.** Every change considers how `unified` will be used as a library by
  several co-op games with Godot, now and later.

## Workflow

- Iterate locally first. CI is the final check, and the cross-check of every reference run:
  Linux x64 and arm64 on every PR, Windows x64 after each push to `main`, macOS ARM64 nightly when `main` moved
  (the top of `.github/workflows/ci.yml`). `gh workflow run ci.yml --ref <branch>` runs all four on a branch.
- CI must stay fast. A small set of key benchmarks runs on every platform in CI; the full set runs on demand.
- Commit messages end with the co-author line. Docs stay lean: fold what we learn into the right doc, delete what
  stops being true. History lives in git.

## The board

Planned work is tracked on the GitHub Project [unified](https://github.com/users/FylmTM/projects/2), one issue per
reviewable piece of work. The board tracks issues only; PRs link to them. Operate it with `python tools/dev.py board
list|set` (statuses and areas by name) and `gh issue` / `gh pr`; sessions need permission to run those. Cloud
sessions can't (no GraphQL): they open the PR with their own GitHub tools, comment on the issue with `gh api`, and
leave the card to the developer (`docs/CLOUD.md`). Its `Status` columns:

| Status | Meaning | Who moves it here |
|---|---|---|
| Backlog | Anything, unsorted | anyone |
| Design | Needs a decision or spec first: ends in a spec PR or a decision written in the issue | developer |
| Todo | Ready; the top of the column goes first | developer |
| In progress | A session owns it; the issue names the session and branch in a comment | the agent taking it |
| Review | A PR is open and waits for the developer | the agent |
| Merged, to review | An agent merged it (rules below); the developer reviews after the fact | the agent |
| Done | Merged and seen by the developer; the developer closes the issue | developer |

- **Agents take work only from Todo** (or what the developer hands them directly), and never start Backlog or
  Design items on their own. Another column's item may get a comment with questions or findings.
- **Work the developer asks for in chat is done in that session**, not filed first: issues are for work that isn't
  being done now.
- **Every change is a PR** from its own branch, linked with `Part of #N` (never `Closes`: the developer closes issues),
  or `Part of: no issue (requested in chat)` when a direct request has none.
  A PR may cover several issues (`Part of #a, #b, ...`, one commit per issue). Agents push their own branches and
  open PRs without asking; only merging into `main` is gated. Fill in the PR template; "Decisions made without
  sign-off" lists every choice the developer hasn't seen.
- **A review sitting's follow-ups ship as one PR per sitting** (or per large part of one): one side session on one
  branch does them all while the next sitting continues. Issues stay one per decision. This keeps CI runs down and
  parallel agents off each other's files.
- **Merging:** an agent may merge its own PR, after `python tools/dev.py all` passes and CI is green, only when
  the change is trivial (typo, formatting, test-only, a doc that only fixes facts) or the issue carries the
  `agent-may-merge` label. It then moves the issue to "Merged, to review". Everything else waits in Review.
- **New findings** (bugs, follow-ups, ideas) outside the current request become new Backlog issues, not notes in
  docs or reports. A finding that is part of the current request gets fixed, not filed.
- The `review` label marks a review sitting: the developer goes through one part of the project with an agent
  (explanation, a hands-on task, decisions); its decisions and follow-ups are written into the issue.

## Conventions

- `src/` is the `unified` collection, one package per directory. Imports point one way and always go through the
  collection (`unified:<pkg>`), the way games and tests import it. Deterministic packages never import real-time or
  host ones. The graph lives in `tests/lint/lint_test.odin` (an import allowlist per package): a new package in
  `src/` needs a rule there (the lint test fails otherwise). A game's `simulation/` is linted by its layout
  (`lint.check_game`: `headless/`, `extension/`, `tests/`, every other directory a sim package).
- A game is a Godot project in `games/<game>/`; its Odin code is in `simulation/`: the sim package (linted like the
  core), its headless binary, its GDExtension and its sim tests.
- Library tests are black-box packages in `tests/<module>/`, importing `unified:<pkg>` like a game does. A game's
  sim tests, end-to-end suite and reference run live with the game, in `simulation/tests/`. `dev.py test` runs them all in one compile.
- Specs live next to what they specify: `src/<pkg>/SPEC.md` per module, `games/<game>/SPEC.md` per game.
- Generated output goes to `out/` (root) and `games/<game>/.out/`, both git-ignored and safe to delete.
- Each fact has one home. README.md: what, why, requirements, setup. This file: roles, rules, workflow. Commands and
  options: `python tools/dev.py -h`. Packages: their `SPEC.md`. No layout trees, test counts or measured times in
  docs: the tools print them.

## Commands

Everything runs through `python tools/dev.py`, from the repo root, on any OS; `python tools/dev.py -h` lists every
command and `-h` on a command its options. Every command rejects unknown arguments. Before handing work back:

```
python tools/dev.py fmt          # odinfmt (pinned, see README.md); --check only reports
python tools/dev.py vet          # odin check, strict flags, every target
python tools/dev.py test         # every test package and end-to-end suite in one compile, the determinism lint included
python tools/dev.py check        # when netcode or the headless CLI changed (real UDP, separate processes)
python tools/dev.py bench        # when the sim, physics or rollback changed: step and re-sim times
python tools/dev.py godot-checks # when Godot-side code or GDScript changed (or the matching `dev.py game` commands)
python tools/dev.py all          # everything CI runs; before merging
```

## Where things are

- The board (above): current and upcoming work. `docs/WORK.md`: phases and decisions taken so far (they move into
  the specs during the foundations review, then the file goes).
- `README.md`: what `unified` is, why, the developer's requirements, the toolchain and first commands.
- `SPEC.md` next to each module and game; `src/README.md`: how the core works inside; `tools/README.md`: the tools.
- `docs/RELEASE.md` (game builds), `docs/EOS.md` (online setup), `docs/CLOUD.md` (Claude Code cloud sessions: setup,
  and what they can't do, the board among it), `docs/research/` (open research).
- `docs/archive/`: phase 2 results kept for reference; the research on the stacks we didn't choose is in git
  history (`docs/archive/README.md`).
