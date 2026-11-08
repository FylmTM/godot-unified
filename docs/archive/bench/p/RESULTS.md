# Physics rollback spike: results (2026-11-08, Apple M4 Pro, quiet machine)

Same scenario in both variants (`SPEC.md`):
- static arena, 300 or 1000 crates and barrels, 4 velocity-driven player capsules
- churn: 4 props despawned and 4 spawned every 15 ticks
- explosions every 45 ticks
- ray-fan and sphere queries feeding the hashed state

C++20, single-threaded, `-ffp-contract=off`, 60 Hz. Numbers are medians of 3 runs of `--cost --window 8` (release),
measured by the orchestrator.

## Correctness: both pass

| | Box3D (fork of 3362633) | Jolt 5.6.0 |
|---|---|---|
| Sync-test, window 8, 3600 ticks, with churn | **0 mismatches / 28,744 re-simulated ticks** | **0 mismatches / 28,744** |
| Also tested by implementers | windows 1, 4, 16, 60; 1000 bodies; no churn; Box3D debug validation | windows 1, 2, 30, 60; 1000 bodies; dev/release |
| Negative controls (the test catches real breaks) | skipping the physics restore → diverges | dropping contacts from the snapshot → 28,592 mismatches; skipping the reconcile step → restore fails |
| x86-64 under Rosetta: trace vs ARM64 / sync-test | **byte-identical / 0 mismatches** | **byte-identical / 0 mismatches** |
| Spawns and despawns inside the window | Handled by the snapshot itself: id pools and generations are restored | Our own body-ID allocator in sim state, plus a 40-line reconcile before restore (re-adds or removes ~2+2 bodies, 1–2 µs) |

## Cost of one rollback (save + restore + re-simulate 8 ticks), mean µs (p99)

| | Box3D, 300 bodies | Jolt, 300 bodies | Box3D, 1000 bodies | Jolt, 1000 bodies |
|---|---|---|---|---|
| Save | 36 (49) | 66 (89) | 126 (163) | 296 (448) |
| Restore | 41 (59) | 71 (95) | 134 (195) | 279 (395) |
| Re-simulate 8 ticks | 884 (1193) | 2381 (3020) | 3964 (6440) | 8713 (15,540) |
| **Total per tick** | **≈ 0.96 ms** | **≈ 2.5 ms** | **≈ 4.2 ms** | **≈ 9.3 ms** |
| One forward step | 123 | 309 | 510 | 1095 |
| Physics snapshot | 525 KB | 99 KB | 2.24 MB | 427 KB |

Target was ≤ 6 ms per tick. Box3D meets it at 1000 bodies (p99 of the re-sim is 6.4 ms). Jolt meets it at 300 but
not at 1000.

Configuration differs: Box3D runs 4 substeps and Jolt 1 collision step, its usual setting. So Box3D is faster
despite doing more solver iterations. Simulation quality (stacking, jitter) wasn't compared.

## Baseline: a commercial fixed-point deterministic engine

The same scenario, headless .NET 10, on the engine's own physics:
- fixed-point math
- 4 substeps × 2 iterations, warm start on, sleeping on
- single-threaded
- rollback = a full frame copy, as the engine's own rollback does

**Correctness:** sync-test gives 0 mismatches over 28,744 re-simulated ticks with its stateful PGS solver, its hybrid
solver and its legacy solver. x64 under Rosetta is byte-identical.

**Its PGS solver is stateful**, but its warm-start cache lives in the frame heap. So a frame copy is
still a complete rollback, with nothing extra to snapshot. Dropping the cache after a restore gives 28,537 mismatches.

| Rollback per tick (mean µs) | Fixed-point PGS | Fixed-point hybrid | Box3D fork | Jolt |
|---|---|---|---|---|
| 300 bodies: save + restore | 43 | 37 | 77 | 137 |
| 300 bodies: re-sim 8 ticks | 4,320 | 3,417 | 884 | 2,381 |
| **300 bodies: total** | **≈ 4.4 ms** | **≈ 3.5 ms** | **≈ 1.0 ms** | **≈ 2.5 ms** |
| 1000 bodies: total | **≈ 21 ms** | **≈ 16.6 ms** | **≈ 4.2 ms** | **≈ 9.3 ms** |
| One forward step, 300 / 1000 | 576 / 2,700 | 458 / 2,110 | 123 / 510 | 309 / 1,095 |
| State copied per snapshot, 300 / 1000 | ~420 KB / 1.39 MB (frame) | | 525 KB / 2.24 MB | 99 KB / 427 KB |

Comparability caveats:
- The baseline is fixed-point C#; the others are f32 C++.
- Solver work differs: baseline 4×2, Box3D 4 substeps, Jolt 1 step with 10+2 iterations.
- The baseline's statics live in the map, not the frame.
- The baseline normally runs physics across worker threads; these numbers are single-threaded.

So the order is clear: **single-threaded, the Box3D fork rolls back ~4× (300) to ~5× (1000) cheaper than the
fixed-point baseline**, and Jolt ~2× cheaper. The baseline's advantage is architectural: rollback can't miss state,
because there's only one place for it.

## Bindings for the other languages

- **Box3D:** the fork adds `b3World_SaveState` / `b3World_RestoreState` (plus create/destroy) to the plain C header.
  That's 184 lines of patch, only additions, no existing Box3D code changed. Odin, C# and Rust bind it exactly like
  the rest of Box3D (the same approach as Benchmark A).
- **Jolt:** no C wrapper or binding exposes save/restore. That covers joltc, JoltC, zphysics, JoltPhysicsSharp, the
  Odin bindings, and oxijolt (which refuses restores after bodies were added or removed). Every non-C++ prototype would
  need our own C shim around `SaveState`/`RestoreState` and a deterministic native Jolt build.

## Risks

- **Box3D:**
  - It's alpha (v0.1, a few months old). Its API will change.
  - The author's FAQ disclaims rollback. We'd own the fork, and the sync-test has to stay in CI.
  - Snapshots are large: raw internal arrays at their high-water mark. 16 ring slots at 1000 bodies is ~36 MB, and a
    late-join transfer needs compression (or delta encoding later).
  - Not covered: user data pointers (unused by our sim) and event arrays.
  - Untested: joints, sensors, triangle meshes, the character mover, multithreaded stepping, the AVX2 8-wide path
    (Rosetta has no AVX2).
- **Jolt:**
  - It's mature and AAA-proven, and has the best character controller.
  - But rollback costs about 2.2× more.
  - Spawn/despawn needs our own reconcile layer.
  - Bindings need our own shim in every non-C++ language.
  - Settings it doesn't save (friction, layers, shapes) must live in our state.
