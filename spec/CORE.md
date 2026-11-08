# unified core: spec (phase 2)

Goal: prove we can build the `unified` core, a deterministic simulation plus relay-stamped rollback netcode, that is
bit-identical across platforms. It was built headless (no Godot) in C++, Odin and Rust; Odin was chosen (comparison:
`docs/archive/`). The code is `src/` and the harness `tools/check.py`. This spec stays the contract for that code and
for T1–T9 until the module specs replace it.

The implementation must be deterministic across *platforms* (macOS ARM64 locally, Linux x64 and Windows x64 in CI)
and across runs, rollbacks, processes and network conditions. The test game is in `spec/GAME.md`. Layout and
commands: `README.md`.

## 1. Simulation harness

- **Fixed tick:** 60 Hz, `DT = 0.016666668f` (bits `0x3C888889`). f32 only, no FMA contraction
  (`-ffp-contract=off`, or `/fp:precise` with clang-cl's `/clang:-ffp-contract=off`), no transcendentals except the
  deterministic ones we write ourselves (only `+ − × ÷ sqrt` from hardware). Single-threaded sim. Box3D with 1 worker.
- **State block:** one pointer-free block (fixed-capacity tables, generational entity handles, globals, RNG). It's
  checked by the language's idiomatic mechanism (for Odin, a type-info assert). Physics bodies are
  referenced by stored Box3D ids. The Box3D world is the only state outside the block.
- **Snapshot:** `memcpy(block)` plus `b3World_SaveState` (the fork). Restore = `memcpy` back plus
  `b3World_RestoreState`. There's a ring of 16 snapshots.
- **Tick:** `tick(state, physics, inputs[4])` runs the game systems in a fixed order (`GAME.md`) and steps physics
  once with 4 substeps.
- **Checksum:** XXH3-64 (seed 0) over a canonical little-endian serialization of the whole state block (field order
  is the language's own, but fixed), then every alive physics body in entity order (position, rotation, linear and
  angular velocity; −0.0 → +0.0). It's computed every verified tick in tests.
- **Input:** per player per tick, 4 bytes: `move_x i8, move_z i8, buttons u8, choice u8` (`GAME.md`). An absent or
  disconnected player has all zeros and the "absent" flag.
- **Input log (replay file):** a binary format, versioned, little-endian. Header: magic `UNIL`, version u16,
  seed u64, player count u8, tick count u32. Then per tick `[4 × input]` plus a per-player "replaced by relay" bitmask
  (u8). Replaying a log must reproduce the exact checksums of the session that recorded it.
- **Sync-test:** every tick, save; once W ticks exist, restore W ticks back, re-simulate W ticks with the recorded
  inputs, and compare each tick's checksum to the forward one. Mismatches are fatal.

## 2. Netcode (input relay)

- **Relay:** owns the tick clock (60 Hz, monotonic time). It collects inputs that clients send stamped with their
  target tick, and **finalizes tick T** when all connected players' inputs for T have arrived or the hard tolerance
  has expired (relay clock ≥ T + `tolerance`, default 6 ticks). A missing input is replaced by that player's last
  finalized input with the "replaced" flag. The relay broadcasts finalized input sets over the unreliable channel,
  resending every unacknowledged tick in each packet (bounded to 32), and keeps the full input log. It has no game
  logic and runs on its own thread inside the host's process, or standalone (`unified relay`).
- **Client:**
  - **Verified frame:** advanced only with finalized inputs.
  - **Predicted frame:** the verified frame plus the local player's own inputs plus predicted remote inputs (the last
    finalized input repeated).
  - **On new finalized inputs:** restore the verified snapshot, advance it with the finalized ticks, then re-predict to
    the current tick. Skip the restore if every prediction was right.
  - **Prediction cap:** at most 10 ticks ahead of verified; past that the client stalls its *simulation* (no new
    predicted ticks). It keeps sampling and sending inputs on the synced clock. Otherwise a capped client's inputs
    arrive after the relay's tolerance, all get replaced, and it stays capped (found in the C++ implementation, phase 2).
- **Input delay:** the client sends its input for `local_tick + delay`.
  `delay = clamp(ceil((rtt_ms / 2 + 8) / 16.667), 1, 6)` ticks. It's re-evaluated every second, with changes limited
  to ±1 per second. Delay changes must not create gaps: when the delay grows, repeat the last input for the skipped
  tick; when it shrinks, the relay keeps the first input it got for a tick.
- **Time sync:** the client estimates the relay's tick from timestamps in relay packets and RTT. It runs its tick
  scheduler 2% faster or slower to keep its local tick ≈ relay tick + `delay`. This affects only scheduling, never the
  sim.
- **Late join and reconnect:**
  - The joiner connects; the relay assigns a player slot that is first active at a future tick J. The relay sends J.
  - Any connected client that has verified tick V ≥ J − 1 sends its verified snapshot for V to the joiner over the
    reliable channel, chunked: block plus physics snapshot.
  - The relay sends finalized inputs from V + 1.
  - The joiner restores and fast-forwards. **A snapshot must restore on a different machine or OS:** the format is
    portable bytes, not memory dumps with pointers.
- **Desync detection:** every 16 verified ticks, clients send `(tick, checksum)`. The relay compares them, and on a
  mismatch logs the tick and the differing players. Tests treat any mismatch as a failure.
- **Transport interface:** `send(peer, bytes, unreliable|reliable)`, `poll() → [(peer, bytes)]`, connect and
  disconnect events. Implementations:
  - `loopback`: in-process
  - `udp`: localhost or LAN, with a minimal reliable channel (sequence numbers, ack bitfield, resend)
  - `netsim`: a wrapper around either one, with latency, jitter, loss, duplication and reordering from a seeded RNG,
    so test runs are reproducible
- **Wire format:** our own; cross-language interop isn't required. It's little-endian with explicit sizes,
  and inputs are bit-packed (2 × i8 + u8 + u8 per tick).

## 3. CLI (`tools/check.py` relies on it)

All modes print a final JSON line on stdout. Non-zero exit = failure.

- `unified sim --ticks N [--seed S] [--players P] [--trace F] [--log F]`: offline run with scripted inputs (`GAME.md`
  §input script); per-tick `"%06d %016x"` trace; `--log` writes the run's inputs as an input log (nothing replaced).
- `unified synctest --ticks N --window W [--seed S] [--players P]`: JSON includes `mismatches`.
- `unified replay --log F --trace F`: replays an input log.
- `unified session --clients N --transport loopback|udp --profile ideal|wan|bad --ticks N [--late-join P@T]
  [--log F] [--seed S]`: an in-process relay plus N clients (threads) with scripted inputs. Writes the relay's official
  input log. JSON includes, per client, the verified checksums for every 16th tick, `desyncs`, rollback count and
  average/max rollback depth, stall ticks, and final ticks.
- `unified relay --port P --players N --ticks T --log F` and
  `unified client --connect HOST:PORT --player I --ticks T [--profile ...]`: separate processes over UDP, for the
  multi-process test.
- `unified snapshot --ticks T --out F [--seed S] [--players P]`: run offline to tick T and write a portable snapshot.
  `unified resume --in F --ticks N --trace F`: restore from that snapshot and continue, tracing.
- `unified bench --enemies E --window W --ticks N`: JSON with mean/p99 µs for the forward step, save, restore, W-tick
  re-sim, and snapshot bytes.

Conventions `tools/check.py` relies on:
- Defaults: `--seed 1`, `--players 4`. `relay` and `client` have no `--seed` and use the default.
- Ticks are numbered from 1: the state after the k-th step is tick k, and `--ticks N` ends at tick N. A trace has one
  line per tick, 1..N in order (`resume` from a tick-T snapshot traces T+1..T+N). Checksums in traces and JSON are
  lowercase `%016x`.
- JSON fields (extra fields are fine):
  - `synctest`: `mismatches`.
  - `session`: `desyncs` (relay-detected mismatches) and `clients`, a list with one object per client. `client`
    prints that same object as its whole JSON line, and `relay` prints `desyncs`. A client object has `player`,
    `final_tick` (last verified tick, = N on success), `checksums` (`[[tick, "%016x"], ...]` for every verified tick
    divisible by 16; a late joiner starts at its first verified one), `rollbacks`, `rollback_depth_avg`,
    `rollback_depth_max`, `stall_ticks`, and optionally `desyncs`.
  - `bench`: `step_us`, `save_us`, `restore_us`, `resim_us` (the W-tick re-sim), each `{"mean": µs, "p99": µs}`, and
    `snapshot_bytes`.

Network profiles: `ideal` (0 ms); `wan` (50 ms ± 15 ms one way, 2% loss, 1% duplicates, 1% reordering); `bad`
(120 ms ± 40 ms, 8% loss, 3% duplicates, 5% reordering).

## 4. Tests (`tools/check.py`; locally and in CI)

| # | Test | Pass |
|---|---|---|
| T1 | `synctest --ticks 3600 --window 8` with 4 players | 0 mismatches |
| T2 | `sim --ticks 3600` twice | identical traces |
| T3 | `session` with 2 and 4 clients × `ideal`, `wan`, `bad` (loopback + netsim), 3600 ticks | 0 desyncs; all clients' verified checksums equal; all reach 3600; rollbacks > 0 under `wan`/`bad` |
| T4 | `replay` of the T3 `bad` session's log | trace equals that session's verified checksums |
| T5 | UDP: `relay` + 3 `client` processes (one with `--profile bad`), 1800 ticks | 0 desyncs |
| T6 | `session --late-join 3@1200` (4th player joins at tick 1200) under `wan` | 0 desyncs after joining; the joiner's checksums match from its first verified tick |
| T7 | **Cross-platform:** `replay` of `testdata/ref.log` | trace equals `testdata/ref.trace` (generated on macOS ARM64, committed) |
| T8 | **Cross-platform snapshot:** `resume --in testdata/ref-1800.snap --ticks 1800` | trace equals ticks 1801–3600 of `ref.trace` |
| T9 | `bench --enemies 1000 --window 8` | reported (not gated). Target: forward step + 8-tick re-sim ≤ 6 ms. |

CI runs T1–T9 on Linux x64 and Windows x64 and puts the T9 bench in the job summary. macOS is checked locally with
the same `tools/check.py`. The `testdata/` references are regenerated only deliberately (`tools/dev.py check
--regen`, see `testdata/README.md`), which updates the committed files.
