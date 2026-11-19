# src: how the code works

The `unified` collection, one package per directory. Each package's README (`src/<package>/README.md`) says how it
works and `uni doc <package>` prints its API; this file is how the packages fit together. The example games built on it
are in `examples/`. Toolchain: [`../docs/getting-started.md`](../docs/getting-started.md); commands: `uni help`.

## Packages

- Deterministic (the tick runs them): `sim` (the harness: state tables, the snapshot ring, checksum, events,
  commands, the input log), `physics` (Box3D as rollback state, a plug-in: `sim` knows nothing about it), `dmath`, `level`,
  `nav` (walking a level's navigation mesh), and the leaf `wire`.
- Real-time: `netcode` (input relay, prediction, rollback; it drives the sim but stays off `core:math`), `eos`
  (Epic Online Services as a `netcode.Lobby`), `headless` (a game's headless binary, the sync-test, replay and
  the other offline runs, and the end-to-end suites).
- Host: `gdext` (Godot's API), `godot` (the host, its view logic included), `devui`.
- Tools: `cli` (`uni`; it never links the sim) and `lint` (the determinism lint a game's tests run).

A package exists only where determinism rules differ, a consumer needs one piece without another, or third-party code
lives; everything else merges. Imports point one way, always through the collection (`unified:<pkg>`), and never from
a deterministic package to a real-time or host one: `tests/lint` holds the graph (an import allowlist per package,
`src/lint/README.md`). A game's sim is linted like the core's tick packages. Tick code keeps to dmath's rules
(`src/dmath/README.md`); host code (`godot`, `devui`) may use `core:math`: nothing there feeds the sim.

## Box3D

Box3D is the unified-box3d shared library (Box3D ported to Odin; upstream's C API plus our snapshots and canonical
images), pinned in `pins.cfg` and unpacked by `uni` into `.out/unified-box3d/`, whose Odin bindings are the
`box3d:` collection. Only `unified:physics` imports them (`src/physics/README.md`, The boundary).

## How a tick flows

- **A step.** The host's loop calls `netcode`'s `*_step(now_us)` (`src/netcode/README.md`, Pieces); the client steps
  the sim (`src/sim/README.md`, The tick), which steps the Extra (physics: `src/physics/README.md`, The plug-in) and
  saves the tick to its ring (The harness); the Godot host shows the newest frame (`src/godot/README.md`, How it
  works). Time is a parameter, so tests and `headless` run whole sessions on a virtual clock
  (`src/headless/README.md`, Runs).
- **The bytes.** The State is plain data without padding, so its memory is the checksum's input and a snapshot is a
  copy (`src/sim/README.md`, The state block); physics adds Box3D's snapshot and canonical image
  (`src/physics/README.md`, The plug-in).
- **A rollback.** A finalized tick that differs from its prediction restores the ring and re-simulates
  (`src/netcode/README.md`, Client).
- **A late join.** The joiner gets a portable snapshot from a player and checks it against the others' checksums
  (`src/netcode/README.md`, Late join and rejoin; the format: `src/sim/README.md`, The harness).
