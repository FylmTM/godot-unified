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
  state; the block is zeroed before), `tick(s, w, t, ^Inputs(I, P), ^[dynamic]Event)`, `event_names`, `commands`
  (below).
- `compat_of(&GAME) -> u64`: the build's identity for netcode (layouts of S, I, Inputs; the command types; P;
  tick_hz; name; version).

`Inputs(I, P) = {present: Players, replaced: Players, input: [P]I, n_commands, commands: [16]Command}`. `present`
(a `bit_set[0..<32; u32]`) is who is in the game this tick: joining and leaving are presence changes, decided by the
relay, never flags in `I`. `replaced` marks inputs the relay substituted (informational). `inputs_same(a, b)`: same
presence, input bytes and commands.

## Commands

Signed off by the developer 2026-11-10. A one-shot action (pick an upgrade, set the map, ready up) can't be a flag
in `I`: the netcode repeats inputs (a client fills skipped ticks with its last input, the relay substitutes a late
input with the last one). A command is delivered exactly once, in order, per player; never lost, never repeated.

```odin
Cmd_Set_Map :: struct { map_index: u8, rule: Break_Rule, colors: bool }   // any plain struct, <= 64 bytes
GAME := sim.Game(...) { ..., commands = {{"set_map", Cmd_Set_Map}, {"ready", Cmd_Ready}} }   // index = kind
for &c in sim.commands(inputs, slot) {                // inside tick: in order, exactly once each
    if m, ok := sim.command_as(&c, Cmd_Set_Map); ok { ... }
}
```

- A command is **input, not state**: part of the tick's input record (`Inputs.commands`), so it is logged, replayed
  and sent to late joiners with the log; never in the block. `tick` reads it.
- Types are checked at `create` (`commands_violation`): plain data with no padding (`plain_violation`), 1..64 bytes
  (`COMMAND_MAX`), each type and name once, at most 255 kinds. Fields named `_...` are explicit padding.
- A tick holds at most `COMMANDS_PER_PLAYER` (4) of a player and `TICK_COMMANDS` (16) in all, ordered by slot, each
  player's in the order sent; more wait for the next tick, in order. `add_command(&inputs, c) -> bool`.
- `Command {id: typeid, kind, slot, size, data: [64]u8}`: `advance` fills `id` from `Game.commands` before `tick`
  (`bind_commands`); an unknown kind or a wrong size gets nil, which `command_as` never matches (bytes from the
  network are dropped the same way on every peer). `id` is not compared or sent.
- Sources (a UI, a script, a bot) send into a `Command_Out` (`kinds`, `slot`, `cap`): `send_command(out, value) ->
  bool` (false: not a declared type, or `cap` reached), `push_command(out, c)` for one built with `command_make` /
  `command_from_bytes`. Delivery (the client predicts it, the relay places it): `src/netcode/SPEC.md`.

## State model (c): tables and handles

- `Table(T, N)`: `items: [N]T`, `slots: [N]Slot`, free list, `high_water`, `count`. The zero value is empty. Stable
  indices (no swap-remove), LIFO reuse, freed items zeroed (equal states hash equal).
- `Handle(T) = {index: u16, generation: u16}`; generation 0 is never live, so `Handle{}` is null.
- `spawn(&t) -> (^T, Handle(T), ok)`, `despawn(&t, idx | handle)`, `get(&t, h) -> ^T` (nil if stale/null/out of
  range), `at(&t, i) -> (^T, alive)` for `for i in 0 ..< t.high_water { e := sim.at(&t, i) or_continue }`,
  `handle(&t, i)`, `handle_key(h) -> u32` (the deterministic key views use), `prev_item(prev, cur, i) -> (^T, ok)`
  (the same item in the previous tick's table: alive in both, same generation; views interpolate with it).
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
- **Extra** (`save/restore(slot)`, `hash(state, tick, out)` (on multiples of `DEEP_CHECKSUM_EVERY` = 16, the ticks the netcode compares, its whole internal state), `image(slot)`, `load(bytes)`): rollback state outside the
  block. The harness knows nothing about Box3D.
- **Input log** `UNIL` v4: seed, content hash, slots, input size, ticks; per tick (`write_tick`, also the netcode's
  finalized tick) present, replaced, the slots' input bytes, a command count (an empty tick costs one byte) and per
  command slot, kind, size and the struct's bytes. In memory `Input_Log` is compact (`ticks: [dynamic]Log_Tick`,
  `commands`): `log_append(&lg, &inputs)`, `log_inputs(&lg, k) -> Inputs` (tick k + 1), `log_commands`.
  `log_encode/decode/read/write`; decoding refuses a malformed tick (`read_tick`).
- **Portable snapshot** `UNIS` v4: seed, content hash, tick, block size, `layout_hash(S)` (rejects other builds),
  payload XXH3, block bytes, each Extra's image. `snapshot_encode(s, tick)`,
  `from_snapshot(&GAME, bytes) -> (^Sim, Snap_Error)` (creates the world the same way, saves tick 0, then loads; the
  error says why not, the library never prints).
- **Format versions:** readers accept only the current version of each; nothing is kept for older files yet. A format
  change bumps the version and regenerates every reference run (`uni record-reference <game>|toy`).

## Physics plug-in (`unified:physics`)

`create(settings) -> ^World` (one Box3D world, one worker unless `Settings.workers`; creation is mutex-guarded), `destroy`,
`Body_Ref {index1, generation}` (no world index, so blocks match across worlds and machines), `body_id`, `ref_of`,
`destroy_body`, `extra(w, S) -> sim.Extra`: finds every `Body_Ref` in `S` by RTTI once (fields, arrays,
table items); ring slots are Box3D snapshots (a memcpy of the world's arena); the hash is Box3D's whole-world hash
on `DEEP_CHECKSUM_EVERY` ticks, otherwise each referenced body (position, rotation, velocities; −0 → +0) in block
order; images are Box3D's canonical images with their geometry (`src/box3d_port/SPEC.md`).

## `unified:dmath`

`sqrt` (hardware), `length2/3`, `dist_sq2`, `normalize2/3` (zero below eps), `clamp_length2`, `lerp`,
`to_i32_clamped(x, lo, hi)` (clamp the f32, then convert; NaN gives lo: out-of-range conversions differ between x86
and ARM), the exact 8-direction table `DIR8_C/S` (`@(rodata)`). Transcendentals land here as fixed polynomials when a
game needs them.

## Determinism lint (`tests/lint`)

Code inside a tick (game sim packages, `dmath`, `physics`, `level`, `sim`) has an import allowlist (the deterministic
packages, `base:intrinsics`, `core:math/bits`; plus what the harness and physics need: RTTI, hashing, files, a mutex)
and may not use `foreign`, `map`, `matrix`, `f64*`/`f16*`, fused multiply-add, quaternion/complex types, cycle
counters, runtime entropy, or `x := 1.5` (an untyped float literal is f64). Its package-level variables must be
`@(rodata)` (or `::` constants): a write to one during a tick would be state outside the block. The exceptions are
named in `MUTABLE_GLOBALS` with a reason (physics' `world_mutex`). Sub-packages are scanned. It cannot see types: a
float-to-int conversion needs `dmath.to_i32_clamped` by convention.

## Open

Optional components and `using` as component; cross-table helpers; desync recovery policy; a `Handle` with a u32
index if a table needs more than 65 536 items.
