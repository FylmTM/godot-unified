# headless

The headless binary every game builds from `unified:headless` (`src/headless`, wired by
`games/<game>/simulation/headless`), and the end-to-end tests T1-T9 that `tools/check.py` runs against it. The CLI
and the tests are the phase 2 contract (signed off with it); the rest of the old phase 2 spec moved into
`spec/sim.md` and `spec/netcode.md`, which describe the code as it is now. The test game is `spec/GAME.md`.

## CLI (`tools/check.py` relies on it)

The modes come from `unified:headless`; the binary is the game's headless binary (`out/<mode>/survivor`). Below,
`unified <mode>` stands for it. A game may add its own modes (the survivor: `eos-host`, `eos-client`, `spec/eos.md`).
Formats and the sim/netcode behaviour behind the modes: `spec/sim.md`, `spec/netcode.md`.

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

## Tests T1-T9 (`tools/check.py`; locally and in CI)

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
