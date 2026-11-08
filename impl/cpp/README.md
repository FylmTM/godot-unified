# unified core: C++

The phase-2 core (spec/CORE.md, spec/GAME.md) in orthodox C++20. It covers the deterministic survivor-lite
sim on Box3D, snapshots and the snapshot ring, checksums, sync-test, replays, portable snapshots, and a
Quantum-style relay with prediction/rollback clients over loopback, UDP and a network simulator.

```
python impl/cpp/build.py dev|release     # -> impl/cpp/out/<mode>/unified[.exe]   (any cwd; no shell)
python impl/cpp/build.py asan|tsan       # ASan+UBSan / TSan builds (local)
python impl/cpp/build.py release-x64     # macOS only: x86_64 binary against the macos-x64 Box3D (Rosetta)
python tools/check.py cpp                # T1-T9
```

## Status (macOS ARM64, M4 Pro, 2026-11-08)

| | Result |
|---|---|
| `tools/check.py cpp` (release) | **T1-T9 pass**; references generated with `--regen` (testdata/cpp/, final checksum `c1d233d922384beb`) |
| `tools/check.py cpp --build-mode dev` | T1-T9 pass (bounds checks and libc++ hardening on) |
| x86_64 under Rosetta (`release-x64`, via `check.py --impl-dir ... --no-build`) | T1, T2, T7, T8, T9 pass: the trace equals ARM64's, and the ARM64 snapshot restores on x86_64 |
| Cross-arch extras | An x86_64-made snapshot resumes on ARM64 with the identical trace. A mixed UDP session (ARM64 relay and 2 clients, plus an x86_64 client on `bad`) has 0 desyncs, and its log replays to the x86_64 client's checksums |
| ASan+UBSan | Clean: synctest, sim, snapshot/resume, bench, and a 4-client `bad` loopback session with a late join |
| TSan | Clean: a 4-client `wan` UDP session with a late join (relay and client threads) |
| Negative control | Skipping the physics restore in sync-test gives 4744/4744 mismatches |

Linux x64 and Windows x64 are compiled and checked only in CI. The platform code there is written but hasn't been
run (see the risks below).

## Toolchain

- Apple clang 21.0.0 (clang-2100.3.34.2), CMake 4.4.5, Ninja 1.13.2, Python 3.9.6, macOS 26.7.1.
- One compiler family: clang/clang++ on macOS and Linux, clang-cl on Windows (found by `tools/common.py`; the MSVC
  environment is loaded via vswhere when the shell isn't a developer prompt). The CRT is `/MD`, matching Box3D.
- Flags on every target of ours:
  - Determinism: `-ffp-contract=off -fwrapv -fno-math-errno -fno-fast-math`. On clang-cl the same flags go through
    `/clang:`.
  - Warnings: `-Wall -Wextra -Wshadow -Werror` (`/W4 /WX` on clang-cl).
  - `-fno-exceptions -fno-rtti` on macOS/Linux. On Windows it's `/GR-` but `/EHsc` is kept, because the MSVC STL
    headers expect it. Our code never throws.
- Modes:
  - `release`: `-O2`.
  - `dev`: `-O1 -g` with `UNI_CHECKS=1`, which turns on bounds-checked `uni::Array` and dev asserts, plus
    `_LIBCPP_HARDENING_MODE_EXTENSIVE` (macOS) or `_GLIBCXX_ASSERTIONS` (Linux).
  - `asan`: `-fsanitize=address,undefined -fno-sanitize-recover=undefined`.
  - `tsan`: `-fsanitize=thread`.
  - Box3D is always the `-O2` library from `tools/box3d.py`. Dev and release traces are identical.
- Vendored: `third_party/xxhash/xxhash.h` (v0.8.3, BSD-2, copied from bench/a). Nothing else is downloaded.

## Structure

```
build.py, CMakeLists.txt     build.py runs tools/box3d.py --json, then CMake+Ninja; one static lib per module
src/core/     base.h (types, UNI_CHECK/UNI_ASSERT, bounds-checked Array), pod_check.h, bytes.h (LE reader/writer),
              hash (XXH3 wrapper), input.h, input_log (UNIL format), json, platform{,_posix,_win}.cpp
src/physics/  physics.{h,cpp} (the Box3D binding: the only place box3d.h is included),
              world_state_ext.cpp (load-image-from-bytes workaround, see papercuts)
src/game/     state.h (the state block), tables.h, pool.h (stable-index free lists), world.cpp (setup, checksum),
              systems.cpp (GAME.md systems 1-11), script.cpp (scripted inputs)
src/sim/      sim.{h,cpp}: Sim (block + world + scratch), Snapshot, the 16-slot Ring, the portable snapshot format
src/net/      socket.h + socket_{posix,win}.cpp (UDP), loopback, netsim, transport.h (the interface),
              host (connections + reliable channel), protocol (messages), relay, client, session (in-process)
src/cli/      main, args, offline.cpp (sim/synctest/replay/snapshot/resume/bench), net_commands.cpp
```

Modules depend downwards: cli → net → sim → game → physics → core. Everything platform-specific is in
`core/platform_*.cpp` and `net/socket_*.cpp`, which CMake selects by OS.

## Pointer-freedom and the state block

`game::State` is one 66 KB aggregate:
- globals: seed, tick, RNG, spawn cap, stats
- `Array<Player,4>`, `Array<Item,40>` (crates and barrels)
- `Array<Enemy,1200>`, `Array<Projectile,512>`, `Array<Gem,1024>`, each with a `SlotPool` free list

Box3D bodies are stored as `phys::BodyRef {index1, generation}`. The world slot is deliberately left out, because it
differs between the clients of one process. Three compile-time checks guard it:

1. **`static_assert(uni::pod::is_portable_pod<State>())`** (`core/pod_check.h`, ~100 lines). This is a Boost.PFR-style
   aggregate reflection: count the fields by brace-initialising with "convertible to anything", recover the field
   types with structured bindings, and recurse. Every field must be arithmetic, an enum, a `uni::Array` of passing
   types, or a nested aggregate of passing types. Pointers, references, raw C arrays and non-aggregates fail to
   compile. It also requires trivially-copyable and standard-layout.
2. **`#pragma clang diagnostic error "-Wpadded"`** around the state structs. There is no implicit padding, so the
   block's bytes are fully determined by its fields.
3. **Size asserts** plus a constexpr layout hash, which is stored in portable snapshots.

Because the block is padding-free and little-endian (asserted), **its raw bytes are the canonical serialization**:
- The checksum is XXH3-64 over the block, then over the 13 floats of every alive body in entity order (players,
  then items, with −0 → +0).
- A portable snapshot is `"UNIS", version, layout hash, block bytes, Box3D image`.
- Restore is `memcpy` plus `b3World_RestoreState`.

## Box3D binding

Box3D's C header is used directly from C++, so there's no binding layer to generate. `physics/` is a thin
handle-based wrapper (~230 code lines) that keeps `box3d.h` out of the rest of the code. It covers:
- bodies (static box, dynamic box, capsule)
- velocity and impulse
- body state for the checksum
- `CastRayClosest`, which classifies hits by shape filter category, because categories survive snapshots and
  userData doesn't
- step
- the fork's save/restore

Snapshot images go through `phys::Snapshot`, an RAII `b3WorldState`. Two process-level details:
- The geometry registry (`b3WorldStateCache`) is **primed right after world setup**, so hull blobs get the same
  registry ids in every process. That's what lets a saved image restore in a fresh process or on another OS.
- `b3CreateWorld`/`b3DestroyWorld` go through a mutex, because they scan Box3D's global world table and session
  clients create worlds on their own threads.

## Threads, sockets, timing

**Transport stack** (`net/`):
- `DatagramSocket`, with three implementations: UDP, the in-process `LoopbackHub`, and `NetSimSocket`. The netsim
  is a decorator with a seeded splitmix RNG. It applies one-way latency ± jitter (FIFO), loss, duplication and
  reordering (held back 5–40 ms) in both directions on the client side. It sits **under** the reliability layer, so
  reliable traffic sees real loss.
- `Host` implements the spec's `Transport` interface (`send(peer, bytes, unreliable|reliable)`, `poll()` → connect,
  disconnect and message events). It adds:
  - connection handshake (token)
  - 8 s timeout
  - a reliable ordered channel: u32 sequence numbers, cumulative ack plus a 32-bit ack bitfield, Karn-sampled RTO,
    a 256-fragment window, and automatic fragmentation, so a 134 KB snapshot is just one `send`

**Relay** (one thread, or the `relay` process):
- Polls about every 0.5 ms. Its 60 Hz clock runs from `steady_clock`.
- Finalizes tick T when every required player's input is in, or when its clock reaches T + 6. A missing input repeats
  the last finalized one with the replaced bit.
- Sends each client its unacked finalized ticks (≤ 32 per packet) on every new finalization and at least once per
  tick.
- Keeps the log, compares `(tick, checksum)` every 16 verified ticks, and brokers late joins:
  - J = max(relay tick, last finalized) + 20.
  - It asks a connected client for a verified snapshot of a tick ≥ J − 1, forwards it reliably to the joiner, then
    streams finals from that tick + 1.
  - A joiner counts toward early finalization only after its first accepted input.

**Client** (one thread per client in `session`):
- Timing:
  - The relay tick is estimated as the max of recent `relay_time − recv_time` samples plus min RTT / 2.
  - RTT comes from echoed timestamps and is seeded by the connect handshake.
  - `delay = clamp(ceil((rtt/2 + 8)/16.667), 1, 6)`, re-evaluated every second, ±1 per step.
  - The tick clock is slewed by ±2% towards relay tick + delay. It jumps only when it's more than 8 ticks off (at
    start, or for a joiner).
- Prediction and rollback:
  - Remote inputs are predicted as the last finalized input repeated. The ring holds 16 snapshots and the
    prediction cap is 10.
  - On new finals it compares the inputs it used against the finalized ones. If they match, it skips the restore.
    Otherwise it restores the ring slot before the first wrong tick and re-simulates to the present.
- A joiner restores the portable snapshot and fast-forwards on finalized inputs only. It starts sending inputs once
  it's within 2 ticks of its clock.

**Time and sleep**:
- `std::chrono::steady_clock` and `std::this_thread::sleep_for`, wrapped in `core/platform.h`. On Windows,
  `timeBeginPeriod(1)` makes sleep granularity about 1 ms.
- Sessions run in real time: 3600 ticks take 60 s, and a whole 4-client session uses about 1–2 s of CPU.

## Interpretation choices (GAME.md leaves these open)

- **Timing:**
  - `t` in "at tick t" is the number of completed ticks before the step, so the first spawn batch is at t = 0.
  - Countdowns (dash, fire, contact, respawn) decrement before they're tested.
  - The dash is a velocity ×3 for 8 ticks.
- **Physics setup:**
  - Walls are boxes centred at ±30.5 with half extents (0.5, 1.5, 31).
  - Gravity is Box3D's default.
  - Player capsules have density 1.
  - The enemy climb ray goes from y = 3 down 3 m. It counts as climbing if the closest hit is a crate or barrel above
    y 0.8.
- **Distances and targeting:**
  - All gameplay distances are horizontal (XZ), including the explosion radius and falloff.
  - The explosion direction is the normalized XZ offset plus 0.5 up, normalized again.
  - Contact damage hits the lowest-index player in range.
- **Projectiles:**
  - A projectile flies at the shooter's body height.
  - It first hits the lowest-index enemy in the 3×3 cells (enemies already at HP ≤ 0 are skipped), else the ray
    against the world.
  - The grid is rebuilt after enemy movement for that test.
- **XP:** the level-up threshold is subtracted from XP.
- **Joining and leaving:** a player slot activates on its first non-absent input and is removed on an absent input.
  So joins, leaves and the initial player count all flow through the official input log, and `replay` needs nothing
  else. The log header's `players` is the number of slots active at tick 0.

## Lines of code (non-blank, non-comment / raw)

| Module | Files | Code | Raw |
|---|---|---|---|
| core (core/ + sim/) | 16 | 699 | 919 |
| netcode (net/) | 19 | 2011 | 2371 |
| game (game/) | 7 | 885 | 1054 |
| bindings (physics/) | 3 | 227 | 316 |
| cli (cli/) | 6 | 578 | 670 |
| **total** | 51 | **4400** | **5330** |

Build scripts: build.py 116 lines, CMakeLists.txt 147.

## Build times (M4 Pro, Box3D already built by tools/box3d.py)

| | release | dev |
|---|---|---|
| Fresh (configure + 23 TUs) | 2.1 s | 2.0 s |
| One-line edit in game/systems.cpp | 0.41 s | 0.42 s |
| One-line edit in net/client.cpp | 0.77 s | |
| Touch game/state.h (the block header) | 0.90 s | |
| No-op | 0.11 s | |

## T9: `bench --enemies 1000 --window 8 --ticks 600` (release)

| | mean µs | p99 µs |
|---|---|---|
| Forward step | 150 | 398 |
| Save (block memcpy + Box3D save) | 8 | 15 |
| Restore | 11 | 20 |
| 8-tick re-sim | 1013 | 3193 |
| **Step + 8-tick re-sim** | **≈ 1.16 ms** (target ≤ 6 ms) | |
| Snapshot | 134,349 bytes (65,928 block + about 68 KB Box3D image) | |

Under Rosetta (x86_64), step + re-sim is 1.45 ms. Enemies are kinematic state, not bodies, so the physics image
stays small (13 statics, 40 props, 4 players).

## Papercuts and findings

- **The fork can't load an image from bytes.** `b3WorldState` has `GetData`/`GetSize` but no setter, and portable
  snapshots (late join, `resume`) need one. `physics/world_state_ext.cpp` mirrors the private `b3RecBuffer` layout
  and allocates with Box3D's own `b3Alloc`/`b3Free`. It verifies the mirror against the public getters on every
  use. A two-line `b3WorldState_SetData` in `third_party/box3d.patch` would remove it, and Odin and Rust will hit
  the same gap.
- **Box3D images aren't byte-reproducible.** Every serialized `b3Contact` (216 B, plus a 4 B count) carries about 8
  stale pointer bytes that change with ASLR. Restore ignores them: resumes and late joins reproduce exactly. But
  two snapshot files of the same state differ, so compare traces, not `.snap` bytes.
- **A trap in the netcode spec under `bad`.** "Send input for local_tick + delay" plus "past the cap the client
  stalls" makes a feedback loop:
  1. A capped client generates its inputs late.
  2. They reach the relay after the tolerance, so the relay finalizes on its timer.
  3. Finals arrive later, so the client stays capped.

  With RTT ≈ 15 ticks against cap + delay = 16, `bad` never escapes it: 100% of inputs were replaced. The fix here
  is that input sampling follows the time-synced clock, while only the predicted simulation is frozen by the cap.
  With it, `bad` drops to about 3–5% replaced inputs. Even so, `bad` needs about 2·OWL − delay ≈ 9–13 ticks of
  prediction, so it sits at the cap most of the time. Expect large `stall_ticks` there (about 1000 per 1200 ticks).
  `wan` has 0 stalls and 0 replacements.
- **The spec's game balance.** With these rules the 1200-enemy cap is reached before tick 3600 ("several hundred
  alive" isn't reachable: 2070 spawns against a kill rate of at most about 6/s). Players are swarmed and spend much
  of the time dead. That churns player bodies, which is good for rollback coverage. Barrels rarely take 6 hits,
  though: 1 explosion across seeds 1–40 × 3600 ticks, and none in the test seeds 42 and 7. So T1 doesn't exercise
  explosions. I checked them separately with seed 9: synctest at windows 3, 8 and 15, 6000 ticks, 0 mismatches.
- **Windows sockets:** `recvfrom` reports an ICMP port-unreachable as `WSAECONNRESET` on later calls. It's disabled
  with `SIO_UDP_CONNRESET` and also skipped. Also `closesocket`, `ioctlsocket(FIONBIO)` and `WSAStartup` in
  `platform::init`.
- **Windows timers:** the default sleep granularity is 15.6 ms, so there's `timeBeginPeriod(1)`. `steady_clock` is
  QPC.
- **Windows paths and stdout:** UTF-8 paths are converted to UTF-16 for `_wfopen`, and stdout is set to binary so the
  JSON line ends in LF.
- **Windows build:** clang-cl needs `NOMINMAX`/`WIN32_LEAN_AND_MEAN`, and `winsock2.h` has to come before
  `windows.h`. CMake's default `/O2 /Ob2 /DNDEBUG /GR` per-config flags are replaced, so the mode alone decides
  optimization.
- **Linux:** `-pthread` and `-lm` come from `box3d.json` `link_libs` and `Threads::Threads`.
- **Box3D's global world table** isn't thread-safe for create/destroy, hence the mutex. TSan can't see inside the
  uninstrumented Box3D, so only our side is verified.

## CI risks (untested here)

- `socket_win.cpp`, `platform_win.cpp` and the clang-cl flag set have never been compiled. A `/W4 /WX` warning from
  a newer clang-cl, or from Linux's clang 18 with `-Werror`, would fail the build. Those are the most likely
  failures, and they're easy to fix.
- T8 on Windows depends on Box3D's raw struct images having the same layout under LLP64. The image's own layout hash
  would reject a mismatch (restore fails instead of silently diverging). Nothing in the serialized structs uses
  `long`.
- Sessions run in real time. On 2–4 vCPU runners T3 runs only 1–2 sessions in parallel (about 3 minutes), well inside
  the timeouts. Scheduler jitter on a loaded Windows runner shows up as more rollbacks or stalls, not as failures.
