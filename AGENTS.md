# unified

A purpose-built core for **cooperative games with deterministic rollback netcode**, written in **Odin**, with
**Godot** as the host for rendering, audio, UI and the editor. Inspired by Photon Quantum's model (deterministic
sim, input relay, prediction and rollback), built for speed, code-first workflows and AI-agent development. The
example games in `examples/` prove it.

## Roles

- **The developer is the architect and stakeholder.** Every design decision goes through them. Never settle an open
  design question on your own: explain the options, recommend one, and ask.
- **Design is decided in the issue first.** A new module or a substantial change starts with its design (the API it
  offers, how it works, the decisions in it) agreed with the developer and written in its issue, **before** it is
  built. After that the code is the spec: the package's README says how it works, its doc comments what each public
  declaration does, its tests prove it.
- How the developer likes to be engaged, in order of preference:
  1. Explain in chat, then ask questions interactively to reach a decision.
  2. A one-off, self-contained `.html` page that goes deep on a topic (e.g. a module's architecture). Make one when
     the explanation would be too large for chat, or when asked.
  3. A Markdown doc they read in VS Code.

## Non-negotiables

- **Fast.** Everything we build, run and ship must be fast: builds, tests, checks, tooling, runtime. We left Unity
  for speed and efficiency. Main subsystems have benchmarks. Every `uni` command prints how long it took, and
  `uni bench` the sim's step and re-sim times; a slowdown in either is a bug: find out why and fix it.
- **Correct, proven by tests at every layer.** Each module, including every third-party dependency we rely on (the
  Box3D library and its bindings first), has independent tests covering everything we use: determinism, save/restore,
  rollback, replays. Upgrading a dependency must be safe because the tests say so.
- **Deterministic simulation.** f32 only. No FMA contraction. No transcendentals except our own deterministic ones
  (hardware `+ − × ÷ sqrt` only). No `matrix` types, no `core:math` transcendentals, no builtin `min`/`max`/`clamp`
  (`dmath`'s), no NaN in the state block, no wall-clock time, no unordered iteration that affects state, no pointers
  or heap data in sim state. The state block is pointer-free and
  padding-free, so a snapshot is a memcpy and the bytes are the checksum. Physics state lives in Box3D and is
  snapshotted through unified-box3d (our Odin port).
- **Minimal third-party code.** The ideal number of dependencies is zero. Every dependency needs a reason and tests.
- **Narrow, purpose-built tooling.** No random scripts in random languages: one CLI, `uni`, in Odin
  (`src/cli/README.md`). Agents must know exactly how to operate everything: keep `uni help` and each command's `-h`
  current.
- **Don't name products we take ideas from, or the developer's other games, in repo files** (the one line above
  aside). Describe designs on their own terms. Dependencies we use (Godot, Box3D, EOS, ...) are named normally.
- **Design for the library, not the demo.** Every change considers how `unified` will be used as a library by
  several co-op games with Godot, now and later.

## Workflow

- Iterate locally first. CI is the final check, and the cross-check of every reference run (the top of
  `.github/workflows/ci.yml`): a PR's own run (Linux x64, Linux arm64, Windows x64, godot) is the check before
  merging, and every push to `main` runs all four platforms, macOS ARM64 included (again nightly when `main` moved).
  Don't dispatch extra runs as routine: `gh workflow run ci.yml --ref <branch>` is only for re-checking something on
  demand. macOS never blocks a merge (its runners are often out of capacity): the run on `main` after the merge is
  the macOS check, and a red macOS on `main` is fixed before anything else merges.
- CI must stay fast. Every platform runs `uni bench` (each game's standard benchmark; reported, not gated).
- Commit messages end with the co-author line. Docs stay lean: fold what we learn into the right doc, delete what
  stops being true. History lives in git.
- **Never disturb the developer's main screen or keyboard.** Any game window an agent opens (to look at it or as a
  check) starts muted on the leftmost screen and never takes focus: `tool --window`, `coop --window` and `drive start`
  always do; `run` takes `--mute --screen left --background`; the `unified-godot` skill. The editor always takes focus:
  open it only when the developer asks.

## The board

Planned work is on the GitHub Project [unified](https://github.com/users/FylmTM/projects/2), one issue per reviewable
piece of work. The `board-work` skill has the statuses, the procedure and when a finding is filed.

- **Agents take work only from Todo**, or what the developer asks for in chat (done in that session, not filed first).
- **Every change is a PR** from its own branch. Agents push and open PRs without asking; only merging is gated.
- **Findings: do the work in the same PR; file only what can't be done here.** Never notes in docs or reports.

## Conventions

- `src/` is the `unified` collection, one package per directory. Imports point one way and always go through the
  collection (`unified:<pkg>`), the way games and tests import it. Deterministic packages never import real-time or
  host ones. The graph lives in `tests/lint/lint_test.odin` (an import allowlist per package): a new package in
  `src/` needs a rule there (the lint test fails otherwise). A game's `simulation/` is linted by its layout
  (`lint.check_game`: `headless/`, `extension/`, `tests/`, every other directory a sim package).
- This repo's games are examples of building on `unified`, in `examples/<game>/` (a real game lives in its own repo,
  made with `uni init <dir>`). A game is a Godot project; its Odin code is in `simulation/`: the sim package (linted
  like the core), its headless binary, its GDExtension and its sim tests.
- Library tests are black-box packages in `tests/<module>/`, importing `unified:<pkg>` like a game does. A game's
  sim tests, end-to-end suite and reference run live with the game, in `simulation/tests/`. `uni test` runs them all, from two compiles at once (`tests/tooling` unoptimised).
- The code is the spec. Each package (`src/<pkg>/`) and game (`examples/<game>/`) has a `README.md`: what it is, why,
  where it fits, how it works, and the decisions a reader could get wrong that no single declaration shows. The API
  is the code: each file's header comment and a doc comment on every public proc and type (the lint fails on one
  without), printed by `uni doc <pkg>`. A fact about one declaration lives on it. No API listings, history,
  measurements, test lists, options or anything unbuilt in a README (`.claude/rules/readme.md`).
- Generated output goes to `.out/` (the root's and each game's), git-ignored and safe to delete.
- Each fact has one home. README.md: what, why, the design and its reasons. `docs/getting-started.md`: setup. This
  file: roles, rules, workflow. Commands and options: `./uni help`. Packages and games: their `README.md` and doc
  comments (`./uni doc`). Procedures (how to do a recurring task): `.claude/skills/<name>/SKILL.md`. Agents in a game
  repo: `docs/agent-guide.md`; the `unified-*` skills ship to game repos, so they are written for one: here, drop
  `unified/` from their paths and name the example game. Rules for one kind of file: `.claude/rules/` (they load when Claude touches a matching file). No layout trees, test counts or measured times in docs: the tools print them.

## Commands

Everything runs through `./uni` (`uni.cmd` on Windows), from the repo root, on any OS; `./uni help` lists every
command and `-h` on a command its options. Every command rejects unknown arguments. Before handing work back:

```
./uni fmt                      # odinfmt (pinned; a hook formats each .odin file Claude edits)
./uni vet                      # odin check, strict flags, every target
./uni test                     # the odin suite: every test package and end-to-end suite, the lint included
./uni test <game>              # the inner loop of game work: that game's tests only
./uni test --suite net         # when netcode or the headless modes changed (real UDP, separate processes)
./uni bench                    # when the sim, physics or rollback changed: step and re-sim times
./uni test --suite godot       # when Godot-side code or GDScript changed (`--only <step>`, `uni tool` for one script)
./uni verify                   # fmt --check, vet and every test suite (CI also runs bench); before merging
./uni test --long              # when a game's rules, physics, netcode or rollback changed: the full-length suites
```

## Where things are

- The board (above): current and upcoming work; decided designs live in the code, its READMEs and doc comments.
- `README.md`: what `unified` is, the programming model, the design and why; `docs/getting-started.md`: the
  toolchain, first commands and a new game.
- `README.md` in each package and game, `./uni doc <pkg>` for its API; `src/README.md`: how the core works inside;
  `tools/main.odin`: this repo's CLI.
- `docs/EOS.md`: online setup.
