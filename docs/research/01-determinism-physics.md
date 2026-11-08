# 01: Determinism, numbers and physics

Research date: 2026-11-07. Versions checked that day: Rapier 0.36.1, Jolt 5.6.0, Box3D v0.1.0 tag (main at
2026-10-27), Avian 0.8.0, Box2D 3.2. "Unverified" marks anything I could not confirm from a primary source.

## TL;DR and recommendation

1. **Use IEEE `f32` with deterministic discipline, not fixed point.** Every mature open-source 3D physics engine is
   float-based, and three of them now test **bit-identical results across ARM64 and x64 in CI**:
   [Jolt](https://jrouwe.github.io/JoltPhysics/#deterministic-simulation) (14 targets, macOS ARM NEON and Windows
   x64 AVX2 among them), [Box3D](https://github.com/erincatto/box3d/blob/main/.github/workflows/build.yml) (macOS
   ARM, Windows x64, Windows ARM64, Linux, at -O0 and -O2, all checked against one set of golden hashes) and
   [Rapier](https://github.com/dimforge/rapier/blob/master/.github/workflows/rapier-ci-build.yml) (x86_64, aarch64
   and wasm32 checked against shared goldens, snapshot portability included). Fixed point would mean writing our own
   rigid-body engine, which is years of work and gives worse quality per CPU cycle.
2. **Physics: start with Rapier 0.36 (`enhanced-determinism`), and race Box3D against it in the spike.** Rapier is
   the only engine whose **public** save/restore covers the *whole* world (broad phase, contact graph with
   warm-start impulses, islands, handle arenas) and whose snapshots are CI-tested across architectures. It is
   native Rust, and determinism now holds with `parallel` at any thread count, with no measurable cost. Box3D is
   faster, simpler (C17, MIT) and has the same complete snapshot *internally*, but it is alpha, its FAQ says "no
   rollback determinism", and its snapshot is not public yet. **Jolt is the fallback** if dynamics quality or the
   character controller decides it: the most proven engine (Horizon Forbidden West, Death Stranding 2), but
   `RestoreState` does not cover bodies added or removed inside the rollback window, and it is C++ behind a C
   wrapper. Reject Avian (tied to Bevy, 3D determinism not tested across platforms), PhysX, Bepu and a homegrown
   fixed-point engine.
3. **Keep the 1000+ swarm agents out of the rigid-body engine.** Agents live in our contiguous ECS block (memcpy
   snapshot), move kinematically with a spatial hash, and only *query* physics. Rigid bodies stay at roughly 200–400
   **awake** at once. Sleeping bodies are almost free.
4. **The physics engine is the one subsystem outside the "one pointer-free block" design.** A snapshot becomes
   `memcpy(block) + physics.save()`. In a Quantum-style loop (always roll back to the last *verified* frame) that is
   **one save and one restore per tick**, not one per predicted frame, so even a serializing snapshot is affordable.
5. **Determinism is enforced by tooling, not by hope:** a pinned toolchain, `-ffp-contract=off` on every C/C++
   dependency, a single deterministic math module (libm-pinned transcendentals, glam `scalar-math`), lints that ban
   `f32::sin` and its relatives in sim code, and per-tick checksum CI on macOS ARM, Windows x64 and Linux.

## Options compared

| | **Rapier 0.36** | **Box3D (v0.1)** | **Jolt 5.6** | **Avian 0.8** | **Quantum (ref.)** |
|---|---|---|---|---|---|
| Language / licence | Rust / Apache-2.0 | C17 / MIT | C++17 / MIT | Rust, Bevy ECS / MIT+Apache | C#, closed, commercial |
| Cross-arch determinism | `enhanced-determinism`, **CI on x86_64 + aarch64 + wasm32** | Default on, **CI goldens on mac ARM, Win x64, Win ARM64, Linux** | `CROSS_PLATFORM_DETERMINISTIC` (~8% slower), **CI on 14 targets** | `enhanced-determinism`; **only a 2D test** in CI (Linux) | Q48.16 integers, by construction |
| Multithreaded determinism | Yes, any pool size (since 0.35) | Yes, any worker count | Yes (same binary), but callback/query *order* is not | Claimed locally (unverified) | Single sim thread |
| Save/restore API | serde of the whole `PhysicsWorld` (public) | Full world snapshot exists, **internal only** (recording/replay) | `SaveState`/`RestoreState` with filter (public); **no add/remove** | ECS components + resources; you snapshot them | The frame *is* the state (memcpy) |
| Caches in snapshot | Broad phase, contacts + impulses, islands, arenas | Same, plus id pools | Bodies, contacts (warm start), constraints; **not the broad-phase tree** | Contact graph lives in resources (unverified) | Stateless engine |
| Character controller | `KinematicCharacterController` | Mover, "experimental" | `CharacterVirtual` (best in class, any up axis) | Community crates | KCC addon (+Y hard-coded) |
| Queries | Ray/shape cast, overlap, deterministic order (unverified) | Ray/shape cast, overlap, mover casts (recorded and checked on replay) | Narrow-phase results consistent, **order varies** | Ray/shape cast | Yes |
| Maturity | 6 years, frequent breaking releases | 4 months, alpha, no PRs accepted | AAA shipped, ~5 years | Young, tied to Bevy releases | Shipped titles |
| Bindings | Native; C bindings in repo (CI job) | Trivial FFI; `boxddd`, `box3d-sys`, pure-Rust port | `joltc`/`JoltC` → `oxijolt` (Rust), `zphysics` (Zig) | Bevy only | n/a |

## Float determinism: what breaks it and how to control it

Modern x64 (SSE2+) and ARM64 both implement IEEE-754 binary32/64 `+ − × ÷ sqrt` with round-to-nearest. Those
operations are **bit-exact everywhere**. The traps are everything around them:

| Hazard | Where it bites | Control |
|---|---|---|
| **FMA contraction** (`a*b+c` fused, one rounding) | **Clang contracts by default since v14** (`-ffp-contract=on`), and that bites on ARM64 where FMA is baseline ([LLVM commit](https://lists.llvm.org/pipermail/cfe-commits/Week-of-Mon-20211108/391738.html), [OpenFOAM report](https://develop.openfoam.com/Development/openfoam/-/issues/2958)). GCC defaults to `fast` in GNU mode. MSVC stopped contracting under `/fp:precise` only in VS2022 ([MS docs](https://learn.microsoft.com/en-us/cpp/build/reference/fp-specify-floating-point-behavior)). | C/C++: `-ffp-contract=off` (clang-cl: `/clang:-ffp-contract=off`, as [Box3D's CMake](https://github.com/erincatto/box3d/blob/main/CMakeLists.txt) does), MSVC `/fp:precise` without `/fp:contract`. **Rust never contracts**: [RFC 3514](https://rust-lang.github.io/rfcs/3514-float-semantics.html) rules out turning `a*b+c` into FMA. Explicit `mul_add` is correctly rounded everywhere, but uses a slow software fallback on x64 without FMA. |
| **Fast-math / reassociation** | `-ffast-math`, `/fp:fast`, Zig `@setFloatMode(.optimized)`, Rust `algebraic_*` intrinsics | Never in sim code. Erin Catto measured no real speedup ([Box2D blog](https://box2d.org/posts/2024/08/determinism/)). |
| **libm transcendentals** (`sin`, `cos`, `atan2`, `exp`, `pow`) | Different CRTs give different last bits. Rust's [`f32::sin`](https://doc.rust-lang.org/std/primitive.f32.html#method.sin) docs say its precision "varies by platform, Rust version, and can even differ within the same execution" (const-folding vs runtime). Box2D found `atan2f` differs across platforms. | Our own or a pinned implementation (below). Jolt asks you to use its `Sin`/`Cos`; Box2D/Box3D hand-code `atan2`/`cos`/`sin`. |
| **x87 / excess precision** | 32-bit x86 only | Irrelevant: all our targets are 64-bit SSE2/NEON. |
| **SIMD width / horizontal ops** | A different reduction order (dot products, sums) on SSE vs NEON vs AVX. Rapier's `simd8` is a "separate determinism domain". Approximate `rsqrtps`/`frsqrte` differ by ISA. | Same lane width on every platform, or scalar. Rapier/Parry's `enhanced-determinism` turns on **glam `scalar-math` + `libm`** ([parry Cargo.toml](https://github.com/dimforge/parry/blob/master/crates/parry3d/Cargo.toml)). Box3D's goldens match across NEON, x64 SIMD and scalar ARM64. Never use approximate reciprocal instructions. |
| **min/max and signed zero** | x86 `minss` returns the 2nd operand on ties/NaN, ARM `fmin` orders −0 < +0. Rapier's CI notes this "diverged serialized snapshots on aarch64 for months" before an ARM job caught it. Rapier 0.35 canonicalizes signed zeros in stored impulses. | Hash *values* with canonicalized ±0. Run CI on real ARM. |
| **Denormals / FTZ / rounding mode** | Thread-local MXCSR/FPCR. Some audio or graphics middleware sets FTZ/DAZ. | Assert the FP environment at sim-thread start and after each foreign call. Jolt lists this explicitly. |
| **NaN payloads** | Non-deterministic sign and payload per RFC 3514. On x87 they change across returns. | Treat NaN as a bug: assert in debug builds, quarantine (Rapier 0.35 does this). Never hash raw NaN bits. |
| **Non-float nondeterminism** | `std::sort` (unstable, differs per STL), `std::hash`, Rust `HashMap` random seed, parallel reductions, iteration over pointer-keyed maps, thread timing | Stable sorts on total keys, fixed-seed hashers, ordered containers in sim state. Jolt lists `std::sort`/`push_heap`/`std::hash` as traps. |
| **Compiler/toolchain changes** | Determinism is "brittle" (Catto). One codegen change breaks it. | Pin rustc and C compiler versions per release. Both peers must run the same build (enforce a version handshake). |

**Per language:**
- **Rust**: the best default. No contraction, specified IEEE semantics, defined `as` casts. Gaps: std
  transcendentals, `HashMap` seeding, NaN bits. Ban `f32::{sin,cos,atan2,exp,powf,...}` in the sim crate with
  clippy `disallowed_methods`.
- **C/C++**: workable, with `-ffp-contract=off` / `/fp:precise` in *every* translation unit, third-party code
  included.
- **Zig** (`.strict` is the default float mode) and **Odin** (LLVM): what their built-in `sin` and friends lower to,
  and Odin's contraction default, are **unverified**. Same policy: our own math plus CI.
- **C#**: `Math.Sin` calls the platform CRT, so it is not deterministic. That RyuJIT never contracts implicitly is
  **unverified**. Quantum sidesteps this with integers.

## Fixed point: options and costs

- **Photon Quantum `FP`**: Q48.16 in an `int64`
  ([docs](https://doc.photonengine.com/quantum/current/manual/quantum-ecs/fixed-point)). Usable range is ±32767 if
  you want to square a value safely, with a resolution of 1.5e-5. Trig uses polynomials, sqrt and inverse trig use
  small LUTs. Quantum 3.1 moved its default tick to **64 Hz** because 1/60 is not exact in FP. OctoEscape already
  hits the precision floor ("`FP.Epsilon` is 0.001: never compare squared per-tick steps").
- **Others**: Rust [`fixed`](https://crates.io/crates/fixed) (`I48F16`) plus `cordic` for trig; C# FixedMath.Net
  and BEPUphysicsint, a fixed-point fork of Bepu **v1** that has to run single-threaded
  ([issue #42](https://github.com/bepu/bepuphysics2/issues/42)); soft-float (Berkeley SoftFloat, `rustc_apfloat`),
  which is exact but roughly 10–100× slower (estimate).

**Costs**: multiplies need a 128-bit intermediate; division is a 64-bit `idiv`; there is no wide 64-bit SIMD
multiply, so the 4–8-lane solvers are out; overflow and precision trade-offs leak into gameplay; and every number
needs conversion for the view and GPU. Decisive: **no mature open-source fixed-point 3D rigid-body engine exists.**

## Engine details

### Rapier 0.36 (Dimforge, Rust)

- **Determinism**: `enhanced-determinism` pins transcendentals to `libm` and glam to its scalar core. Since 0.35 it
  can be combined with `parallel`, gives "results bitwise identical for any thread-pool size", and "costs no
  measurable performance anymore" ([CHANGELOG](https://github.com/dimforge/rapier/blob/master/CHANGELOG.md)). It is
  incompatible with `simd8`, and peers must also match `f32`/`f64` and `block-solver`. CI runs the determinism suite
  plus `snapshot_portability` against shared goldens on x86_64, **aarch64** and wasm32. macOS and Windows
  specifically are not in that job, but the compiler is the same LLVM.
- **Save/restore**: `serde-serialize` on the whole `PhysicsWorld`
  ([guide](https://rapier.rs/docs/user_guides/rust/serialization)). It covers bodies, colliders, joints, the broad
  phase, the narrow-phase contact graph, islands and the generational arenas, so bodies spawned or despawned inside
  the window roll back correctly. The changelog shows past bugs here ("non-determinism after snapshot restoration"
  in the broad phase, and with sleeping bodies), both fixed and now covered by the `snapshot_roundtrip` test.
  **Cost: unverified.** It is heap serialization (bincode or similar), so expect allocations proportional to the
  world: likely tens to a few hundred µs for a few hundred bodies. The spike measures it.
- **Other**: `KinematicCharacterController`, CCD, multibodies, new soft bodies. The API breaks often (glam in 0.32,
  snapshot format in 0.36), so pin the version. In Godot-wrapper benchmarks by the godot-rapier author (not neutral,
  [v0.35 post](https://godot.rapier.rs/blog/v0-35-0)) Rapier is fastest on queries and the joint grid, and 10–100%
  slower than Box3D on piles, pyramids and smash.

### Box3D (Erin Catto, C17, MIT)

- Announced 2026-06-30 as alpha ([post](https://box2d.org/posts/2026/06/announcing-box3d/)). It is a 3D fork of
  Box2D v3: Soft Step sub-stepping solver, graph coloring, wide-SIMD contacts, CCD, triangle meshes, height fields,
  compounds, optional double-precision positions. Users include s&box (Facepunch), Esoterica and Glenn Fiedler's
  1000-player space game. 6.7k stars. Issues only; pull requests not accepted yet.
- **Determinism**: on by default, with no switch to turn it off. Order follows creation order, `-ffp-contract=off`,
  `/fp:precise` and custom `atan2`/`sin`/`cos`. Multithreaded results match across worker counts. CI checks one set
  of golden hashes (ragdoll, wave pile, mesh drop, and a scene of queries issued during the step) on macOS ARM,
  Windows x64 (MSVC and clang-cl), Windows ARM64 scalar and Linux, at -O0 and -O2
  ([test_determinism.c](https://github.com/erincatto/box3d/blob/main/test/test_determinism.c)). That is the strongest
  cross-arch evidence of the three.
- **Rollback**: the [FAQ](https://github.com/erincatto/box3d/blob/main/docs/faq.md) says "Box3D does not have
  rollback determinism", because it "caches a lot of internal state". The internal `b3SerializeWorld` /
  `b3DeserializeIntoShell` ([recording.md](https://github.com/erincatto/box3d/blob/main/docs/recording.md)) capture
  bodies, shapes, joints, **contacts with warm-start impulses, island/sleep partition, broad-phase trees and id
  pools**: exactly what rollback needs. The replay player already restores a keyframe, re-steps and checks hashes:
  rollback in all but name. Limits: a restore needs a fresh "shell" world; the image is a raw struct image gated on
  a layout hash (same build only); user data and callbacks are not captured; and "Box3D does not yet expose a
  standalone save-state / restore API", so we would need a small fork patch or an upstream request. **Unverified
  idea**: route all allocations (`b3SetAllocator`) into a fixed-address arena and memcpy it plus the static
  `b3_worlds[]` slot.
- **Character**: `b3World_CastMover` / `CollideMover` / `b3SolvePlanes`, a geometric capsule mover with no
  built-in up axis. Marked "experimental"; better movement is on the roadmap. OctoEscape writes its own controller
  on raw casts anyway.
- **Performance** (author's numbers, [benchmark/](https://github.com/erincatto/box3d/tree/main/benchmark)): M2 Air,
  one thread, `large_pyramid` (5,050 boxes) runs at 9.0 ms/step and `many_pyramids` (~10,800 boxes) at 19.2 ms/step,
  so **about 1.8 µs per awake stacked body per step**. Scaling is about 3.2× on 4 threads.
- **Bindings**: plain C, so it fits any language choice. Rust: `boxddd`, `box3d-sys`, and a pure-Rust port,
  [box3d-rust](https://github.com/larsbrubaker/box3d-rust), that claims to be bit-exact with the C scalar build
  (serial only, 22 stars).

### Jolt 5.6 (Jorrit Rouwe, C++, MIT)

- **Determinism**: same binary means deterministic. `CROSS_PLATFORM_DETERMINISTIC` costs ~8% and holds across
  compilers, OS and architectures, verified every build on 14 configurations
  ([docs](https://jrouwe.github.io/JoltPhysics/#deterministic-simulation)). The docs also say this feature is "less
  tested than other features". Caveats: broad-phase queries are not deterministic, narrow-phase hit *order* varies,
  listeners fire from many threads in any order, and `GetActiveBodies` order varies. Gameplay must sort every query
  result by `BodyID`.
- **Save/restore**: `SaveState(recorder, EStateRecorderState, filter)` covers global state, bodies, contacts (warm
  start) and constraints; the filter can skip static or sleeping bodies. **But**
  ([docs](https://jrouwe.github.io/JoltPhysics/#rolling-back-a-simulation)) it saves only what `Update` modifies:
  API-changed properties (friction and so on) are ours to restore, and if bodies are added or removed inside the
  window "RestoreState will not work". We would re-add them with stable IDs (`CreateBodyWithID`), the biggest
  integration cost for a freely spawning ECS. The samples' "Check Determinism" mode is the same idea as our
  sync-test.
- **Character**: `CharacterVirtual` is the most complete controller here: stairs, slopes, moving platforms, and an
  arbitrary up vector / local frame (a good fit for wall-crawling).
- **Bindings**: [amerkoleci/joltc](https://github.com/amerkoleci/joltc) (active, 221★),
  [SecondHalfGames/JoltC](https://github.com/SecondHalfGames/JoltC), [oxijolt](https://crates.io/crates/oxijolt)
  1.5 (Jolt 5.6, published 2026-11-01, young, with a `cross-platform-deterministic` feature),
  [zphysics](https://github.com/zig-gamedev/zphysics) (Zig). `rolt`/`joltc-sys` are stale (Jolt 5.0, 2024).

### The rest

- **Avian 0.8**: physics state is Bevy components, so bevy_ggrs/lightyear snapshot it like everything else. Its CI
  runs only a **2D** cross-platform test ([repo](https://github.com/avianphysics/avian)), so 3D cross-arch is
  unproven. It only makes sense if we adopt Bevy's ECS, which conflicts with the pointer-free block.
- **Box2D v3.2** (2D reference): cross-platform determinism has been a "first-class feature" since 3.1, results
  match across thread counts, and a hash is checked in CI. No rollback support, for the same internal-state reason
  ([FAQ](https://box2d.org/documentation/md_questions.html)).
- **PhysX**: determinism is local only, and results may vary across platforms
  ([discussion](https://github.com/NVIDIA-Omniverse/PhysX/discussions/99)). No complete save/restore.
- **Bepu v2**: no cross-platform guarantee; the maintainer deferred it (issue #42).

## Rollback performance budget

**Model**: Quantum-style. Each tick advances the verified frame by one confirmed step, restores, and re-predicts up
to "now". With host-stamped inputs the prediction depth is about RTT / 16.7 ms − input delay: 4–8 frames at 60–130
ms RTT with 0–2 frames of delay. **Per tick: 1 + P steps, 1 physics save, 1 restore, 1–2 block memcpys.**

**Budget**: give the sim about 8 ms of the 16.7 ms frame (render and audio on other threads). At P = 8 that leaves
**~0.9 ms per step for everything**; at P = 4, ~1.6 ms.

| Item | Per step (estimate) | × 9 steps |
|---|---|---|
| 300 awake rigid bodies (Box3D rate ~1.8 µs/body, one thread) | ~0.55 ms | ~5 ms |
| 1000 awake rigid bodies | ~1.8 ms | ~16 ms ✗ (needs 4 threads, about 5 ms) |
| 1000 sleeping bodies | ~0.05 ms (unverified) | ~0.5 ms |
| 1000 swarm agents in the ECS (SoA, spatial hash, a few rays) | ~0.1 ms (estimate) | ~0.9 ms |
| 1000 agents as rigid bodies instead | ~1.8 ms or more (dense contacts) | ✗ |
| ECS block memcpy (~1 MB) | – | <0.1 ms |
| Physics save + restore | Rapier unverified (guess 0.05–0.5 ms); Box3D raw-image fast; Jolt filtered fast | once |

So **~200–400 awake bodies plus 1000 kinematic agents fit on one thread at P ≤ 8**. 1000 awake bodies needs
deterministic multithreading (all three engines have it) or a shallower prediction depth.

**Mitigations**, in order of value:
1. **Sleeping**: islands put to sleep cost nearly nothing, and props mostly rest.
2. **Separate swarm agents from rigid bodies**: kinematic agents in the ECS, pushing props through a few explicit
   impulses.
3. **Input delay of 1–3 frames** to shrink P. Quantum recommends a little delay to reduce mispredictions.
4. **Snapshot only verified frames**: one save per tick, never per predicted frame.
5. **Prediction culling** ([Quantum](https://doc.photonengine.com/quantum/current/manual/prediction-culling)):
   skip predicting far-away entities. For physics that means freezing out-of-area islands in predicted steps;
   verified steps still simulate everything.
6. **Deterministic multithreading** inside the physics step, only when measurements demand it.
7. **Skip predicting what players can't perceive** (Catto's falling-building example): tagged cosmetic debris runs
   view-side.

## Deterministic math library

The sim needs `sqrt` (IEEE-exact, so hardware is fine), `sin`/`cos`/`sincos`, `atan2`, `asin`/`acos`, `exp`/`ln`/`pow`
for tuning curves, `floor`/`round`/`trunc` (exact), and a quaternion `slerp`/`nlerp` built on those. Plan:
- **Rust**: [`libm`](https://crates.io/crates/libm) (musl port in pure Rust, used by glam's `libm` feature and by
  Rapier) for transcendentals, plus **glam with `scalar-math` + `libm`** in the sim crate. Physics and gameplay then
  share the exact same math core, which is the configuration Rapier/Parry test.
- **Cheaper approximations** where speed matters (Box3D's `b3ComputeCosSin`/`b3Atan2`, Jolt's `Sin`/`Cos`/`ATan2`):
  fine, as long as every peer uses the same code.
- **Enforcement**: one `detmath` module, lints banning std transcendentals and `HashMap` with a random state in the
  sim crate, a debug assertion on the FP environment, and per-tick checksum CI.

## Photon Quantum as reference: what we lose and gain

Quantum does everything in Q48.16 with its own "stateless" 2D/3D physics engine
([intro](https://doc.photonengine.com/quantum/v2/quantum-intro)). The broad phase and contacts are rebuilt from the
frame, so the frame copy *is* the full state. Exact internals are not public (unverified).

- **We lose**: determinism by construction regardless of compiler, a one-memcpy snapshot that includes physics,
  and years of production netcode tuning.
- **We gain**: sub-stepping and warm-starting solvers (better stacking per µs), wide SIMD, no ±32k range or
  `FP.Epsilon` traps, one number type shared with view and GPU, mature controllers and queries, no licence or
  service.
- **The price**: pinned toolchains and cross-arch checksum CI become core infrastructure, and the physics snapshot
  sits beside the block instead of inside it.

## Risks and unknowns

1. **Engine snapshot cost and completeness** decides the engine: Rapier's serde cost is unverified, Box3D's
   snapshot is internal, Jolt has the lifecycle gap.
2. **Box3D maturity**: alpha, one author, no PRs, the API will change, and the FAQ disclaims rollback, so we would
   own that property.
3. **Our own code breaks determinism** more often than the engines do: HashMap order, std trig, signed zeros,
   padding bytes in hashed structs. Sync-test and checksum CI are needed from day one.
4. **Toolchain drift**: a rustc/LLVM upgrade can change codegen. Peers must run identical builds (the snapshots of
   both engines are build-specific anyway). Re-baseline goldens on each upgrade.
5. **macOS and Windows are not in Rapier's determinism CI** (only Linux x86_64/aarch64 and wasm). Likely
   equivalent with the same LLVM, but **unverified**.
6. **Arbitrary-up character movement** (wall-crawling): only Jolt has a mature controller for it. Elsewhere we keep
   writing our own, as today.
7. **Query order** after a restore: Jolt's varies; Rapier's and Box3D's are believed stable (unverified). Always sort
   hits by a stable id.

## Spike proposal

**Build** `spikes/det-physics` (Rust host; Box3D through `boxddd-sys` or bindgen; Rapier native; Jolt through
`oxijolt` only if time allows):
- A scene: static level of boxes plus one triangle mesh; 300 dynamic convex/box props (stacks, a ramp, a seesaw
  joint); 4 kinematic "octopus" capsules driven by a scripted-random input stream through shape casts; spawn and
  despawn 5 props per second; 1000 swarm agents in a plain SoA block, ray-casting the static world.
- A loop that is Quantum-shaped: a verified frame plus re-prediction of P frames (P = 0…8, configurable), and a
  `sync-test` mode (restore t−P, re-simulate, compare hashes every tick).
- A hash of our block plus the physics body states (canonicalized ±0) every tick, written to a trace file.

**Measure**:
1. Cross-arch: 20,000 ticks on macOS ARM (M-series), Windows x64 and Linux x64, in GitHub Actions (`macos-latest`,
   `windows-latest`, `ubuntu-latest`), with physics at 1 thread and at 4 threads.
2. Rollback correctness: (a) sync-test at P = 8 for 20,000 ticks; (b) "late input": run A with inputs as they
   arrive (predict, then correct) vs run B straight through with the final inputs. Hashes must match from the
   verified frame on.
3. Costs: µs per step at 100/300/1000 awake bodies, sleeping fraction, save and restore µs and bytes, total tick
   cost at P = 4 and P = 8, on an M-series Mac and a mid-range x64.
4. Ergonomics: lines of glue for ECS ↔ physics lifecycle, and how much of the engine had to be patched (Box3D
   snapshot exposure).

**Pass/fail**:
- **Pass** if all tick hashes are identical across the 3 OS/arch combinations and both thread counts, sync-test
  shows 0 mismatches including despawns and respawns inside the window, run A equals run B, and the P = 8 tick costs
  **≤ 6 ms** with 300 awake bodies plus 1000 agents on one physics thread, with save + restore **≤ 0.5 ms**.
- **Fail** for an engine if any cross-arch mismatch can't be traced to our own code within a day, if restore can't
  handle spawns and despawns without bookkeeping we can't hide behind one API, or if it is over budget by more than
  2×.
- **Decision rule**: if both pass, pick the faster engine, unless Box3D still needs a private fork for snapshots
  (then Rapier, revisiting when Box3D exposes save/restore). If neither passes, spike Jolt with
  `CreateBodyWithID`-based lifecycle replay.
- **Side deliverable**: the `detmath` module, the lint config and the three-OS checksum CI job, kept regardless of
  the engine chosen.
