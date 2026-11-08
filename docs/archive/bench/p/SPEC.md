# Physics rollback spike: Box3D fork vs Jolt

Question: can the physics world be saved and restored inside a rollback sim so that re-simulation is bit-identical,
including bodies spawned or despawned inside the rollback window, at an acceptable cost? The answer picks one engine
for all four language prototypes (`docs/PLAN.md`). Language: C++20 (both engines are used through their C/C++ API
here; the C API's coverage of save/restore matters for Odin/C#/Rust later, so report it).

Two variants, same scenario, same CLI, same build interface:
- `bench/p/box3d/`: Box3D at the pinned commit (`bench/a/vendor/box3d`, 3362633) **plus a minimal fork** that
  exposes world save/restore publicly, built on Box3D's internal serializer (`src/world_snapshot.{h,c}`:
  `b3SerializeWorld`, `b3DeserializeIntoShell`). Keep the patch small and reviewable (`fork.patch`). Restore may
  rebuild the world (destroy + recreate the shell + deserialize) if that's what the internals support. What matters is
  that body/shape ids and all solver caches come back identical.
- `bench/p/jolt/`: Jolt at the latest stable release, built with `JPH_CROSS_PLATFORM_DETERMINISTIC`, using
  `PhysicsSystem::SaveState`/`RestoreState` (StateRecorder). Jolt doesn't restore bodies added or removed inside the
  window, so solve that the way a real engine would (e.g. a pre-allocated body pool that is activated/deactivated as
  part of saved state, or recreating bodies on restore) and document the choice and its cost.

Both: `-ffp-contract=off`, single-threaded physics (no job system, or one worker), fixed 60 Hz, 4 substeps (or the
engine's closest equivalent; document).

## Scenario (identical in both, deterministic from a seed)

- **Static:** ground box 100×100 m; four walls; 12 static pillars (boxes 1×4×1 m) on a ring of radius 20 m.
- **Dynamic props:** 300 bodies at start (crates = boxes 0.5 m half-extent, barrels = cylinders or capsules
  r 0.4 h 1.0), dropped in a grid. Density 1, default friction.
- **Players:** 4 dynamic capsules (r 0.5, half-height 0.5), rotation locked, driven each tick by setting linear
  velocity from a deterministic input stream (xorshift32 per player, new direction every 20 ticks, speed 6 m/s,
  occasional jump 6 m/s).
- **Churn (rollback stress):** every 15 ticks, despawn the 4 oldest props and spawn 4 new ones at deterministic
  positions (above the arena, falling in). Body handles are kept in the sim's state block (a logical entity id →
  physics handle table) and must stay valid after restores.
- **Explosions:** every 45 ticks, an explosion at a deterministic point applies an impulse to every dynamic body
  within 6 m: direction away from the centre, magnitude `20 * (1 - d/6)`, computed by our code in the same order in
  both engines (bodies in entity-id order).
- **Queries:** every tick, each player does 8 ray casts in a fan (length 10 m) and 1 sphere overlap (r 3 m); the hit
  counts go into the hashed state (proves queries are consistent after restore).

## State and hashing

Our sim state block (pointer-free): tick, rng per player, inputs, the entity table (entity id → handle + kind +
alive), query hit counters. Per tick, hash (XXH3-64) the canonical buffer: the state block fields, then for every
alive entity in id order: position, rotation, linear and angular velocity (f32, −0 → +0). Engine-internal state is
covered by its effect on these values over time.

## Modes (CLI)

- `--ticks N --trace PATH`: forward run, one line per tick `"%06d %016x"`.
- `--synctest --window W` (default 8): each tick, save a snapshot (state block + physics) into a ring; once W ticks
  exist, restore the snapshot from W ticks ago, re-simulate W ticks with the recorded inputs, and require the hash at
  every re-simulated tick to equal the forward hash recorded for that tick. Print mismatches (first tick and count)
  and exit non-zero if any. **Must be 0 over 3600 ticks.**
- `--cost --window W [--bodies 300|1000]`: Quantum-shaped rollback cost. Each tick:
  1. save the physics state (and the state block)
  2. restore to W ticks back
  3. re-simulate W ticks

  Report as one JSON line: mean and p99 µs for save, restore, the W-tick re-sim, a plain forward step for reference,
  snapshot size in bytes, and the peak body count.
- `--bodies N`: initial prop count (300 default, 1000 for scaling).

## Deliverables per variant

- Code, `build.sh dev|release` (CMake + Ninja), `fetch.sh` if needed. Outputs `out/{dev,release}/physics-spike`.
- `README.md`: approach, fork patch size (Box3D) or pool/recreate strategy (Jolt), C API coverage of save/restore
  (Box3D: our fork; Jolt: does JoltC expose SaveState/RestoreState and StateRecorder?), any determinism caveats, and
  the results of one informal run of each mode (formal timing is done afterwards on a quiet machine).
- Also build an x86_64 macOS binary (`-DCMAKE_OSX_ARCHITECTURES=x86_64`, Box3D/Jolt built for x86_64 too) at
  `out/x64/physics-spike`, run it under Rosetta (`arch -x86_64`), and report whether its `--trace` matches ARM64 and
  `--synctest` passes.
