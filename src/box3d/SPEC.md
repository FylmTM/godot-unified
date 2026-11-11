# box3d

Pending developer review (written after the code, 2026-11-09).

Box3D, pinned and forked, as the sim's physics engine: `third_party/box3d.patch` (the fork), `tools/box3d.py`
(fetch, patch, build), `src/box3d` (hand-written Odin bindings). `src/physics` wraps it as the sim's `Extra` state
(`src/sim/SPEC.md`). Tests: `tests/box3d` (the fork and bindings on their own: layouts against the pinned headers, each
call the games make, exact save/restore, portable images, damaged images, a golden trace), `tests/physics`, and
the games' reference runs (`src/headless/SPEC.md`) across platforms.

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

- **Build** (`uni setup`, and any command that needs it): the pinned commit (`pins.cfg`) plus the patch (must apply
  exactly), every `src/*.c` compiled by clang directly, static, `-O2 -DNDEBUG -std=gnu17 -fvisibility=hidden`,
  `-ffp-contract=off`, `BOX3D_DISABLE_AVX2` so x64 runs the same 4-wide solver as ARM64; clang-cl on Windows
  (`/std:c17 /clang:-ffp-contract=off`, static CRT `/MT`). A stamp over the pins, patch, recipe, flags, platform and
  compiler makes the up-to-date check cheap.
- **Bindings:** transcribed from the pinned headers; 38 `#assert`s on sizes and offsets from a C probe. The static
  library is imported by relative path per platform, so plain `odin build`/`odin test` link it.
- **Determinism:** one worker thread, f32, no FMA; world creation/destruction are serialised by a mutex in
  `physics` (they touch Box3D globals).
- **Workaround:** the fork has no "load an image from bytes" call, so `World_RestoreStateFromBytes` points a scratch
  `b3WorldState`'s private `b3RecBuffer` at the bytes for the call. It depends on that layout (24 bytes,
  asserted).

Upgrading: the `upgrade-dependency` skill (`.claude/skills/`).

## Open

- A `b3WorldState_Load` in the fork, which removes the workaround.
