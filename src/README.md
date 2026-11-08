# src: how the code works

The `unified` collection: the phase-2 core of `spec/CORE.md` (deterministic sim, snapshot ring, checksums,
sync-test, replay, input-relay netcode) with the survivor-lite test game of `spec/GAME.md`. Commands and
toolchain: [`../README.md`](../README.md). Phase-2 measurements (build times, T9, lines of code): `docs/archive/PHASE2.md`.

## Packages

| Package | Files | Role |
|---|---|---|
| `box3d` | `box3d.odin` | Hand-written bindings for the pinned commit + the fork's save/restore API |
| `pod` | `pod.odin` | Plain-data check (RTTI walk) for state blocks |
| `wire` | `wire.odin` | Little-endian Writer/Reader used by every binary format |
| `game` | `state.odin`, `world.odin`, `systems.odin`, `script.odin` | State block, pools and handles, world setup, systems 1-11, scripted inputs |
| `sim` | `sim.odin`, `log.odin`, `offline.odin` | Harness (ring, checksum, portable snapshot), input log, the offline modes sim/synctest/replay/snapshot/resume/bench |
| `netcode` | `link.odin`, `udp.odin`, `netsim.odin`, `channel.odin`, `proto.odin`, `relay.odin`, `client.odin`, `session.odin` | Transports, reliable channel, relay, client, in-process sessions |
| `cli` | `main.odin`, `netmodes.odin`, `args.odin`, `platform_*.odin` | The CLI of CORE.md §3 (package `main`) |

Imports are one-way: `cli -> netcode -> sim -> game -> box3d`, plus the leaves `pod` and `wire`. Packages import
each other by relative path, so nothing inside `src/` needs a collection flag; code outside (tests, games) imports
`unified:<pkg>`. Package names avoid Odin's own (`net`, `log`, `bytes`...): package names must be unique
program-wide, which is why the netcode package isn't called `net`.

**Known inversion:** `sim` depends on `game` (it stores a `game.State` and calls `game.tick`), so the harness is not
yet reusable by another game. Making it generic is part of the architecture work in `docs/WORK.md`.

## State block and pointer-freedom

`game.State` is one struct of fixed arrays (~95 KB): globals and the RNG, 4 players, 40 items (crates/barrels),
and three `Pool($T, $N)` tables (1200 enemies, 512 projectiles, 1024 gems). A pool is a parapoly struct with a
free list: indices are stable (no swap-remove), slots carry a generation for `Handle`s. A `Handle` stores `index1` = index + 1 (like Box3D's ids and `Body_Ref`), so the zero `Handle{}` is the null handle and never matches a slot. Physics bodies are stored
as `Body_Ref {index1, generation}` without Box3D's world index, so the block is identical across the worlds of one
process and across machines.

Enforcement is the RTTI walk in `pod`, run by `sim.create` and by `odin test` (`tests/game`, `tests/sim`): only integers,
floats, bools, enums, fixed/enumerated arrays and structs of those, **and no implicit padding anywhere** (field
offsets must be contiguous). That last rule is what makes the block's memory its canonical little-endian
serialization (`#assert(ODIN_ENDIAN == .Little)`): the checksum hashes the raw bytes, a snapshot is a struct copy,
and the portable snapshot writes the bytes as they are. Odin has no compile-time "is POD" trait, so this is a
startup check, not a type error.

Determinism: scalar f32 `+ − × ÷` and `intrinsics.sqrt` only; no `matrix` types, no `core:math` anywhere in the
library (the client's input-delay ceiling is done by hand). Float→int casts only see clamped values. The angle table
is literal, per GAME.md. `tests/lint` enforces the import and type bans per package.

## Box3D binding

Hand-written, ~300 code lines, 38 layout `#assert`s (sizes/offsets from a C probe against the pinned headers; the
layouts are the same on x64 Linux/Windows). Based on benchmark A's bindings (archived) for the same commit, plus `DestroyBody`,
`ApplyLinearImpulseToCenter` and the fork API. `vendor:box3d` targets an older commit with a different ABI.

The static library is imported by a relative path per target
(`../../third_party/box3d/build/<platform>/lib/libbox3d.a`, `box3d.lib` on Windows), where `tools/box3d.py` puts it,
so `odin build`/`odin test` need no linker flags. (`foreign import` rejects absolute paths, even from a `#config`
constant.) On Windows Box3D is built with the static CRT (`/MT`), which is what Odin links, so there is one CRT and
no `/NODEFAULTLIB` override.

Shape categories (static/crate/barrel/player) filter the ray casts; each item's shape carries
`userMaterialId = 1000 + item index`, which ray results report, so a projectile knows which barrel it hit without
a lookup. Both survive save/restore (they're in Box3D's shape structs).

## Snapshots

- Ring of 16: the block copy plus `b3World_SaveState` into a per-slot reusable `b3WorldState`, saved after every
  step (including tick 0). Restore = copy back + `b3World_RestoreState`.
- Portable snapshot (`snapshot`/`resume`, late join): `UNIS`, version, seed, players, tick, sizes, an XXH3 of the
  payload, the block bytes and the Box3D image. Box3D's image nulls pointers and refers to hull geometry by index
  into the `b3WorldStateCache` registry. The receiver rebuilds the same initial world and saves tick 0 once, which
  fills its registry in the same order, then restores the image. Verified: an arm64 snapshot resumes bit-exactly
  under Rosetta (T8).
- **Workaround (fork gap):** the fork has no call to load an image from foreign bytes. `World_RestoreStateFromBytes`
  mirrors `b3WorldState`'s single `b3RecBuffer` (`data, capacity, size, countOnly`), points a scratch state at the
  bytes for the restore, then detaches them. It depends on that private layout; a `b3WorldState_Load` in the fork
  would remove it.

## Checksum

XXH3-64 (seed 0) over the block bytes followed by every alive body in entity order (items 0..39, then players):
position, rotation, linear and angular velocity, −0.0 → +0.0. The bytes are copied into one buffer and hashed
one-shot. **Odin bug found:** `core:hash/xxhash`'s *streaming* XXH3 (`XXH3_64_update/digest`) returns wrong digests
for some input lengths (e.g. 100,097 bytes; ~25% of lengths between 100k and 300k), while `XXH3_64_default` matches
the C reference (`xxhash.h`). Checked with a small program against the C reference `xxhash.h`.

## Netcode, threads, sockets, timing

- **Layers:** `Link` (datagrams; in-process loopback hub with a mutex per inbox, or UDP via `core:net`, non-blocking)
  → optional `netsim` wrapper (seeded xorshift; latency, uniform jitter, loss, duplication, extra delay for
  reordering; applied to both directions on the client side) → `Channel` (the transport interface: `send(peer,
  bytes, unreliable|reliable)`, `poll() -> events`, connect/disconnect). The channel runs the same protocol on every
  link: sequence numbers, ack + 32-bit ack field, reliable messages resent after an RTT-based timeout and delivered
  in order, keepalives every 250 ms, disconnect after 10 s of silence.
- **Relay:** owns the clock (60 Hz from `time.tick_now`), finalizes tick T once all connected active players'
  inputs are in or the clock reaches T + 6, replaces missing inputs with the last finalized one (flag set), sends
  every client its unacked finalized ticks (≤ 32) each tick, keeps the log, routes snapshots, compares checksums.
- **Client:** verified/predicted frames, rollback from the first mispredicted tick (restoring tick m−1 from the
  ring, which equals the verified state since predictions matched up to there), prediction cap 10 (stall), input
  delay `clamp(ceil((rtt/2+8)/16.667),1,6)` re-evaluated every second ±1, gap filling on delay changes, clock slewed
  ±2% towards relay tick + delay (with a hard catch-up/hold beyond 4 ticks), checksums every 16 verified ticks.
- **Late join:** the relay assigns J ≥ the asked tick, asks the lowest connected client for its verified snapshot at
  V ≥ J−1, forwards it chunked (1000 B reliable messages), and streams finalized ticks from V (tick V's inputs seed
  the joiner's prediction). The joiner runs its scheduler and sends inputs for ticks ≥ J before the snapshot lands.
- **Threads:** `session` runs the relay and each client on `core:thread` threads (one sim + one Box3D world per
  client). `b3CreateWorld`/`b3DestroyWorld` touch Box3D globals (world table, lazily initialised contact
  registers), so world creation is serialised by a mutex. Loops poll, flush and sleep 1 ms.
- **Windows:** `timeBeginPeriod(1)` at startup (otherwise `Sleep(1)` is ~15.6 ms; Odin's `time.sleep` is
  `Sleep(ms)`). UDP `recvfrom` errors other than would-block (WSAECONNRESET from an ICMP port-unreachable) are
  skipped, not treated as "no data".

## Papercuts

- `core:hash/xxhash` streaming XXH3 is wrong for some lengths (above). Easy to miss: it is still deterministic.
- `foreign import` takes no absolute path and no `#config` path (relative paths work, see Box3D binding).
- **Windows CRT:** Odin links `/defaultlib:libcmt` (static CRT), so tools/box3d.py builds Box3D with `/MT` too.
- `_test.odin` files are compiled into normal builds (and pull in `core:testing`): tests live in `tests/`, not next
  to the code.
- `core:net` is package `net`, so ours can't be.
- Windows timer resolution and UDP WSAECONNRESET (above).
- Not Odin-specific: with the spec's constants and the scripted inputs barrels are rarely shot (they sit off the
  firing lines), so barrel explosions are rare in the 3600-tick tests. Physics churn inside rollback windows still
  happens through player deaths/respawns (bodies destroyed and created).
