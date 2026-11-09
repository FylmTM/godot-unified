# headless

The headless binary every game builds from `unified:headless` (`src/headless`, wired by
`games/<game>/simulation/headless`), and the end-to-end tests T1-T9 that `tools/check.py` runs against it. The CLI
and the tests are the phase 2 contract (signed off with it); the rest of the old phase 2 spec moved into
`src/sim/SPEC.md` and `src/netcode/SPEC.md`, which describe the code as it is now. The test game is `games/survivor/SPEC.md`.

## CLI (`tools/check.py` relies on it)

The modes come from `unified:headless`; the binary is the game's headless binary (`out/<mode>/survivor`). Below,
`unified <mode>` stands for it. A game may add its own modes (the survivor: `eos-host`, `eos-client`, `src/eos/SPEC.md`).
Formats and the sim/netcode behaviour behind the modes: `src/sim/SPEC.md`, `src/netcode/SPEC.md`.

All modes print a final JSON line on stdout. Non-zero exit = failure.

- `unified sim --ticks N [--seed S] [--players P] [--trace F] [--log F]`: offline run with scripted inputs (`games/survivor/SPEC.md`
  §input script); per-tick `"%06d %016x"` trace; `--log` writes the run's inputs as an input log (nothing replaced).
- `unified synctest --ticks N --window W [--seed S] [--players P]`: JSON includes `mismatches`.
- `unified replay --log F --trace F`: replays an input log.
- `unified session --clients N --transport loopback|udp --profile ideal|wan|bad --ticks N [--late-join P@T]
  [--log F] [--seed S] [--clock real|virtual]`: an in-process relay plus N clients with scripted inputs (threads on
  the real clock; on the virtual clock, loopback only, one thread steps everything through test time). Writes the
  relay's official input log. JSON includes, per client, the verified checksums for every 16th tick, `desyncs`,
  rollback count and average/max rollback depth, stall ticks, and final ticks.
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
| T3 | `session --clock virtual` with 2 and 4 clients × `ideal`, `wan`, `bad` (loopback + netsim), 3600 ticks | 0 desyncs; all clients' verified checksums equal; all reach 3600; rollbacks > 0 under `wan`/`bad` |
| T4 | `replay` of the T3 `bad` session's log | trace equals that session's verified checksums |
| T5 | UDP: `relay` + 3 `client` processes (one with `--profile bad`), 960 ticks of real time | 0 desyncs |
| T6 | `session --clock virtual --late-join 3@1200` (4th player joins at tick 1200) under `wan` | 0 desyncs after joining; the joiner's checksums match from its first verified tick |
| T7 | **Cross-platform:** `replay` of `games/survivor/simulation/tests/testdata/ref.log` | trace equals `ref.trace` there (generated on macOS ARM64, committed) |
| T8 | **Cross-platform snapshot:** `resume --in ref-1800.snap --ticks 1800` (same folder) | trace equals ticks 1801–3600 of `ref.trace` |
| T9 | `bench --enemies 1000 --window 8` | reported (not gated). Target: forward step + 8-tick re-sim ≤ 6 ms. |

CI runs T1–T9 on Linux x64 and Windows x64 and puts the T9 bench in the job summary. macOS is checked locally with
the same `tools/check.py`. The reference runs (each game's `simulation/tests/testdata/`) are regenerated only deliberately
(`tools/dev.py check --regen`, see the README there), which updates the committed files.

## End-to-end suites (pending sign-off: #60, #61, #67)

**Pending the developer's sign-off; nothing below is built yet.** When it is, it replaces the T1-T9 section above
and `tools/check.py`. Decided in the testing sitting (#4): each game has its own end-to-end suite of Odin tests calling
`unified:headless` in-process; the library provides the standard scenarios as procs and every in-repo game calls each
one explicitly; tests are named for what they check; no platform assumptions.

### Where things are

- **`unified:headless/scenarios`** (`src/headless/scenarios/`): the standard scenarios, one proc each. A test-only
  sub-package (it imports `core:testing`); game binaries never import it. The `headless` lint rule covers it.
- **Each game's suite:** `games/<game>/simulation/tests/suite_test.odin`: one `@(test)` per standard scenario call,
  then the game's own scenarios. Its reference run stays in `simulation/tests/testdata/`.
- **The toy's suite** (#67): `tests/scenarios/`, the scenarios package's own tests, with the toy's reference run in
  `tests/scenarios/testdata/`. It is the template a game's suite copies: the standard part is identical in shape.

### API

```odin
Suite :: struct($S, $I, $W: typeid, $P: int) {
	h:       ^headless.Headless(S, I, W, P),
	players: int, // scripted players in offline runs
	seed:    u64,
	ticks:   u32, // length of offline runs and sessions
	ref:     Reference,
}
Reference :: struct {
	dir:                  string, // #directory + "/testdata"
	ticks, snapshot_tick: u32,    // ref.trace covers 1..ticks; ref-<snapshot_tick>.snap
	seed:                 u64,
	players:              int,
}
```

| Proc | Passes when |
|---|---|
| `rollback_every_tick(t, s, window = 8)` | restoring `window` ticks back and re-simulating, every tick: 0 mismatches |
| `runs_match(t, s)` | two scripted runs: identical traces |
| `session_agrees(t, s, clients, profile)` | virtual-clock session: 0 desyncs, every client's verified checksums equal, all reach `ticks`, rollbacks > 0 unless `ideal` |
| `session_log_replays(t, s, clients, profile)` | its own session; the relay's input log replays offline to every verified checksum |
| `late_join_agrees(t, s, profile, player, tick)` | 0 desyncs; the joiner's checksums match from its first verified tick |
| `reference_replays(t, s)` | replay of `ref.log` equals `ref.trace` |
| `reference_resumes(t, s)` | resume of the snapshot equals the rest of `ref.trace` |

Failures name the scenario's parameters and the first tick that differs. `session_run` returns structured
per-client results (final tick, verified checksums, rollbacks and depth, stall ticks) instead of JSON strings; the
CLI builds its JSON from them. A suite reads as a list of sentences:

```odin
@(test)
rollback_every_tick :: proc(t: ^testing.T) {scenarios.rollback_every_tick(t, &SUITE)}
@(test)
four_clients_agree_on_a_bad_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 4, .Bad)}
```

Every game calls `session_agrees` for 2 and 4 clients under `ideal`, `wan` and `bad`, and every other proc once
(friendslop gains the sessions, the resume and a reference snapshot it lacks today).

### Running

- **One group: every scenario runs in `python tools/dev.py test`**, at full length, in the same compile and parallel
  run as the unit tests. Each scenario is its own test, so the runner spreads them over the cores: the wall time
  grows by the slowest scenario, not by their sum. If the suites push `dev.py test` over its budget, the remedy is a
  shorter scenario in that game's suite, not a second tier. One game alone:
  `odin test games/<game>/simulation/tests -collection:unified=src`.
- **`python tools/dev.py check`** keeps only the real-UDP, real-clock, multi-process test (a relay and 3 client
  processes, one under `bad`): a netcode transport test, at library level, on the toy's headless binary
  (`tests/toy/headless/`, a few lines wiring the toy into `unified:headless`).
- **CI**, on Linux x64 and Windows x64: `dev.py test` (every suite and every reference run: the cross-check), then
  `dev.py check`. The bench leaves with #62; this lands with it or after it, so CI's summary keeps the bench.

### Reference runs (#61)

A reference run is a committed run every platform must reproduce. `python tools/dev.py regen <game>|toy`, on any
machine, runs that suite's reference tests with `-define:UNIFIED_REGEN=true`: `reference_replays` then writes
`ref.log`, `ref.trace` and the snapshot through `run_sim` and `run_snapshot`, checks them (replay, resume), and writes
`ref.json` (where it was made: OS, architecture, Odin version, build flags, commit; when; the parameters). Nothing
else in the tools, suites or docs names a platform: no Rosetta step, no `--arch` (`dev.py build`, `game build`,
`box3d.py`). Known consequence: cross-architecture is proven only while the dev machine and CI differ in CPU.
