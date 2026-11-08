# 01: Determinism, numbers and physics

Research date: 2026-11-07, updated 2026-11-08 after the phase 1 and 2 results. Versions checked: Box3D v0.1.0 (main
at 2026-10-27), Box2D 3.2. "Unverified" marks anything not confirmed from a primary source.

## Decisions

1. **IEEE `f32` with deterministic discipline, not fixed point.** Box3D is float-based and tests **bit-identical
   results across ARM64 and x64 in CI**. Fixed point would mean writing our own rigid-body engine.
2. **Physics: our Box3D fork with world save/restore** (`third_party/box3d.patch`). Measured in phase 1: bit-exact
   under sync-test with spawn/despawn churn, bit-exact on x86-64 under Rosetta and against ARM64, about 1.0 / 4.2 ms
   per tick of rollback at 300 / 1000 bodies. Box3D already has a complete internal world snapshot; the fork exposes
   it. Open: a public load-from-bytes API with self-contained geometry, and clearing stale pointer bytes (see
   `../archive/PHASE2.md`). Jolt is the fallback if dynamics quality or the character controller decides it.
3. **Keep the 1000+ swarm agents out of the rigid-body engine.** Agents live in our contiguous state block, move
   kinematically with a spatial hash, and only *query* physics. Rigid bodies stay at roughly 200–400 **awake** at
   once. Sleeping bodies are almost free.
4. **Physics is the one subsystem outside the "one pointer-free block" design.** A snapshot is
   `memcpy(block) + physics.save()`: **one save and one restore per tick**, not one per predicted frame.
5. **Determinism is enforced by tooling, not by hope:** a pinned toolchain, no FMA contraction (Box3D included), the
   Box3D AVX2 path compiled out (x64 runs the same 4-wide solver as ARM64), Box3D with 1 worker, one deterministic
   math module, lints that ban `core:math` transcendentals in sim code, and per-tick checksum CI.

## Float determinism: what breaks it and how to control it

Modern x64 (SSE2+) and ARM64 both implement IEEE-754 binary32/64 `+ − × ÷ sqrt` with round-to-nearest. Those
operations are **bit-exact everywhere**. The traps are everything around them:

| Hazard | Where it bites | Control |
|---|---|---|
| **FMA contraction** (`a*b+c` fused, one rounding) | **Clang contracts by default since v14** (`-ffp-contract=on`), and that bites on ARM64 where FMA is baseline ([LLVM commit](https://lists.llvm.org/pipermail/cfe-commits/Week-of-Mon-20211108/391738.html), [OpenFOAM report](https://develop.openfoam.com/Development/openfoam/-/issues/2958)). GCC defaults to `fast` in GNU mode. MSVC stopped contracting under `/fp:precise` only in VS2022 ([MS docs](https://learn.microsoft.com/en-us/cpp/build/reference/fp-specify-floating-point-behavior)). | C/C++: `-ffp-contract=off` (clang-cl: `/clang:-ffp-contract=off`, as [Box3D's CMake](https://github.com/erincatto/box3d/blob/main/CMakeLists.txt) does), MSVC `/fp:precise` without `/fp:contract`. |
| **Fast-math / reassociation** | `-ffast-math`, `/fp:fast`, Odin/LLVM fast-math flags | Never in sim code. Erin Catto measured no real speedup ([Box2D blog](https://box2d.org/posts/2024/08/determinism/)). |
| **libm transcendentals** (`sin`, `cos`, `atan2`, `exp`, `pow`) | Different CRTs give different last bits. Box2D found `atan2f` differs across platforms. | Our own or a pinned implementation (below). Box2D/Box3D hand-code `atan2`/`cos`/`sin`. |
| **x87 / excess precision** | 32-bit x86 only | Irrelevant: all our targets are 64-bit SSE2/NEON. |
| **SIMD width / horizontal ops** | A different reduction order (dot products, sums) on SSE vs NEON vs AVX. Approximate `rsqrtps`/`frsqrte` differ by ISA. | Same lane width on every platform, or scalar. Box3D's goldens match across NEON, x64 SIMD and scalar ARM64. Never use approximate reciprocal instructions. |
| **min/max and signed zero** | x86 `minss` returns the 2nd operand on ties/NaN, ARM `fmin` orders −0 < +0. | Hash *values* with canonicalized ±0. Run CI on real ARM. |
| **Denormals / FTZ / rounding mode** | Thread-local MXCSR/FPCR. Some audio or graphics middleware sets FTZ/DAZ. | Assert the FP environment at sim-thread start and after each foreign call. |
| **NaN payloads** | Non-deterministic sign and payload per RFC 3514. On x87 they change across returns. | Treat NaN as a bug: assert in debug builds, quarantine. Never hash raw NaN bits. |
| **Non-float nondeterminism** | `std::sort` (unstable, differs per STL), `std::hash`, random-seeded hash maps, parallel reductions, iteration over pointer-keyed maps, thread timing | Stable sorts on total keys, fixed-seed hashers, ordered containers in sim state. |
| **Compiler/toolchain changes** | Determinism is "brittle" (Catto). One codegen change breaks it. | Pin the Odin and C compiler versions per release. Both peers must run the same build (enforce a version handshake). |

**Odin** (LLVM backend): what its built-in `sin` and friends lower to, and its contraction default, were
**unverified** at research time. Policy: our own math plus per-tick checksum CI, no `core:math` transcendentals, and
FMA contraction off in every compiled unit (Box3D included).

## Box3D (Erin Catto, C17, MIT)

- Announced 2026-06-30 as alpha ([post](https://box2d.org/posts/2026/06/announcing-box3d/)). It is a 3D fork of
  Box2D v3: Soft Step sub-stepping solver, graph coloring, wide-SIMD contacts, CCD, triangle meshes, height fields,
  compounds, optional double-precision positions. Users include s&box (Facepunch), Esoterica and Glenn Fiedler's
  1000-player space game. 6.7k stars. Issues only; pull requests not accepted yet.
- **Determinism**: on by default, with no switch to turn it off. Order follows creation order, `-ffp-contract=off`,
  `/fp:precise` and custom `atan2`/`sin`/`cos`. Multithreaded results match across worker counts. CI checks one set
  of golden hashes (ragdoll, wave pile, mesh drop, and a scene of queries issued during the step) on macOS ARM,
  Windows x64 (MSVC and clang-cl), Windows ARM64 scalar and Linux, at -O0 and -O2
  ([test_determinism.c](https://github.com/erincatto/box3d/blob/main/test/test_determinism.c)).
- **Rollback**: the [FAQ](https://github.com/erincatto/box3d/blob/main/docs/faq.md) says "Box3D does not have
  rollback determinism", because it "caches a lot of internal state". The internal `b3SerializeWorld` /
  `b3DeserializeIntoShell` ([recording.md](https://github.com/erincatto/box3d/blob/main/docs/recording.md)) capture
  bodies, shapes, joints, **contacts with warm-start impulses, island/sleep partition, broad-phase trees and id
  pools**: exactly what rollback needs. The replay player already restores a keyframe, re-steps and checks hashes:
  rollback in all but name. Limits: a restore needs a fresh "shell" world; the image is a raw struct image gated on
  a layout hash (same build only); user data and callbacks are not captured; and "Box3D does not yet expose a
  standalone save-state / restore API", so our fork adds one. **Unverified
  idea**: route all allocations (`b3SetAllocator`) into a fixed-address arena and memcpy it plus the static
  `b3_worlds[]` slot.
- **Character**: `b3World_CastMover` / `CollideMover` / `b3SolvePlanes`, a geometric capsule mover with no
  built-in up axis. Marked "experimental"; better movement is on the roadmap. We write our own controller on raw
  casts anyway.
- **Performance** (author's numbers, [benchmark/](https://github.com/erincatto/box3d/tree/main/benchmark)): M2 Air,
  one thread, `large_pyramid` (5,050 boxes) runs at 9.0 ms/step and `many_pyramids` (~10,800 boxes) at 19.2 ms/step,
  so **about 1.8 µs per awake stacked body per step**. Scaling is about 3.2× on 4 threads.
- **Bindings**: plain C; our Odin bindings are hand-written (phase 2: 294 lines).

## Rollback performance budget

**Model**: relay-stamped rollback. Each tick advances the verified frame by one confirmed step, restores, and
re-predicts up to "now". With host-stamped inputs the prediction depth is about RTT / 16.7 ms − input delay: 4–8
frames at 60–130 ms RTT with 0–2 frames of delay. **Per tick: 1 + P steps, 1 physics save, 1 restore, 1–2 block memcpys.**

**Budget**: give the sim about 8 ms of the 16.7 ms frame (render and audio on other threads). At P = 8 that leaves
**~0.9 ms per step for everything**; at P = 4, ~1.6 ms.

| Item | Per step (estimate) | × 9 steps |
|---|---|---|
| 300 awake rigid bodies (Box3D rate ~1.8 µs/body, one thread) | ~0.55 ms | ~5 ms (measured in phase 1: ≈ 1.0 ms/tick) |
| 1000 awake rigid bodies | ~1.8 ms | ~16 ms ✗ (needs 4 threads, about 5 ms) |
| 1000 sleeping bodies | ~0.05 ms (unverified) | ~0.5 ms |
| 1000 swarm agents in the ECS (SoA, spatial hash, a few rays) | ~0.1 ms (estimate) | ~0.9 ms |
| 1000 agents as rigid bodies instead | ~1.8 ms or more (dense contacts) | ✗ |
| ECS block memcpy (~1 MB) | – | <0.1 ms |
| Physics save + restore | Box3D raw image: 8 / 11 µs measured | once |

So **~200–400 awake bodies plus 1000 kinematic agents fit on one thread at P ≤ 8**. 1000 awake bodies needs
deterministic multithreading (Box3D has it) or a shallower prediction depth.

**Mitigations**, in order of value:
1. **Sleeping**: islands put to sleep cost nearly nothing, and props mostly rest.
2. **Separate swarm agents from rigid bodies**: kinematic agents in the ECS, pushing props through a few explicit
   impulses.
3. **Input delay of 1–3 frames** to shrink P. A little delay reduces mispredictions.
4. **Snapshot only verified frames**: one save per tick, never per predicted frame.
5. **Prediction culling**: skip predicting far-away entities. For physics that means freezing out-of-area islands
   in predicted steps; verified steps still simulate everything.
6. **Deterministic multithreading** inside the physics step, only when measurements demand it.
7. **Skip predicting what players can't perceive** (Catto's falling-building example): tagged cosmetic debris runs
   view-side.

## Deterministic math library

The sim needs `sqrt` (IEEE-exact, so hardware is fine), `sin`/`cos`/`sincos`, `atan2`, `asin`/`acos`, `exp`/`ln`/`pow`
for tuning curves, `floor`/`round`/`trunc` (exact), and a quaternion `slerp`/`nlerp` built on those. Plan:
- **Odin**: our own `detmath` package (hardware `+ − × ÷ sqrt` only) with polynomial transcendentals.
- **Cheaper approximations** where speed matters (Box3D's `b3ComputeCosSin`/`b3Atan2`): fine, as long as every peer
  uses the same code.
- **Enforcement**: one `detmath` module, a check banning `core:math` transcendentals in sim code, a debug assertion on the FP environment, and per-tick checksum CI.

## Risks and unknowns

1. **Box3D snapshot API**: internal today; the fork must expose load-from-bytes (see `../archive/PHASE2.md`).
2. **Box3D maturity**: alpha, one author, no PRs, the API will change, and the FAQ disclaims rollback, so we would
   own that property.
3. **Our own code breaks determinism** more often than Box3D does: HashMap order, std trig, signed zeros,
   padding bytes in hashed structs. Sync-test and checksum CI are needed from day one.
4. **Toolchain drift**: an Odin/LLVM upgrade can change codegen. Peers must run identical builds (Box3D snapshots are build-specific anyway). Re-baseline goldens on each upgrade.
5. **Arbitrary-up character movement** (wall-crawling): Box3D's mover is experimental, so we write our own controller.
6. **Query order** after a restore: Box3D's is believed stable (unverified). Always sort hits by a stable id.
