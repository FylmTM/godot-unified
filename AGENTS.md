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
  for speed and efficiency. Main subsystems have benchmarks. A step that is slower than its documented budget is a
  bug: find out why and fix it.
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
  (design pending sign-off). Agents must know exactly how to operate everything: keep the commands below current.
- **Don't name products we take ideas from, or the developer's other games, in repo files** (the one line above
  aside). Describe designs on their own terms. Dependencies we use (Godot, Box3D, EOS, ...) are named normally.
- **Design for the library, not the demo.** Every change considers how `unified` will be used as a library by
  several co-op games with Godot, now and later.

## Workflow

- Iterate locally first (macOS ARM64, plus x86_64 under Rosetta for determinism checks). CI (Linux x64, Windows x64)
  is the final check before merging. macOS doesn't run in CI.
- CI must stay fast. A small set of key benchmarks runs on every platform in CI; the full set runs on demand.
- Keep `docs/WORK.md` current: what's being worked on now, what's next, which sessions own what.
- Commit and push only when the developer asks. Commit messages end with the co-author line.
- Docs stay lean: fold what we learn into the right doc, delete what stops being true. History lives in git.

## Layout and commands

- `src/` is the `unified` collection, one package per directory. Imports point one way (`a → b`: a imports b):
  - deterministic: `sim` → `wire`; `physics` → `sim`, `box3d`; `wire`, `box3d` and `dmath` are leaves;
  - real time: `netcode` (→ `sim`, `wire`); `eos` (EOS transport, → `netcode`); `headless` (the CLI modes a game's
    headless binary wires up, → `netcode`, `sim`; online modes come in through a transport hook);
  - host: `gdext` (Godot bindings, generated) and `imgui` are leaves; `devui` (→ `gdext`, `imgui`);
    `godot_host` (→ `sim`, `netcode`, `view`, `gdext`, `devui`; the dev UI is compiled in unless
    `-define:UNIFIED_DEVUI=false`); `view` is a host-agnostic leaf.
- `games/<game>/` is a Godot project: `simulation/<game>/` the deterministic sim (→ `sim`, `physics`, `dmath`,
  `box3d`; linted like the core), `simulation/headless/` its CLI binary (→ `headless`, plus `eos` for online
  modes), `simulation/extension/` its GDExtension (→ `godot_host`, `eos`, ...), `game/` everything Godot. The
  first game is `games/survivor/`.
- `tests/`: `odin test` packages, one per module (`box3d`, `sim`, `netcode`, `headless`, `godot_host`, `gdext`, `eos`,
  ...), importing `unified:<pkg>`; `tests/lint` is the determinism lint, `tests/godot` the binding tests under
  headless Godot. `README.md` has the toolchain; `tools/README.md` the tools.

Commands, all from the repo root, any OS (times: M-series Mac, warm). Every command rejects unknown arguments.

```
python tools/dev.py build [dev|release|debug]   # out/<mode>/survivor; dev ~1 s, release ~4 s, debug ~0.6 s
python tools/dev.py test                        # odin test, every package (~3 s, 93 tests)
python tools/dev.py check [--only T1,T7]        # release build + T1-T9 end-to-end (~32 s; on an ARM64 Mac a full
                                                # check first runs T1,T7,T8 of the x86_64 build under Rosetta;
                                                # --no-rosetta skips it)
python tools/dev.py check --arch x86_64 --only T1,T7,T8   # just the Rosetta check (~10 s)
python tools/dev.py fmt [--check]               # odinfmt (pinned, see README) (<1 s)
python tools/dev.py vet                         # odin check, strict flags, all targets (<1 s)
python tools/dev.py gen                         # Godot bindings from the committed API dump (cached; ~1 s)
python tools/dev.py godot-test                  # binding tests under headless Godot (~2 s)
python tools/dev.py godot-checks                # godot-test + every game's headless Godot checks (~25 s)
python tools/dev.py all                         # fmt --check, vet, test, check, godot-checks: everything CI runs
python tools/dev.py game build <game> [dev|release]   # the game's GDExtension (~1 s dev)
python tools/dev.py game run|editor <game>      # windowed game / the Godot editor on it
python tools/dev.py game validate|walk <game>   # GDScript: compile + load scenes (~1 s) / scripted UI walk (~4 s)
python tools/dev.py game headless|session-check|editor-check <game>   # headless Godot session checks (~5 s each)
python tools/dev.py game tour|coop|shots|play <game>   # real-game tours, EOS co-op, screenshots (windowed, manual)
python tools/dev.py game tour <game> --frames [--cold]   # frame times and first-use hitches (--cold: no shader cache)
python tools/release.py build games/<game> [--version V]   # playable zip + smoke test (~20 s warm; docs/RELEASE.md)
```

Run `fmt`, `vet` and `test` before handing work back; `check` when the sim, netcode or headless CLI changed;
`godot-checks` (or the matching `game` commands) when Godot-side code or GDScript changed. A new package in `src/`
needs a rule in `tests/lint/lint_test.odin` (the lint test fails otherwise).

## Where things are

- `docs/WORK.md`: phases, decisions, current and upcoming work.
- `docs/CONTEXT.md`: why `unified` exists and the developer's requirements.
- `spec/`: one short spec per module, plus the test game (`GAME.md`) and its client (`survivor-client.md`).
- `docs/RELEASE.md` (game builds), `docs/EOS.md` (online setup), `docs/research/` (open research).
- `docs/archive/`: phase 2 results kept for reference; the research on the stacks we didn't choose is in git
  history (`docs/archive/README.md`).
