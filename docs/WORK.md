# Work

Updated 2026-11-08. Language: **Odin** (leaning; final sign-off pending). Host: **Godot**.

## In progress (background sessions)

| Session | Scope | Owns |
|---|---|---|
| Odin-only cleanup | Remove the C++/Rust implementations; idiomatic Odin project layout; OLS config; formatting (`odinfmt`); build/check/test commands; CI for Odin on Linux x64 + Windows x64; Box3D static C runtime on Windows; fix the colliding null handle and the `core:math` import in netcode | code, `tools/`, `.github/`, `README.md`, `testdata/` |
| Docs review and archive | Keep what's relevant; move research, benchmarks and investigations for other stacks to `docs/archive/` | `docs/` (except `AGENTS.md`, `WORK.md`, `PLAN.md`), `spec/` wording, `bench/` write-ups |
| Upstream XXH3 fix | Clone Odin to `~/work/personal/odin`; draft (don't submit) a fix and regression test for the streaming XXH3 bug in `core/hash/xxhash/streaming.odin` | `~/work/personal/odin` |

## In discussion (this thread)

1. **Architecture of the `unified` library**: structure, features, design, use as a library in several game
   projects.
2. **Godot integration**: GDExtension vs LibGodot, and how sim entities bind to Godot nodes (inspired by Quantum's
   entity views).
3. **Dev tooling and AI**: one `unified` CLI for everything, AI-agent knowledge (skills, docs), prior art for
   AI-assisted Godot development.
4. **Testing strategy**: sim unit tests, in-process loopback tests, multi-instance tests, F3 feedback, frame dumps,
   replays, smoke tests, CI benchmarks.

Background research feeding the discussion: GDExtension vs LibGodot; Quantum's view and prototype model; AI tooling
prior art for Godot.

## Next (after sign-offs)

- Module specs for the agreed architecture, each signed off before building.
- The `unified` CLI.
- Box3D fork: public load-from-bytes API, clearing stale bytes, and a full test suite for our use of Box3D.
- A test scenario that forces explosions and barrel respawns inside rollback windows.

## Deferred

- Windows ARM64, Linux ARM64; real Windows hardware checks beyond CI.
- Box3D's AVX2 path (compiled out today) as a separate CI job.
