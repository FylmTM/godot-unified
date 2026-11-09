# src: how the code works

The `unified` collection: the deterministic harness (`sim`, with `physics` as a plug-in and `dmath`), the
input-relay netcode with a step API (`netcode`, `eos`), the generic headless runs and CLI (`headless`) that a game's
headless binary wires up, the Godot host (`gdext`, `view`, `devui`, `godot_host`), and the determinism lint a
game's tests run (`lint`). The test game lives in
`games/survivor/`. Each package's API is in its spec (`src/<package>/SPEC.md`); this file is how the deterministic
core works inside, across packages. Toolchain: [`../README.md`](../README.md); commands: `python tools/dev.py -h`.

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
Render-side code (`view`, `godot_host`, `devui`) may use it: nothing there feeds the sim. Float→int casts only see
clamped values. `tests/lint` enforces the import and type bans per package, including the games' simulation
packages.

## Box3D binding

Hand-written, with layout `#assert`s (sizes/offsets from a C probe against the pinned headers; the layouts are the
same on x64 Linux/Windows); `src/box3d/SPEC.md` lists what we use and how to upgrade. `vendor:box3d` targets an
older commit with a different ABI.

The static library is imported by a relative path per target
(`../../third_party/box3d/build/<platform>/lib/libbox3d.a`, `box3d.lib` on Windows), where `tools/box3d.py` puts it,
so `odin build`/`odin test` need no linker flags. (`foreign import` rejects absolute paths, even from a `#config`
constant.) On Windows Box3D is built with the static CRT (`/MT`), which is what Odin links, so there is one CRT and
no `/NODEFAULTLIB` override.

Shape categories (static/crate/barrel/player) filter the ray casts; each item's shape carries
`userMaterialId = 1000 + item index`, which ray results report, so a projectile knows which barrel it hit without
a lookup. Both survive save/restore (they're in Box3D's shape structs).

## Snapshots

- Ring of 16: the block copy, the tick's events and every Extra's save (physics: `b3World_SaveState` into a
  per-slot reusable `b3WorldState`), saved after every step (including tick 0). Restore = copy back + the extras'
  restores.
- Portable snapshot (`snapshot`/`resume`, late join): `UNIS` v3, seed, content hash, tick, block size, the block type's layout
  hash, an XXH3 of the payload, the block bytes and each Extra's image. Box3D's image nulls pointers and refers to
  hull geometry by index into the `b3WorldStateCache` registry. The receiver builds the same initial world and saves
  tick 0 once, which fills its registry in the same order, then loads the image.
- **Workaround (fork gap):** the fork has no call to load an image from foreign bytes. `World_RestoreStateFromBytes`
  mirrors `b3WorldState`'s single `b3RecBuffer` (`data, capacity, size, countOnly`), points a scratch state at the
  bytes for the restore, then detaches them. It depends on that private layout; a `b3WorldState_Load` in the fork
  would remove it.

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
- **Relay / client:** see `src/netcode/SPEC.md` (finalization with a 100 ms tolerance, prediction cap 218 ms, input
  delay from RTT, ±2% clock slew, checksums every 16 verified ticks, late join with a queued snapshot or a full replay).
- **Threads:** Box3D world creation/destruction touch Box3D globals (world table, lazily initialised contact
  registers), so `physics.create/destroy` are serialised by a mutex.
- **Windows:** `timeBeginPeriod(1)` at headless startup (otherwise sleeps round to ~15.6 ms). UDP `recvfrom` errors
  other than would-block (WSAECONNRESET from an ICMP port-unreachable) are skipped, not treated as "no data".

## Papercuts

- `core:hash/xxhash` streaming XXH3 is wrong for some lengths (above). Easy to miss: it is still deterministic.
- `foreign import` takes no absolute path and no `#config` path (relative paths work, see Box3D binding).
- **Windows CRT:** Odin links `/defaultlib:libcmt` (static CRT), so tools/box3d.py builds Box3D with `/MT` too.
- `_test.odin` files are compiled into normal builds (and pull in `core:testing`): tests live in their own packages
  (`tests/<module>/`, a game's `simulation/tests/`), not next to the code.
- `core:net` is package `net`, so ours can't be.
- Windows timer resolution and UDP WSAECONNRESET (above).
- Generic procs only type-check when instantiated, so `-vet` flags an import used only inside them as unused in a
  package that doesn't call them: keep such imports behind small non-generic helpers (`sim.write_file`,
  `sim.hash_bytes`, ...), or keep them in a package of their own (`unified:headless/cli`: the game suites import
  `unified:headless` and never instantiate the CLI modes).
- A struct field named like an imported package shadows it inside generic code (`Client.sim`): netcode's
  client.odin imports `sim` as `usim`.
- Not Odin-specific: with the spec's constants and the scripted inputs barrels are rarely shot (they sit off the
  firing lines), so barrel explosions are rare in the 3600-tick tests. Physics churn inside rollback windows still
  happens through player deaths/respawns (bodies destroyed and created).
