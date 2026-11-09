# `unified:sim`: the deterministic harness

Decided autonomously 2026-11-09, pending developer review.

## What a game supplies

Four compile-time types and a descriptor (`sim.Game(S, I, W, P)`):

- `S` **state block**: one plain-data struct (no pointers, slices, maps, unions; no implicit padding). Its memory is
  its canonical little-endian serialization: a snapshot is a copy, the checksum hashes its bytes. Checked at
  `create` by an RTTI walk (`plain_violation`, `check_plain`).
- `I` one player's **input** for one tick, plain data.
- `W` the game's **World**: everything outside the block (physics world, per-tick scratch). Rollback state in it is
  registered as `Extra` (physics does that, see below).
- `P` player slots, 1..32.
- `Game`: `name`, `version` (bump when a tick computes differently without a layout change), `tick_hz` (a power of
  two; `dt = 1/tick_hz` exactly), `world_create(seed)`, `world_destroy`, `extras(w)`, `init(s, w, seed)` (tick-0
  state; the block is zeroed before), `tick(s, w, t, ^Inputs(I, P), ^[dynamic]Event)`, `event_names`.
- `compat_of(&GAME) -> u64`: the build's identity for netcode (layouts of S, I, Inputs; P; tick_hz; name; version).

`Inputs(I, P) = {present: Players, replaced: Players, input: [P]I}`. `present` (a `bit_set[0..<32; u32]`) is who
is in the game this tick: joining and leaving are presence changes, decided by the relay, never flags in `I`.
`replaced` marks inputs the relay substituted (informational). `inputs_same(a, b)`: same presence and input bytes.

## State model (c): tables and handles

- `Table(T, N)`: `items: [N]T`, `slots: [N]Slot`, free list, `high_water`, `count`. The zero value is empty. Stable
  indices (no swap-remove), LIFO reuse, freed items zeroed (equal states hash equal).
- `Handle(T) = {index: u16, generation: u16}`; generation 0 is never live, so `Handle{}` is null.
- `spawn(&t) -> (^T, Handle(T), ok)`, `despawn(&t, idx | handle)`, `get(&t, h) -> ^T` (nil if stale/null/out of
  range), `at(&t, i) -> (^T, alive)` for `for i in 0 ..< t.high_water { e := sim.at(&t, i) or_continue }`,
  `handle(&t, i)`, `handle_key(h) -> u32` (the deterministic key views use).
- `schema_of(S)`: tables (by shape: `items` + `slots: [N]Slot`; fixed arrays of structs count as always-live tables)
  and globals, with byte offsets. Inspectors, diffs and dumps build on it.
- `Rng` (xorshift32, 4 bytes): `rng_seed(u64)`, `rng_next`, `rng_below(n)` (Lemire, unbiased), `rng_f32`.

## Harness

`Sim(S, I, W, P)` holds the tick counter, `state`, `world`, extras and a ring of `RING = 16` slots (state copy, the
extras' saves, the events that tick emitted). Ticks count from 1; tick 0 is the initial state.

- `create(&GAME, seed)` (world, init, save tick 0), `destroy`.
- `step(s, &inputs)` = `advance` (run `tick`) + `save`. `restore(s, tick)` (extras first: on failure the block and
  tick are untouched), `state_at(s, tick)`, `events_at(s, tick)`.
- `checksum(s)`: XXH3-64 (one-shot; Odin's streaming XXH3 is wrong for some lengths) over tick (u32 LE), the block,
  then each Extra's bytes.
- **Events**: `emit(&events, kind_enum, entity, pos, value, slot)` appends a fixed 24-byte `Event`. Events live per
  tick in the ring, are re-emitted when a tick is re-simulated, and are not hashed. The netcode hands predicted and
  verified events to the view, which confirms or cancels.
- **Extra** (`save/restore(slot)`, `hash(state, out)`, `image(slot)`, `load(bytes)`): rollback state outside the
  block. The harness knows nothing about Box3D.
- **Input log** `UNIL` v2: seed, slots, input size, ticks; per tick `Inputs` bytes. `log_encode/decode/read/write`.
- **Portable snapshot** `UNIS` v2: seed, tick, block size, `layout_hash(S)` (rejects other builds), payload XXH3,
  block bytes, each Extra's image. `snapshot_encode(s, tick)`, `from_snapshot(&GAME, bytes) -> (^Sim, Snap_Error)`
  (creates the world the same way, saves tick 0, then loads; the error says why not, the library never prints).

## Physics plug-in (`unified:physics`)

`create(settings) -> ^World` (one Box3D world, one worker; creation is mutex-guarded), `destroy`,
`Body_Ref {index1, generation}` (no world index, so blocks match across worlds and machines), `body_id`, `ref_of`,
`destroy_body`, `extra(w, S) -> sim.Extra`: finds every `Body_Ref` in `S` by RTTI once (fields, arrays,
table items); the hash covers each referenced body (position, rotation, velocities; −0 → +0) in block order; images
are the fork's `b3World_SaveState` bytes.

## `unified:dmath`

`sqrt` (hardware), `length2/3`, `dist_sq2`, `normalize2/3` (zero below eps), `clamp_length2`, `lerp`,
`to_i32_clamped(x, lo, hi)` (clamp the f32, then convert; NaN gives lo: out-of-range conversions differ between x86
and ARM), the exact 8-direction table `DIR8_C/S` (`@(rodata)`). Transcendentals land here as fixed polynomials when a
game needs them.

## Determinism lint (`tests/lint`)

Code inside a tick (game sim packages, `dmath`, `physics`, `sim`) has an import allowlist (the deterministic packages,
`base:intrinsics`, `core:math/bits`; plus what the harness and physics need: RTTI, hashing, files, a mutex) and may
not use `foreign`, `map`, `matrix`, `f64*`/`f16*`, fused multiply-add, quaternion/complex types, cycle counters,
runtime entropy, or `x := 1.5` (an untyped float literal is f64). Sub-packages are scanned. It cannot see types: a
float-to-int conversion needs `dmath.to_i32_clamped` by convention.

## Open

Optional components and `using` as component; cross-table helpers; desync recovery policy; a `Handle` with a u32
index if a table needs more than 65 536 items.
