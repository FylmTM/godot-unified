# unified core: Odin

The phase-2 core of `spec/CORE.md` (deterministic sim, snapshot ring, checksums, sync-test, replay, Quantum-style
relay netcode) with the survivor-lite game of `spec/GAME.md`, in Odin.

```
python impl/odin/build.py dev|release        # -> impl/odin/out/<mode>/unified[.exe]
python impl/odin/build.py release --check    # + odin check for linux_amd64, windows_amd64, darwin_arm64
python impl/odin/build.py release --arch x86_64   # macOS: darwin_amd64 build for Rosetta checks
python tools/check.py odin                   # T1-T9
odin test src/core -extra-linker-flags:-L<box3d lib dir>   # POD-walker tests
```

## Toolchain

- Odin `dev-2026-11:9a6991685` (Homebrew `odin 2026-11a`, LLVM 22 backend), on PATH. Python 3.9+ for `build.py`.
- Box3D: `tools/box3d.py` (pinned commit + `third_party/box3d.patch`), Apple clang 21, `-O2 -ffp-contract=off`.
- Flags: dev `-o:none -debug`, release `-o:speed`; both `-vet -strict-style -vet-tabs -warnings-as-errors`.
  **Bounds checks stay on in release**: they cost ~5% of the T9 step + re-sim (0.71 vs ~0.66 ms), which is not
  worth losing the safety net for agent-written code.
- **Release is one LLVM module** (Odin's default for `-o:speed`): 2.5 s. `-use-separate-modules` builds in 0.7 s but
  the bench runs ~1.8x slower (step 143 vs 81 µs, re-sim 1153 vs 605 µs), because the single module inlines the
  systems. At this size (~3.9k lines) the single-module cost is fine; bench/s showed it explodes at 100k lines.

## Structure

| Package | Files | Role |
|---|---|---|
| `src/box3d` | `box3d.odin` | Hand-written bindings for the pinned commit + the fork's save/restore API |
| `src/game` | `state.odin`, `world.odin`, `systems.odin`, `script.odin` | State block, tables, world setup, systems 1-11, scripted inputs |
| `src/core` | `sim.odin`, `log.odin`, `offline.odin`, `pod.odin`, `bytes.odin` | Sim harness (ring, checksum, portable snapshot), input log, sim/synctest/replay/snapshot/resume/bench, POD check, LE writer/reader |
| `src/netcode` | `link.odin`, `udp.odin`, `netsim.odin`, `channel.odin`, `proto.odin`, `relay.odin`, `client.odin`, `session.odin` | Transports, reliable channel, relay, client, in-process sessions |
| `src/cli` | `main.odin`, `netmodes.odin`, `args.odin`, `platform_*.odin` | The CLI of CORE.md §3 (package `main`) |

Imports are one-way: `cli -> netcode -> core -> game -> box3d`. The package is called `netcode`, not `net`:
Odin package names must be unique program-wide and `core:net` already takes `net`.

## State block and pointer-freedom

`game.State` is one struct of fixed arrays (~95 KB): globals and the RNG, 4 players, 40 items (crates/barrels),
and three `Pool($T, $N)` tables (1200 enemies, 512 projectiles, 1024 gems). A pool is a parapoly struct with a
free list: indices are stable (no swap-remove), slots carry a generation for `Handle`s. Physics bodies are stored
as `Body_Ref {index1, generation}` without Box3D's world index, so the block is identical across the worlds of one
process and across machines.

Enforcement is the RTTI walk in `core/pod.odin`, run by `sim_create` (and `odin test src/core`): only integers,
floats, bools, enums, fixed/enumerated arrays and structs of those, **and no implicit padding anywhere** (field
offsets must be contiguous). That last rule is what makes the block's memory its canonical little-endian
serialization (`#assert(ODIN_ENDIAN == .Little)`): the checksum hashes the raw bytes, a snapshot is a struct copy,
and the portable snapshot writes the bytes as they are. Odin has no compile-time "is POD" trait, so this is a
startup check, not a type error.

Determinism: scalar f32 `+ − × ÷` and `intrinsics.sqrt` only; no `matrix` types, no `core:math` in the sim (the
netcode client uses `math.ceil` on f64 for the input delay, which never feeds the sim). Float→int casts only see clamped values. The angle
table is literal, per GAME.md.

## Box3D binding

Hand-written, 294 code lines, 38 layout `#assert`s (sizes/offsets from a C probe against the pinned headers; the
layouts are the same on x64 Linux/Windows). Based on bench/a's bindings for the same commit, plus `DestroyBody`,
`ApplyLinearImpulseToCenter` and the fork API. `vendor:box3d` targets an older commit with a different ABI.

Linked as `"system:box3d"` (`"system:box3d.lib"` on Windows) with the library directory from
`tools/box3d.py --json` passed through `-extra-linker-flags`. (`foreign import` rejects absolute paths, even from a
`#config` constant, so build.py can't inject the path any other way.)

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
  under Rosetta (T8 below).
- **Workaround (fork gap):** the fork has no call to load an image from foreign bytes. `World_RestoreStateFromBytes`
  mirrors `b3WorldState`'s single `b3RecBuffer` (`data, capacity, size, countOnly`), points a scratch state at the
  bytes for the restore, then detaches them. It depends on that private layout; a `b3WorldState_Load` in the fork
  would remove it.

## Checksum

XXH3-64 (seed 0) over the block bytes followed by every alive body in entity order (items 0..39, then players):
position, rotation, linear and angular velocity, −0.0 → +0.0. The bytes are copied into one buffer and hashed
one-shot. **Odin bug found:** `core:hash/xxhash`'s *streaming* XXH3 (`XXH3_64_update/digest`) returns wrong digests
for some input lengths (e.g. 100,097 bytes; ~25% of lengths between 100k and 300k), while `XXH3_64_default` matches
the C reference (`xxhash.h`). Checked with a small program against bench/a's `xxhash.h`.

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

## Lines of code (non-blank, non-comment)

| core | netcode | game | bindings | cli | total |
|---:|---:|---:|---:|---:|---:|
| 589 | 1714 | 967 | 294 | 287 | 3851 |

(core = harness, ring, checksum, snapshots, log, offline modes; tests not counted.)

## Build times (M4 Pro, warm, Odin only; Box3D comes prebuilt from tools/box3d.py)

Odin compiles the whole program every time, so a fresh build and a one-line edit cost the same.

| | fresh | edit |
|---|---:|---:|
| dev (`-o:none -debug`) | 0.4 s | 0.4 s |
| release (`-o:speed`, single module) | 2.5 s | 2.5 s |
| `odin check` | 0.05 s | |

## T9 (`bench --enemies 1000 --window 8 --ticks 600`, release, M4 Pro)

| | mean µs | p99 µs |
|---|---:|---:|
| forward step | 83 | ~130 |
| save | 9 | ~16 |
| restore | 12 | ~17 |
| 8-tick re-sim (step + save per tick) | 625 | ~1000 |
| **step + re-sim** | **0.71 ms** (target ≤ 6 ms) | |
| snapshot | 164,261 bytes (block 94,904 + Box3D image) | |

## Results on macOS ARM64

`python tools/check.py odin`: T1–T9 pass (`--regen` created `testdata/odin/`). Under Rosetta
(`build.py release --arch x86_64`, macos-x64 Box3D, `check.py --no-build --only T1,T7,T8`): T1 0 mismatches, T7
replay == the arm64 `ref.trace`, T8 the arm64 snapshot resumes bit-exactly.

## Papercuts

- `core:hash/xxhash` streaming XXH3 is wrong for some lengths (above). Easy to miss: it is still deterministic.
- `foreign import` takes no absolute path and no `#config` path; `system:` names go to `link.exe` verbatim, so the
  Windows name needs `.lib`.
- **Windows CRT:** Odin links `/defaultlib:libcmt` (static CRT); tools/box3d.py builds Box3D with `/MD`. build.py
  passes `/NODEFAULTLIB:libcmt /DEFAULTLIB:msvcrt` so the program uses one (DLL) CRT. Not yet verified on Windows.
- `core:net` is package `net`, so ours can't be.
- Windows timer resolution and UDP WSAECONNRESET (above).
- Not Odin-specific: with the spec's constants and the scripted inputs barrels are rarely shot (they sit off the
  firing lines), so barrel explosions are rare in the 3600-tick tests. Physics churn inside rollback windows still
  happens through player deaths/respawns (bodies destroyed and created).
