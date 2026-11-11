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
`World_RestoreStateFromBytes(world, cache, []u8)` (no pointer trick, unlike the C binding).

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

## Open

- Phase 2, rollback: world storage in one pointer-free block (save = memcpy, the bytes hashed), hulls in the image
  (#86), clean plane-locked velocities (#87).
- Build time: each `-o:speed` whole-program build compiles the port (~5 s); `-use-separate-modules` builds split
  it into several modules and lose inlining across them (tests run ~35% slower than whole-program; `-lto:thin`
  recovers it at ~10 s compile).
- Upstream quirks seen while porting (kept as is): `Body_SetType` can return with the world locked;
  `GetWheelJointForce` adds `lowerSuspensionLimit` where an impulse is likely meant; `World_Draw` skips contacts.
- Save images hold each live shape's hull pointer in the geometry union, so images aren't byte-identical across
  processes (also true of the C fork).
