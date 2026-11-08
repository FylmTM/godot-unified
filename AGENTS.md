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

Odin packages live in `src/` (the `unified` collection, one package per directory: `box3d`, `pod`, `wire`, `game`,
`sim`, `netcode`, `cli`); imports point one way, `cli → netcode → sim → game → box3d`, with `pod` and `wire` as
leaves. Tests are `odin test` packages in `tests/` (one per module, importing `unified:<pkg>`; `tests/lint` is the
determinism lint). `README.md` has the full layout and toolchain. Commands, all from the repo root, any OS:

```
python tools/dev.py build [dev|release|debug]   # out/<mode>/unified; dev ~1 s, release ~2.5 s
python tools/dev.py test                        # odin test, every package (~2 s)
python tools/dev.py check [--only T1,T7]        # release build + T1-T9 end-to-end (~70 s)
python tools/dev.py fmt [--check]               # odinfmt (pinned, see README)
python tools/dev.py vet                         # odin check, strict flags, all targets (<1 s)
python tools/dev.py all                         # everything CI runs
python tools/dev.py build release --arch x86_64 && python tools/check.py --only T1,T7,T8   # Rosetta check
```

Run `fmt`, `vet` and `test` before handing work back; run `check` when the sim, netcode or CLI changed. A new
package in `src/` needs a rule in `tests/lint/lint_test.odin` (the lint test fails otherwise).

## Where things are

- `docs/WORK.md`: phases, decisions, current and upcoming work.
- `docs/CONTEXT.md`: why `unified` exists and the developer's requirements.
- `spec/`: specs (core and test game today; module specs to come).
- `docs/archive/`: research and benchmarks for the stacks we didn't choose (C++, Rust, C#, Zig, Bevy...), kept for
  reference.
