# unified core: Rust

Implements [`spec/CORE.md`](../../spec/CORE.md) and [`spec/GAME.md`](../../spec/GAME.md). `python tools/check.py rust`
passes T1–T9 on macOS ARM64 (M4 Pro). The `testdata/rust/` references were generated once with `--regen`.

```
python impl/rust/build.py dev|release        # -> impl/rust/out/<mode>/unified, from any cwd
python impl/rust/build.py release --target x86_64-apple-darwin   # Rosetta check -> out/release-x86_64-apple-darwin/
cargo test --workspace                        # in impl/rust: layout, protocol and snapshot tests
```

## Toolchain

- rustc / cargo **1.98.1** (pinned by `rust-toolchain.toml` as `1.98`), edition 2024, `aarch64-apple-darwin`.
- Box3D: Apple clang 21.0.0 through `tools/box3d.py` (static `-O2` library, the same in dev and release).
- Crates (pinned in `Cargo.lock`, 12 packages in total): `bytemuck` 1.25.2 (`derive`, through `syn` 3 /
  `bytemuck_derive` 1.12.1) and `xxhash-rust` 0.8.19 (`xxh3`). Nothing else: no clap, no serde, no async runtime.
  CLI parsing and JSON output are hand-written (about 150 lines).

## Structure

A Cargo workspace. Only `box3d-sys` contains `unsafe`; every other crate has `unsafe_code = "forbid"`
(workspace lints).

```
build.py                    contract build script (box3d.py --json -> env -> cargo build -> out/<mode>/)
crates/box3d-sys/           Box3D: ffi.rs (raw declarations + const layout asserts), lib.rs (safe World/WorldState
                            wrapper, runtime layout check, tests), build.rs (links the tools/box3d.py library)
crates/simcore/             game-agnostic harness: Input/InputSet, the Simulation + InputSource traits,
                            SnapshotRing (16), sync-test, input log (UNIL v1), traces, JSON, timing stats
crates/game/                survivor-lite: state.rs (the Pod block), world.rs (creation order), systems.rs
                            (systems 1-11), grid.rs, script.rs (scripted inputs), lib.rs (Game: Simulation impl,
                            checksum, portable snapshot)
crates/netcode/             transport.rs (Transport trait + Endpoint: connections + reliable lane), loopback.rs,
                            udp.rs, netsim.rs, proto.rs (messages), relay.rs, client.rs; generic over Simulation
crates/unified/             the CLI: offline.rs (sim/synctest/replay/snapshot/resume/bench), net.rs
                            (session/relay/client)
```

`netcode` doesn't depend on `game`: the client is generic over `simcore::Simulation`, and the relay never sees the
game.

## Pointer-freedom and the state block

`game::state::State` is one `#[repr(C)]` struct deriving `bytemuck::Pod` (65,120 bytes). The derive rejects at
compile time any field that isn't plain data (references, `Box`, `Vec`, raw pointers) **and any padding**, so
`bytes_of(&state)` is canonical. The checksum hashes those bytes directly (every target is little-endian, and
`simcore` has a `compile_error!` on big-endian). Then come the live bodies in entity order (items, then players):
position, rotation, linear and angular velocity, with `-0.0 → +0.0`. A `const` assert pins the alignment to 4 and
the size to a multiple of 4.

- Tables (enemies 1200, projectiles 512, gems 1024) are SoA arrays with free lists. Indices are stable (removal never
  reorders) and each slot has a generation (`Handle`).
- Physics bodies are stored as `BodyRef { index1, generation, live }`: the Box3D id **without the world index**. It's
  the same in every client's world and in another process. The wrapper adds the world index back on use.
- Snapshot = `*slot.block = *state` (a memcpy) + `b3World_SaveState`. Restore is the reverse.
- The portable format is `UNIS` | version | block length | physics length | block | Box3D image | XXH3. Box3D's
  image is the fork's pointer-free serialization, and its layout hash rejects a mismatched build.

## Box3D bindings

Hand-written `extern "C"` for the subset used: 28 functions (19 core + 9 fork save/restore) and 26 `#[repr(C)]`
structs. `ffi.rs` is 348 lines, the safe wrapper `lib.rs` is 272 lines including tests, and `build.rs` is 59 lines.
I chose this over bindgen:

- bindgen needs libclang at build time on every CI runner (an LLVM install on Windows) and pulls `bindgen`,
  `clang-sys` and more into every clean build, to generate ~8k lines of API we don't call.
- Hand-written declarations can use safer shapes, e.g. C enums as `c_int` constants.

Layout safety comes from three checks:

1. `const` asserts on the size, alignment and key offsets of every struct. No struct contains `long`, so the LP64
   and LLP64 layouts agree.
2. `verify_layout()` runs once per process. `b3MakeBoxHull` reports C's own `sizeof`/`offsetof`, which are compared
   with Rust's, and the `b3Default*Def` cookies must match.
3. A saved `b3WorldState` read through our image view must agree with `GetData`/`GetSize`.

`build.rs` links `libbox3d.a` / `box3d.lib` from `BOX3D_LIB_DIR`, which `build.py` sets. Without it (plain
`cargo test`), it runs `tools/box3d.py --json` itself.

**Workaround (fork API gap):** the fork can export a state's bytes but has no call to load bytes back into a
`b3WorldState`, and a portable snapshot (late join, `resume`) needs one. `World::restore_bytes` passes
`b3World_RestoreState` a stand-in struct with `b3RecBuffer`'s layout (`data, capacity, size, countOnly`), which is
all that `RestoreState` reads. Check 3 above verifies the layout at runtime. Restored hull geometry is referenced by
registry index, so before restoring, the receiving world (built the same way) is primed with one `SaveState`.
**Suggested fork fix:** add `b3WorldState_SetData(state, bytes, size)`.

## Threads, sockets, timing

- **Threads:** `std::thread` only. `session` runs the relay and each client on their own threads (the late joiner
  too). Each client thread builds its own Box3D world. `b3CreateWorld`/`b3DestroyWorld` edit Box3D's global world
  array, so they're behind a `static Mutex`; stepping different worlds concurrently is fine. Each Box3D world has 1
  worker.
- **Loops:** the relay and client loops poll the transport, do their work, then `thread::sleep(1 ms)` when idle. The
  client skips the sleep while it's catching up.
- **Time:** `Instant` everywhere: mach time on macOS, QPC on Windows, `CLOCK_MONOTONIC` on Linux.
- **Relay clock:** the relay tick is `elapsed / 16.667 ms` from the moment all initial players are connected.
- **Client clock:** the client estimates the relay tick as relay time stamp + RTT/2 (smoothed offset). It schedules
  its own ticks with a period of 16.667 ms ×1.02 or ×0.98 to keep `L ≈ relay tick + delay`. If it's more than 3 ticks
  behind it runs ticks back to back (a joiner's fast-forward); if it's more than 3 ticks ahead it holds.
- **Transports:** `Datagram` sockets (std mpsc channels for loopback; a non-blocking `std::net::UdpSocket`) sit under
  one `Endpoint` that provides the `Transport` interface:
  - `send(peer, bytes, Unreliable|Reliable)`, `poll() -> Connected/Disconnected/Message`
  - a minimal reliable ordered lane: u32 sequence numbers, cumulative ack + 32-bit ack field, RTO from smoothed RTT,
    a 128-message window
- **Netsim:** `NetSim<D>` wraps the *datagram* socket. That puts it under the reliable lane, so snapshots and checksums
  survive simulated loss. It applies the profile's seeded loss, duplication, jitter and reordering to both directions
  of a client.

## Netcode notes and spec interpretations

- **The relay finalizes early.** A tick is finalized as soon as every active player's input for it is in, even if
  the tick is ahead of the relay clock. Otherwise it's finalized at clock ≥ T + 6.
- **The client never simulates past its own predicted tick L.** When finalized inputs exist for the next tick, the
  scheduler uses them directly; it doesn't jump ahead. This keeps L on time sync and keeps own inputs flowing. Under
  `ideal`, every tick is already final when it is simulated (0 rollbacks).
- **Rollback restores the last correctly predicted tick, not V.** The client restores `M-1`, where M is the first
  mispredicted tick (`M-1 ≥ V`, so the state is identical). It skips the restore entirely if every prediction
  matched.
- **Replacing a missing input:** the relay uses the player's last finalized input with the absent bit cleared, so a
  joiner's first missing input becomes neutral rather than "absent".
- **Initial players:** the input log header's player count is the session's slot count. Replay derives the initial
  player set from tick 1's present inputs, which is what makes a late-join log replayable.
- **Late join:** the relay assigns `J = max(requested, relay tick + 10)` and asks the lowest-index active client for
  its verified snapshot once `V ≥ J-1`. Chunks of 1100 bytes travel reliably via the relay, and frames resume from
  V + 1. In `session`, the joiner thread connects about 90 ticks before the requested tick (test harness only).
- **Players are excluded from gameplay rays** by collision category. A projectile spawns at its shooter's position,
  and Box3D reports a ray starting inside a capsule as a hit at fraction 0, so a literal "anything dynamic" would kill
  every projectile on its first tick.
- **Spec inconsistency: barrels.** GAME.md says "24 crates and 16 barrels" but also "barrels are the items where
  `i % 5 == 2`", which gives **8 barrels and 32 crates**. I followed the rule (`N_BARRELS` is computed from it).
- Other choices where the spec leaves room:
  - The spawn jitter is one draw added to both x and z (draw order k, jitter, kind).
  - The dash bit is set only on the redraw tick.
  - The climb ray is cast from y = 3 straight down by 3 m.
  - Explosion and gem distances are horizontal (XZ).
  - Cooldowns decrement before they're tested.
  - Level-up XP carries over (`xp -= threshold`).
  - Enemies hit by an earlier projectile in the same tick (HP ≤ 0) are skipped by later projectiles.

## Lines of code

Non-blank, non-comment lines:

| Part | Crate | Lines |
|---|---|---|
| Core harness | `simcore` | 360 |
| Netcode | `netcode` | 1,407 (client 400, relay 310, transport 241, proto 170, netsim 122, rest 164) |
| Game | `game` | 1,199 (systems 528, lib 224, state 167, world 87, rest 193) |
| Bindings | `box3d-sys` | 679 (ffi 348, safe wrapper + tests 272, build.rs 59) |
| CLI | `unified` | 535 |
| Build script | `build.py` | 75 |

## Build times (M4 Pro, `python build.py <mode>`, wall clock including the box3d.py up-to-date check)

| | dev | release |
|---|---|---|
| Fresh (empty `target/`, registry already fetched) | 5.8 s | 4.3 s |
| Edit one constant in `game` (relink) | 0.5 s | 1.2 s |
| Edit `netcode` | 0.4 s | 1.4 s |

Profiles:
- **dev:** our crates at `opt-level=1` with incremental compilation and overflow checks; dependencies at
  `opt-level=3`; `debug = "line-tables-only"`. It's fast enough to run every test: dev T9 is 0.92 ms, and the dev
  T5/T6 sessions pass.
- **release:** `opt-level=3`, `codegen-units=4`, no LTO.

Most of a fresh build is `syn` for the bytemuck derive. Box3D itself is prebuilt by `tools/box3d.py`.

## T9 (`bench --enemies 1000 --window 8 --ticks 600`, release)

| | mean µs | p99 µs |
|---|---|---|
| forward step | 94 | 146 |
| save (block memcpy + `b3World_SaveState`) | 8 | 16 |
| restore | 11 | 21 |
| 8-tick re-sim (8 × (step + save)) | 727 | 1089 |
| **step + re-sim** | **821 (0.82 ms, target ≤ 6 ms)** | |

The snapshot is 134,689 bytes: 65,120 for the block and 69,569 for the Box3D image. On x86_64 under Rosetta, step +
re-sim is 0.99 ms.

## Determinism checks beyond check.py

- **Rosetta (x86_64-apple-darwin, macos-x64 Box3D):** T1, T2, T7 and T8 pass. The final checksums equal the ARM64
  ones (`38c8f5e6ef29a2ce` for T2, `25e54e617fec30d1` for the reference).
- **Mixed architectures over UDP:** an ARM64 relay, one ARM64 client and two x86_64 clients (one on `wan`) played
  1200 ticks with 0 desyncs and identical checksums. Both architectures replay the relay log to the same trace.
- **Synctest:** its final checksum equals the plain `sim` run's, so saving has no side effects on the world.

## Papercuts and platform risks

- **Windows UDP:** `recv_from` reports an ICMP "port unreachable" from an earlier send as `WSAECONNRESET`. `udp.rs`
  skips `ConnectionReset`/`ConnectionRefused` and keeps reading. (The alternative is the `SIO_UDP_CONNRESET` ioctl,
  which would need `unsafe` + windows-sys.)
- **Windows timers:** the loops rely on `thread::sleep(1 ms)`. Rust's std uses high-resolution waitable timers on
  Windows 10 1803+. On an older or unusual runner, sleeps would round up to ~15.6 ms. Sessions would still work, but
  with coarser scheduling, higher measured RTT and so a larger input delay. Not verified on Windows yet.
- **Windows linking:** `box3d.lib` comes from clang-cl with `/MD`, which matches Rust's MSVC default CRT.
  `BOX3D_DISABLE_AVX2` is defined, so no clang builtins for CPU dispatch are needed. Not verified on Windows yet.
- **Linux:** links `-lm -lpthread` from box3d.json, with rust-lld as the default linker.
- **Cross-OS snapshot (T8 in CI):** the Box3D image is raw struct copies with pointers nulled. It's portable only if
  the struct layouts match, and its layout hash enforces that. I checked that Box3D's internal structs use no
  bitfields and no `long`, where the MSVC and SysV layouts would differ. Rosetta covers x86_64, but not the Windows
  ABI.
- **Real-time sessions:** T3 runs six 60 s sessions in parallel (4–6 threads each). CI runners have about 2× less
  headroom. CPU per client is low (~1 ms per rollback at 1000 enemies), so this shouldn't be a problem.
- **Toolchain:** the pin `channel = "1.98"` made rustup auto-install a `1.98-aarch64-apple-darwin` toolchain locally
  (it already had 1.98.1 as `stable`), and that toolchain has no x86_64 target. So the Rosetta build uses
  `RUSTUP_TOOLCHAIN=stable` (the same rustc 1.98.1).
- **Paths:** `build.py` uses `pathlib` and `sys.executable`, and copies the exe via a temp file + `os.replace`. On
  Windows that fails if `out/<mode>/unified.exe` is still running, e.g. a hung test process.
