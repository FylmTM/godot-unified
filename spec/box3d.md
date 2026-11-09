# box3d

Pending developer review (written after the code, 2026-11-09).

Box3D, pinned and forked, as the sim's physics engine: `third_party/box3d.patch` (the fork), `tools/box3d.py`
(fetch, patch, build), `src/box3d` (hand-written Odin bindings). `src/physics` wraps it as the sim's `Extra` state
(`spec/sim.md`). Tests: `tests/box3d` (the fork and bindings on their own: layouts against the pinned headers, each
call the games make, exact save/restore, portable images, damaged images, a golden trace), `tests/physics`, and
T7/T8 (`spec/headless.md`) across platforms.

## What we use

```odin
// pinned commit 3362633 (single precision): only what unified calls
CreateWorld / DestroyWorld / World_Step(world, dt, substeps) / World_CastRayClosest(world, origin, dir, filter)
CreateBody / DestroyBody / Body_Get{Position,Rotation,LinearVelocity,AngularVelocity} / Body_SetLinearVelocity
Body_ApplyLinearImpulseToCenter / MakeBoxHull / MakeCubeHull / Create{Hull,Sphere,Capsule}Shape
Default{World,Body,Shape}Def / DefaultQueryFilter

// the fork: world save/restore for rollback
CreateWorldStateCache / DestroyWorldStateCache        // registry of hull geometry, shared by a world's images
CreateWorldState / DestroyWorldState / WorldState_GetData / WorldState_GetSize
World_SaveState(world, cache, state) -> bytes          // an image with no pointers (hulls by registry index)
World_RestoreState(world, cache, state) -> ok
World_RestoreStateFromBytes(world, cache, []u8) -> ok  // ours (Odin): an image from another process or machine
```

## How it works

- **Build** (`tools/box3d.py`): the pinned commit plus the patch (must apply exactly), CMake + Ninja, static, `-O2`,
  `-ffp-contract=off` on every source (checked in `compile_commands.json`), `BOX3D_DISABLE_AVX2` so x64 runs the
  same 4-wide solver as ARM64, static CRT on Windows. clang on macOS/Linux, clang-cl on Windows. A stamp over the
  commit, patch and recipe makes the up-to-date check ~10 ms; CI's cache key adds the compiler version.
- **Bindings:** transcribed from the pinned headers; 38 `#assert`s on sizes and offsets from a C probe. The static
  library is imported by relative path per platform, so plain `odin build`/`odin test` link it.
- **Determinism:** one worker thread, f32, no FMA; world creation/destruction are serialised by a mutex in
  `physics` (they touch Box3D globals).
- **Workaround:** the fork has no "load an image from bytes" call, so `World_RestoreStateFromBytes` points a scratch
  `b3WorldState`'s private `b3RecBuffer` at the bytes for the call. It depends on that layout (24 bytes,
  asserted).

## Upgrading Box3D

1. Bump `BOX3D_COMMIT` in `tools/box3d.py`; rebase `third_party/box3d.patch` until it applies exactly.
2. Re-run the C probe against the new headers and update the bindings and their `#assert`s.
3. `python tools/dev.py test` (`tests/box3d` first: its golden trace pins the fork's results) and `check` (T1-T9,
   with the Rosetta T1/T7/T8 check). If the golden trace or T7/T8 change, the simulation changed: update `GOLDEN` in
   `tests/box3d` and regenerate the T7/T8 references (`check --regen`) deliberately, and say why in the commit.

## Open

- A `b3WorldState_Load` in the fork, which removes the workaround.
