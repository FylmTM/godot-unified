# Phase 2 results: the core (sim + rollback netcode)

2026-11-08. Spec: `spec/CORE.md`, `spec/GAME.md`. Built in C++, Odin and Rust; the cross-language comparison (numbers,
lines, build times, agent cost, per-language problems) is in `PHASE2-comparison.md`. Odin was chosen. This
page keeps the Odin-relevant results; its open items moved to `docs/WORK.md`.

## Verdict

**All three languages built the full core, and all three pass every test on every platform.** That's macOS ARM64
locally, Linux x64 and Windows x64 in CI (run 42492702833, all green), and x86_64 macOS under Rosetta.

The core proved out:
- deterministic simulation with Box3D physics inside the snapshot
- sync-test, and replay of the relay's official input log
- a Quantum-style relay with prediction, rollback, adaptive input delay and time sync
- multi-process UDP, and late join
- **snapshots made on macOS ARM64 restore bit-exactly on Linux x64 and Windows x64** (T8 in all languages)

No language hit a blocker.

## Numbers

| | C++ | Odin | Rust |
|---|---|---|---|
| T1–T9 on macOS / Linux / Windows | 9/9 · 9/9 · 9/9 | 9/9 · 9/9 · 9/9 | 9/9 · 9/9 · 9/9 |
| Rollback at 1000 enemies (step + 8-tick re-sim), macOS quiet | 1.16 ms | **0.62 ms** | 0.79 ms |
| Same, Linux CI / Windows CI (noisy shared runners) | 1.89 / 2.4–5.8 ms | 1.01 / 1.92 ms | 1.38 / 1.48 ms |
| Save / restore | 8 / 11 µs | 8 / 11 µs | 7 / 10 µs |
| Snapshot (block + physics) | 134 KB | 164 KB | 135 KB |
| Lines (core / netcode / game / bindings / CLI) | 699 / 2011 / 885 / 227 / 578 = **4400** | 589 / 1714 / 967 / 294 / 287 = **3851** | 360 / 1407 / 1199 / 679 / 535 = **4180** |
| Build: fresh / one-line edit (dev) | ~2.0 s / 0.4 s | 0.4 s / 0.4 s | 5.8 s / 0.4–0.5 s |
| Agent cost to implement (tokens / tool calls / wall time) | 447k / 135 / 53 min | 376k / 111 / 39 min | 390k / 82 / 43 min |
| Extra verification | ASan+UBSan and TSan clean (incl. late join) | Windows and Linux type-checked locally | mixed ARM64 relay + x86_64 clients over UDP |

CI wall time for one language and platform is ~8 minutes, dominated by T3's six 3600-tick real-time sessions.

## What each language ran into

- **C++:**
  - Found the spec's prediction-cap trap (a capped client stopped sending inputs, and all of them got replaced). The
    spec is now fixed.
  - The Windows build (clang-cl, sockets, timers) worked first time.
  - Silent undefined behaviour is still possible in principle; the sanitizer runs found none.
- **Odin:**
  - **Its standard library's streaming XXH3 gives wrong digests for some lengths**, so it hashes in a single call.
    That's a real maturity signal.
  - Odin now defaults to its own Windows linker (RADLINK), which mangled a quoted library path. Fixed after the first
    CI run.
  - It links a different C runtime than Box3D's build, worked around with linker flags.
  - Shared Box3D state needed a mutex when several threads create worlds.
- **Rust:**
  - The most binding code (679 lines, hand-written with layout checks).
  - Pinning the toolchain to `1.98` made rustup install a duplicate toolchain without the cross target.
  - Box3D counts a ray that starts inside a capsule as a hit (spec fixed: gameplay rays ignore players).
- **All three:**
  - The Box3D fork can save but **not load a world state from bytes**. Each language mirrored a private Box3D struct
    to restore snapshots from files and over the network. Fix in the fork: a public load-from-bytes API with
    self-contained geometry. **Must fix before building on it.**
  - Box3D leaves stale pointer bytes in snapshots. Restores are exact, but snapshot bytes differ from run to run
    (matters for compression and diffs, not correctness).
  - Explosions are rarely triggered by the scripted inputs, so tests barely cover them; a seeded scenario is needed.

## Open items before building on the core

1. Box3D fork: a load-from-bytes API, and clearing stale bytes.
2. A test scenario that forces barrel explosions and respawns inside rollback windows.
3. Optional: re-enable Box3D's AVX2 path in a separate CI job to verify it on real x86.
4. Windows ARM64 and Linux ARM64 (deferred).
