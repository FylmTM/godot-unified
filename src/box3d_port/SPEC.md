# box3d_port

Prototype, not signed off (2026-11-11). Box3D in Odin: a 1:1 port of upstream at
`336263320469e5e9febfe18697ab562488f7e97a` (`pins.cfg` `[box3d]`) plus our fork's save/restore. How it was ported,
and how to port an upstream change: `PORTING.md`. It becomes `src/box3d` when it replaces the C library.

## API

Upstream's public API minus the `b3` prefix, the names the C bindings in `src/box3d` already use
(`CreateWorld`, `Body_GetPosition`, `World_SaveState`, ...), so `physics` and the games switch with an import
change. Callbacks are Odin procs (the bindings' were `proc "c"`). Internals are package-public (Odin has no
headers); only the public API is supported outside the port and its tests.

Ours, on top of upstream: `CreateWorldStateCache`, `World_SaveState`, `World_RestoreState`, and
`World_RestoreStateFromBytes(world, cache, []u8)` (no pointer trick, unlike the C binding; it also loads canonical
images, without the cache). Canonical images: `World_SaveImage(world, state, withGeometry)` (self-contained with
geometry: late join), `World_LoadImage(world, []u8)`, and `World_HashState(world) -> u64` (the checksum).

## Proof

- Upstream's 28 test files, ported 1:1 to `tests/box3d/upstream` (run alone: `odin test tests/box3d/upstream
  -collection:unified=src`; they change Box3D's globals, so they can't share a process with other tests).
  Their determinism hashes, recorded from the C build, match.
- With `physics`, the games and our tests on the port, every golden trace and reference run recorded with the C
  library reproduces bit for bit (`uni test`, `--suite net`, `--suite godot`).

## Customizations

Every change from upstream is marked `// unified:` in the code (`grep -rn "// unified:" src/box3d_port`).
Phase 1 has only those forced by the language or by determinism:

- One SIMD path, 4-wide on `#simd[4]f32` with SSE2's semantics; the AVX2 (8-wide) path and its runtime dispatch
  are not ported, so x64 and arm64 compute the same results.
- Sensor overlaps are sorted with the ported `QSORT` instead of libc `qsort` (whose order of equal keys, and so
  which duplicate is kept, depends on the platform's libc).
- Verstable hash maps are Odin maps (lookup only, never iterated) or small chained maps keyed by content hashes.
- Length-scaled constants (`HUGE`, `LINEAR_SLOP`, ...) are package variables recomputed by
  `SetLengthUnitsPerMeter`.
- `B3_DEBUG` and validation default off (`-define:BOX3D_DEBUG=true`), as the C library is built with `NDEBUG`.
- Not ported: prefetch hints, the Tracy macros, double precision, C++ operator overloads, `#if 0` blocks.
- libc replaced: `core:os` file I/O, `core:time`/`core:thread`/`core:sync` for timers, threads and atomics,
  `remainderf` and `floorf` written out exactly.

Phase 2 adds:

- Motion locks also zero the locked velocity components when the step ends (`FinalizeBodiesTask`), after the relax
  iterations and restitution, so locked bodies report clean velocities and start the next step with them (#87).
- Canonical images (`world_image.odin`): every struct the serializer writes goes through a byte mask built once
  from type info (padding, `padding*` fields, pointers, embedded arrays and inactive union members zeroed: the
  shape geometry union whole, the contact union by `simMeshContact`, the joint sim union by type), fused into the
  copy.
- Images with their own geometry (#86): `SerializeWorld(..., img)` writes a table after the header (flags
  `GEOMETRY_TABLE`, `GEOMETRY_BYTES`: per blob kind, byte count, content hash = the blob's baked hash, or rapidhash
  for compounds, and optionally the bytes) and shapes name geometry by table index. `DeserializeIntoShell` resolves
  such a table against the world's geometry store (host memory, append-only, verifying carried blobs) before it
  touches the world. Recording keyframes keep the registry.

## Phase 2: rollback-native (pending sign-off)

Decided with the developer 2026-11-11: all five features below, storage option B, and the bar "match C, roll back
1000 bodies in under 3 ms". Each change is a marked customization, and the upstream tests keep passing.

1. **The world arena.** Everything a world keeps between steps (the arrays of bodies, shapes, contacts, joints,
   islands, solver sets and what they hold, the constraint graph, the broad-phase trees and sets, id pools,
   bitsets, manifold blocks) is allocated from one arena per world. The arena reserves its address range when the
   world is created (`core:mem/virtual`), commits pages as it grows, and never moves. Its allocator is
   deterministic (size classes plus a bump pointer), and its own state lives inside the arena. Per-step scratch,
   task contexts, events, callbacks and the scheduler stay outside it. The set of state is exactly what upstream's
   serializer saves.
2. **Save and restore are a memcpy.** `World_SaveState` copies the arena's used bytes into the slot;
   `World_RestoreState` copies them back. Pointers inside stay valid because the arena is back at the same
   address. This applies only within one process; portability is item 3's job.
3. **Portable, complete images.** The serializer (`world_snapshot`) writes canonical bytes: geometry is named by
   a content id instead of a pointer, padding and host-only fields are zeroed, and every hull, mesh, height field
   and compound that a live shape uses is written into the image (#86). Identical state gives identical bytes on
   every platform. The image is used for late join and for the checksum. Geometry stays immutable and shared, in
   a per-world store outside the arena that is only ever appended to.
4. **Internals in the checksum.** On checksum ticks (the netcode compares every 16), the physics `Extra` hashes the
   canonical image rather than only the bodies' poses.
5. **Deterministic multithreading.** The same scenes step bit-identically with 1, 2, 4 and 8 workers (a test
   compares their images), and the benchmarks measure what more workers buy.
6. **#87:** plane-locked velocity components are zeroed after the relax iterations too.

**Proof:**
- `uni bench` gains a scaling benchmark that runs on both the port and the C library: stacks of 100, 1000 and
  2000 boxes, with 1, 2 and 4 workers. It reports step, save, restore, image bytes, and an 8-tick rollback
  (restore plus 8 × (step + save)).
- The gates: step time within 5% of C on one worker, for the scaling scenes and our games; and an 8-tick rollback
  of 1000 bodies under 3 ms on this machine. The C fork takes about 3.8 ms today.
- The upstream tests, `uni test`, `--suite net` and `--suite godot` all pass. Golden traces and reference runs are
  re-recorded only where a feature changes results (#87).

## Open
- Build time: each `-o:speed` whole-program build compiles the port (~5 s); `-use-separate-modules` builds split
  it into several modules and lose inlining across them (tests run ~35% slower than whole-program; `-lto:thin`
  recovers it at ~10 s compile).
- Upstream quirks seen while porting (kept as is): `Body_SetType` can return with the world locked;
  `GetWheelJointForce` adds `lowerSuspensionLimit` where an impulse is likely meant; `World_Draw` skips contacts.
