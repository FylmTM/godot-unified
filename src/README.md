# src: how the code works

The `unified` collection, one package per directory. Each package's API is in its spec (`src/<package>/SPEC.md`);
this file is how the deterministic core works across packages. The games built on it are in `games/`. Toolchain:
[`../README.md`](../README.md); commands: `uni help`.

## Packages

- Deterministic (the tick runs them): `sim` (the harness: state tables, the snapshot ring, checksum, sync-test,
  replay, events), `physics` (Box3D as rollback state, a plug-in: `sim` knows nothing about it), `dmath`, `level`,
  and the leaf `wire`.
- Real-time: `netcode` (input relay, prediction, rollback; it drives the sim but stays off `core:math`), `eos`
  (Epic Online Services as a `netcode.Lobby`), `headless` (a game's headless binary and the test helpers).
- Host: `gdext` (Godot's API), `view` (interpolation and events, no Godot), `godot`, `devui`.
- Tools: `cli` (`uni`; it never links the sim) and `lint` (the determinism lint a game's tests run).

A package exists only where determinism rules differ, a consumer needs one piece without another, or third-party code
lives; everything else merges. Imports point one way, always through the collection (`unified:<pkg>`), and never from
a deterministic package to a real-time or host one: `tests/lint` holds the graph (an import allowlist per package,
`src/lint/SPEC.md`). A game's sim is linted like the core's tick packages.

## State block and pointer-freedom

A game's `State` is one struct of fixed arrays: globals, an `Rng`, fixed arrays of structs and `sim.Table(T, N)`s.
A table keeps `items` and `slots` (free-list link, generation, alive) apart, so indices are stable (no swap-remove),
freed items are zeroed, and `Handle(T)` = {index, generation} with generation 0 never live (the zero handle is
null). Physics bodies are stored as `physics.Body_Ref {index1, generation}` without Box3D's world index, so the
block is identical across the worlds of one process and across machines. Tooling (the inspector, desync diffs,
dumps) reads the block by Odin RTTI, with no per-type or generated code.

Enforcement is the RTTI walk in `sim.plain_violation`, run by `sim.create` and by `odin test`: only integers,
floats, bools, enums, bit_sets, fixed/enumerated arrays and structs of those, **and no implicit padding anywhere**.
That makes the block's memory its canonical little-endian serialization (`#assert(ODIN_ENDIAN == .Little)`): the
checksum hashes the raw bytes, a snapshot is a struct copy, the portable snapshot writes the bytes as they are, and
a player's input travels and is logged as its bytes (a command as its struct's bytes). Odin has no compile-time
"is POD" trait, so this is a startup check.

Determinism: scalar f32 `+ − × ÷` and `intrinsics.sqrt` only, no `matrix` types, no `core:math` in tick code
(`src/dmath/SPEC.md` has the rest). Host code (`view`, `godot`, `devui`) may use it: nothing there feeds the sim.
Float→int casts only see clamped values.

## Box3D

Box3D is the unified-box3d shared library (Box3D ported to Odin; upstream's C API plus our snapshots and canonical
images), pinned in `pins.cfg` and unpacked by `uni` into `.out/unified-box3d/`, whose Odin bindings are the
`box3d:` collection. Only `unified:physics` imports them (`src/physics/SPEC.md`, The boundary): Odin names,
`[3]f32`/`[4]f32`, mirrored defs, one wrapper per Box3D proc. Shape data a game sets (filter categories, user material ids) lives
in Box3D's shape structs, so it survives save/restore.

## Snapshots and the checksum

- **The ring** (`sim.ring_size(tick_hz)`, about 250 ms of ticks): the block copy, the tick's events and every Extra's
  save (physics: a Box3D snapshot per slot, a memcpy of the world's arena), saved after every step (including tick
  0). Restore = copy back + the Extra's restore.
- **Portable snapshot** (`snapshot`/`resume`, late join): the block bytes and each Extra's image (physics: Box3D's
  canonical image with its geometry, the same bytes on every platform), with what proves they fit (format in
  `src/sim/SPEC.md`). The receiver builds the same initial world, saves tick 0, then loads the image.
- **Checksum:** XXH3-64 over the tick, the block bytes, then each Extra's hash (physics: Box3D's whole-world hash on
  the ticks peers compare, the awake bodies' otherwise; `src/physics/SPEC.md`).

## Netcode

The step API (`src/netcode/SPEC.md`): no package-level threads; the host application calls `*_step(now_us)` from
its own loop and sleeps to the wake time it returns. Time-dependent code takes `now` as a parameter, so tests run
whole sessions on a virtual clock in milliseconds. `headless.session_run` steps a relay and its clients on one thread
on the virtual clock (the end-to-end suites, the `session` mode); the `relay` and `client` modes run on the real
clock in processes of their own, and the Godot host runs a session thread of its own (`src/godot/SPEC.md`). Box3D world creation and destruction touch Box3D globals, so `physics.create/destroy`
are serialised by a mutex.
