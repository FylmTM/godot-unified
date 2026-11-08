# Benchmark A: the same headless sim core in five languages

Rust, Odin, Zig, C++ and C# each implement **exactly this spec**. All five must produce **bit-identical per-tick
hashes**. That makes the benchmark a determinism test too (different languages, the same float operations), and the
output is a fair base for comparing builds.

What it measures (on the M4 Pro, by `scripts/measure.sh`, written later; don't measure while implementing):
- clean build, incremental build after a one-line gameplay change, and a fresh git worktree build
- tick speed in release builds
- lines of binding glue and lines of gameplay code

## Layout and rules

- Directory: `bench/a/<lang>/` with `<lang>` ∈ `rust`, `odin`, `zig`, `cpp`, `csharp`. Touch nothing outside your
  directory (the shared `deps/`, `vendor/` and `scripts/` are read-only for you).
- **Physics: Box3D at the pinned commit** (`vendor/box3d`, see `scripts/fetch-box3d.sh`). The default link target is
  the shared prebuilt library in `bench/a/deps/box3d/` (`lib/libbox3d.a`, `lib/libbox3d.dylib`, `include/`), built by
  `scripts/build-box3d.sh` (Release, `-O2`, `-ffp-contract=off`, SIMD on, single precision).
- **Rust, Zig and C++ must also support building Box3D from source their own idiomatic way** (Rust: `cc` crate in a
  `build.rs`; Zig: `build.zig`; C++: CMake `add_subdirectory` / FetchContent of `vendor/box3d`). It's selected by a
  flag (see the build interface below) and must use `-O2 -ffp-contract=off -DNDEBUG` and no validation, so the
  physics stays bit-identical. Odin and C# always use the prebuilt library (neither ships a C compiler).
- **Bindings**: use your ecosystem's best realistic approach and record it in your README. Options include an
  existing maintained binding (e.g. Odin's `vendor:box3d`, after checking it matches the pinned commit's API/ABI), a
  generator (bindgen, `zig translate-c` through the build system, ClangSharp), or hand-written declarations for just
  the functions used. Large by-value structs such as `b3BoxHull` must have the exact C layout.
- **Code structure, mirroring the engine we'd build**:
  - a `sim` module/package/crate (state block, systems, hashing), separate from
  - the Box3D binding module, and from
  - `main` (CLI, timing, output).

  The swarm system lives in its own file, the **gameplay file**, which holds the edit marker (below).
- The sim state is **one contiguous, pointer-free block** (a struct of fixed-size arrays, or one byte buffer with
  typed views). Use your language's idiomatic way to enforce or check pointer-freedom (e.g. Rust `bytemuck::Pod`,
  Zig comptime checks, Odin RTTI assert, C++ `static_assert(std::is_trivially_copyable_v<…>)`, C# `unmanaged`). The
  physics world is the only state outside it.
- Single-threaded, f32 only (no f64 anywhere in the sim path), no fast-math, no FMA contraction (C/C++/Zig C-compile:
  `-ffp-contract=off`), no transcendental functions (only `+ − × ÷ sqrt`, which are bit-exact under IEEE). Write
  float expressions **exactly in the order given below** (left to right, the temporaries as named). Don't
  algebraically simplify.
- Literals are written as f32 literals (e.g. `0.1f`): each one parses to the nearest f32, the same in every language.

## Constants

```
TICKS_DEFAULT = 3600
DT            = 0.016666668f        // bits 0x3C888889; write the literal, don't compute 1/60
SUBSTEPS      = 4
GRAVITY       = (0, -10, 0)
N_PROPS       = 300
N_PLAYERS     = 4
N_AGENTS      = 1000
RING          = 16                  // snapshot ring slots
```

## World setup (creation order matters: Box3D ids and solver order depend on it)

World: `def = b3DefaultWorldDef(); def.gravity = (0.0f, -10.0f, 0.0f);` nothing else changed (no task callbacks, so
single-threaded). Then create bodies in this order. Every body uses `b3DefaultBodyDef()`, every shape uses
`b3DefaultShapeDef()`, and only the listed fields change.

1. **Ground**: static (`b3_staticBody`, i.e. the default type), position `(0, -1, 0)`, shape = hull from
   `b3MakeBoxHull(50, 1, 50)`, passed as `&boxHull.base` to `b3CreateHullShape`.
2. **Walls**, in order: position `(50, 5, 0)` hull `(1, 6, 50)`; `(-50, 5, 0)` hull `(1, 6, 50)`; `(0, 5, 50)` hull
   `(50, 6, 1)`; `(0, 5, -50)` hull `(50, 6, 1)`. All static.
3. **Props** `i = 0..299`: `b3_dynamicBody`, `layer = i / 100`, `k = i % 100`, `gx = k % 10`, `gz = k / 10`, position
   `x = (f32)gx * 2.5f - 11.25f`, `y = 2.0f + (f32)layer * 2.5f`, `z = (f32)gz * 2.5f - 11.25f` (multiply first, then
   add or subtract). Even `i`: hull `b3MakeCubeHull(0.5f)`. Odd `i`: sphere `{center (0,0,0), radius 0.5f}` via
   `b3CreateSphereShape`.
4. **Players** `p = 0..3`: `b3_dynamicBody`, positions `(20, 2, 20)`, `(-20, 2, 20)`, `(20, 2, -20)`, `(-20, 2, -20)`,
   `motionLocks.angularX = angularY = angularZ = true`, `enableSleep = false`. Capsule
   `{center1 (0, -0.5f, 0), center2 (0, 0.5f, 0), radius 0.5f}` via `b3CreateCapsuleShape`.

Keep the body ids of props and players in creation order (outside the hashed state; they are handles into the
physics world).

## State block (hashed; in-memory layout is up to you, the hash uses the canonical serialization below)

```
tick        u32                 // number of completed ticks
hits        u32
rng[4]      u32                 // initial rng[p] = 0x9E3779B9 * (p + 1) (wrapping u32 multiply)
input[4]    { dx i8, dz i8, jump u8 }   // initial all zero
agents (SoA, 1000 each):
  px, pz, vx, vz   f32
  target           u8
  blocked          u8
```

Initial agents, `i = 0..999`: `col = i % 40`, `row = i / 40`, `px = (f32)col - 19.5f`, `pz = (f32)row - 12.0f`,
everything else 0.

Scratch (not hashed, may live outside the block): the spatial grid arrays and new-velocity arrays.

## One tick (t = state.tick at the start of the tick)

**1. Inputs.** If `t % 30 == 0`, then for each player `p` in order: `x = rng[p]; x ^= x << 13; x ^= x >> 17; x ^= x
<< 5; rng[p] = x` (u32 wrapping shifts), `r = x`, `dir = r % 9`, `dx = (i8)(dir % 3) - 1`, `dz = (i8)(dir / 3) - 1`,
`jump = ((r >> 8) & 7) == 0 ? 1 : 0`. Otherwise `jump = 0` for all players (dx and dz keep their values).

**2. Apply player input.** For each player `p`: `v = b3Body_GetLinearVelocity(player[p])`; `nvx = (f32)dx * 6.0f`;
`nvz = (f32)dz * 6.0f`; `nvy = v.y`; if `jump == 1 && fabsf(v.y) < 0.1f` then `nvy = 6.0f`;
`b3Body_SetLinearVelocity(player[p], (nvx, nvy, nvz))`.

**3. Read player positions.** `pp[p] = b3Body_GetPosition(player[p])` (use `.x` and `.z`).

**4. Build the spatial grid** (scratch). Cell of agent `i`: `cx = (i32)((px + 50.0f) * 0.5f)`,
`cz = (i32)((pz + 50.0f) * 0.5f)` (truncation toward zero), each clamped to `0..49`; `cell = cz * 50 + cx`.
Counting sort: `count[2500] = 0`; for `i` in `0..999`: `count[cell(i)]++`; `start[c]` = exclusive prefix sum;
then for `i` in `0..999` in order: `items[start[cell]+fill[cell]++] = i`. Within a cell, items are in increasing `i`.

**5. Swarm velocities (phase 1: read old positions, write `nvx[i]`, `nvz[i]`, target, blocked, hits).** For each
`i` in `0..999`:
- **Target:** `best = 0; bestD2 = +inf`. For `p` in `0..3`: `dx = pp[p].x - px[i]`, `dz = pp[p].z - pz[i]`,
  `d2 = dx*dx + dz*dz` (`a = dx*dx; b = dz*dz; d2 = a + b`). If `d2 < bestD2`: `best = p; bestD2 = d2`.
  `target[i] = best`. If `bestD2 < 1.0f`: `hits += 1`.
- **Desired:** `dx = pp[best].x - px[i]`, `dz = pp[best].z - pz[i]`, `len = sqrt(dx*dx + dz*dz)`. If `len > 0.0001f`:
  `dirx = dx / len; dirz = dz / len` else `dirx = dirz = 0`. `desx = dirx * 3.0f; desz = dirz * 3.0f`.
- **Separation:** `sepx = sepz = 0`. Agent's own cell `(cx, cz)` as in step 4. For `nz` in `cz-1..cz+1` (outer), `nx`
  in `cx-1..cx+1` (inner), skipping cells outside `0..49`: for each `j` in that cell's items in order, if `j != i`:
  `ox = px[i] - px[j]; oz = pz[i] - pz[j]; d2 = ox*ox + oz*oz;` if `d2 < 1.0f && d2 > 0.00000001f`:
  `inv = 1.0f / d2; sepx = sepx + ox*inv; sepz = sepz + oz*inv`.
- **Blend:** `t1 = vx[i]*0.9f; t2 = sepx*0.5f; t3 = desx + t2; t4 = t3*0.1f; nvx = t1 + t4` (same for z with `vz`,
  `sepz`, `desz`).
- **Clamp:** `s2 = nvx*nvx + nvz*nvz`. If `s2 > 16.0f`: `k = 4.0f / sqrt(s2); nvx = nvx*k; nvz = nvz*k`.
- **Ray:** if `(i + t) % 4 == 0`: `r = b3World_CastRayClosest(world, origin (px[i], 2.0f, pz[i]), translation
  (0, -4.0f, 0), b3DefaultQueryFilter())`; `blocked[i] = (r.hit && r.point.y > 0.2f) ? 1 : 0`. Otherwise `blocked[i]`
  keeps its value. If `blocked[i] == 1`: `nvx = nvx*0.5f; nvz = nvz*0.5f`.

**6. Swarm integrate (phase 2).** For each `i`: `vx = nvx; vz = nvz; px = px + vx*DT; pz = pz + vz*DT`; then clamp:
`px = max(-49.0f, min(49.0f, px))` (same for `pz`).

**7. Physics.** `b3World_Step(world, DT, 4)`.

**8.** `tick = t + 1`. Hash (below), store the hash, then **copy the whole state block into ring slot `tick % 16`**
(a memcpy or the language's bulk copy).

## Canonical hash (XXH3-64, seed 0)

Serialize into a byte buffer, little-endian. Every f32 is written as its bits after canonicalizing `-0.0` → `+0.0`
(leave other values alone):
1. `tick` u32, `hits` u32, `rng[0..3]` u32 ×4
2. for `p` in `0..3`: `dx` i8, `dz` i8, `jump` u8, one zero byte
3. for `i` in `0..999`: `px, pz, vx, vz` (f32 ×4), `target` u8, `blocked` u8, two zero bytes
4. for each body, props `0..299` then players `0..3`: position `x, y, z`, rotation `v.x, v.y, v.z, s`, linear
   velocity `x, y, z`, angular velocity `x, y, z` (13 f32, via `b3Body_GetPosition` / `GetRotation` /
   `GetLinearVelocity` / `GetAngularVelocity`)

Hash = XXH3-64 of that buffer with seed 0. Use a real XXH3 implementation from your ecosystem (e.g. the `xxhash-rust`
crate, Odin `core:hash/xxhash`, Zig `std.hash.XxHash3`, `xxhash.h` for C++, `System.IO.Hashing.XxHash3` for C#),
not XXH64 or XXH32.

## Edit marker (for incremental-build measurement)

The gameplay (swarm) file contains exactly one line holding the token `BENCH_EDIT_MARKER` and an integer constant,
e.g. `const BENCH_EDIT: u32 = 0; // BENCH_EDIT_MARKER`. The value is reported in the JSON output (so the compiler
can't drop it) and must not affect the hash. The measuring script rewrites that number.

## CLI and output

`<binary> [--ticks N] [--trace PATH]`. Default 3600 ticks, no trace. With `--trace`, write one line per tick,
`"%06d %016x\n"` (tick after increment, hash in lowercase hex), buffered in memory during the loop and written after.
At the end, print one JSON line to stdout:
`{"lang":"<lang>","ticks":3600,"final_hash":"<16 hex>","loop_ms":<f64>,"us_per_tick_mean":<f64>,"us_per_tick_p99":<f64>,"edit_marker":<int>}`.
Time only the tick loop (steps 1–8 including hashing and the ring copy), not world setup or file I/O.

## Build interface (identical across languages)

- `./build.sh dev [--box3d-from-source]`: the build developers and agents iterate with (debug info, light or no
  optimisation, fastest compile; your language's best practice for a fast inner loop). Output:
  `out/dev/bench-a`.
- `./build.sh release [--box3d-from-source]`: optimized. Output: `out/release/bench-a`.
- The binary must run from any working directory (for C#: an apphost executable, or a thin launcher script named
  `bench-a`. Note which in your README).
- No network access during `build.sh`, once dependencies are fetched. Fetching is a separate `./fetch.sh` if your
  ecosystem needs one (cargo, NuGet, Zig packages). Document any global caches it uses.

## README.md in your directory

The toolchain version, the binding approach and why, where the gameplay file is, how pointer-freedom is checked,
anything you had to work around, and the first 5 lines of `--trace` output plus the final hash for 3600 ticks.
