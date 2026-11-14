# src: how the code works

The `unified` collection: the deterministic harness (`sim`, with `physics` as a plug-in and `dmath`), the
input-relay netcode with a step API (`netcode`, `eos`), the generic headless runs and CLI (`headless`) that a game's
headless binary wires up, the Godot integration (`gdext`, `view`, `devui`, `godot`), and the determinism lint a
game's tests run (`lint`). The test games live in
`games/survivor/` (3D) and `games/drift/` (2D). Each package's API is in its spec (`src/<package>/SPEC.md`); this file is how the deterministic
core works inside, across packages. Toolchain: [`../README.md`](../README.md); commands: `uni -h`.

## Packages

Imports are one-way (the graph is enforced by `tests/lint`), always through the collection (`unified:<pkg>`).
Package names avoid Odin's own (`net`, `log`, `bytes`...): package names must be unique program-wide, which is why
the netcode package isn't called `net`.

## State block and pointer-freedom

A game's `State` is one struct of fixed arrays: globals, an `Rng`, fixed arrays of structs and `sim.Table(T, N)`s.
A table keeps `items` and `slots` (free-list link, generation, alive) apart, so indices are stable (no swap-remove),
freed items are zeroed, and `Handle(T)` = {index, generation} with generation 0 never live (the zero handle is
null). Physics bodies are stored as `physics.Body_Ref {index1, generation}` without Box3D's world index, so the
block is identical across the worlds of one process and across machines.

Enforcement is the RTTI walk in `sim.plain_violation`, run by `sim.create` and by `odin test`: only integers,
floats, bools, enums, bit_sets, fixed/enumerated arrays and structs of those, **and no implicit padding anywhere**.
That makes the block's memory its canonical little-endian serialization (`#assert(ODIN_ENDIAN == .Little)`): the
checksum hashes the raw bytes, a snapshot is a struct copy, the portable snapshot writes the bytes as they are, and
a player's input travels and is logged as its bytes (a command as its struct's bytes, src/sim/SPEC.md). Odin has no compile-time "is POD" trait, so this is a startup check.

Determinism: scalar f32 `+ − × ÷` and `intrinsics.sqrt` only; no `matrix` types, no `core:math` in the
deterministic packages (`sim`, `physics`, `dmath`, `netcode`, a game's sim; the netcode's ceilings are done by hand).
Render-side code (`view`, `godot`, `devui`) may use it: nothing there feeds the sim. Float→int casts only see
clamped values. `tests/lint` enforces the import and type bans per package, including the games' simulation
packages.

## Box3D

Box3D is the unified-box3d shared library (Box3D ported to Odin; upstream's C API plus our snapshots and canonical
images), pinned in `pins.cfg` and unpacked by `uni` into `.out/unified-box3d/`, whose Odin bindings are the
`box3d:` collection. Unified's code goes through `unified:b3` (`src/b3/SPEC.md`): Odin names, `[3]f32`/`[4]f32`,
mirrored defs, Odin callbacks; conversions only.

Shape categories (static/crate/barrel/player) filter the ray casts; each item's shape carries
`user_material_id = 1000 + item index`, which ray results report, so a projectile knows which barrel it hit without
a lookup. Both survive save/restore (they're in Box3D's shape structs).

## Snapshots

- Ring of 16: the block copy, the tick's events and every Extra's save (physics: a Box3D snapshot per slot, a memcpy
  of the world's arena), saved after every step (including tick 0). Restore = copy back + the extras' restores.
- Portable snapshot (`snapshot`/`resume`, late join): `UNIS`, seed, content hash, tick, block size, the block type's
  layout hash, an XXH3 of the payload, the block bytes and each Extra's image (physics: Box3D's canonical image with
  its geometry, the same bytes on every platform). The receiver builds the same initial world, saves tick 0, then
  loads the image.

## Checksum

XXH3-64 (seed 0) over the tick (u32 LE), the block bytes, then each Extra's bytes: physics appends every body a
`Body_Ref` in the block points at, in block memory order (position, rotation, linear and angular velocity,
−0.0 → +0.0). The bytes are copied into one buffer and hashed one-shot. **Odin bug found:** `core:hash/xxhash`'s
*streaming* XXH3 (`XXH3_64_update/digest`) returns wrong digests for some input lengths (e.g. 100,097 bytes; ~25%
of lengths between 100k and 300k), while `XXH3_64_default` matches the C reference (upstream fix: odin-lang/Odin#8257).

## Netcode, threads, sockets, timing

- **Layers:** `Link` (datagrams; in-process loopback hub with a mutex per inbox, or UDP via `core:net`,
  non-blocking; EOS in its own package) → optional `netsim` wrapper (seeded xorshift; latency, uniform jitter, loss,
  duplication, extra delay for reordering; real or virtual clock) → `Channel` (any number of links, one peer
  numbering; sequence numbers, ack + 32-bit ack field, reliable messages resent after an RTT-based timeout and
  delivered in order, keepalives every 250 ms, disconnect after 10 s of silence or a link's own disconnect event;
  epochs in every datagram end a half-open connection at once, see `channel.odin`).
- **Step API:** `relay_step`, `client_step`, `host_step` take `now_us` and return the next wake time (the next tick
  boundary, or the poll interval, 1 ms by default). No package-level threads; `headless session` runs a thread per
  client on the real clock or steps everything on one thread on the virtual clock (the end-to-end suites), the
  Godot host runs its own loop. Time-dependent code takes `now` as a parameter, so tests run whole sessions on a
  virtual clock in milliseconds.
- **Relay / client:** see `src/netcode/SPEC.md` (finalization with a 100 ms tolerance, prediction cap 218 ms, an
  input delay just big enough for the round trip, ±2% clock slew, checksums every 16 verified ticks judged by
  majority, late join from a checked snapshot of a checksum tick).
- **Threads:** Box3D world creation/destruction touch Box3D globals (world table, lazily initialised contact
  registers), so `physics.create/destroy` are serialised by a mutex.
- **Windows:** `timeBeginPeriod(1)` at headless startup (otherwise sleeps round to ~15.6 ms). UDP `recvfrom` errors
  other than would-block (WSAECONNRESET from an ICMP port-unreachable) are skipped, not treated as "no data".

## Papercuts

The Odin pitfalls (tests in their own packages, `-vet` and generic imports, package names, streaming XXH3, the
Windows CRT, timers and UDP) are in `.claude/rules/odin.md`, which Claude loads when it touches an `.odin` file.
