# headless

Status: draft (no sitting signed it off as a whole); its end-to-end suites signed off 2026-11-09 (#4).

The headless binary every game builds from `unified:headless/modes` (`src/headless/modes`, wired by
`games/<game>/simulation/headless`; the toy game's by `tests/toy/headless`) on top of the in-memory runs of
`unified:headless` (`src/headless`), and the end-to-end suites: each game's Odin tests built on the standard
scenarios of `unified:headless/scenarios`. The CLI is the phase 2 contract (signed off with it); the rest of the old
phase 2 spec moved into `src/sim/SPEC.md` and `src/netcode/SPEC.md`, which describe the code as it is now.

## CLI

The modes come from `unified:headless/modes` (`modes.run(&GAME, {content, summary, bench, ...}, variants, online)`:
`--game NAME` picks one of the variants, `online` plugs in a lobby transport); the binary is the game's headless binary
(`.out/<mode>/<game>`). The runs are played by the game's scripted player (`sim.Game.scripted_input`,
`scripted_commands`).
`uni headless [game] -- <mode> [options]` builds it when stale and runs it with the mode below (`src/cli/SPEC.md`).
A game may add its own modes (the survivor: `eos-host`, `eos-client`, `src/eos/SPEC.md`).
Formats and the sim/netcode behaviour behind the modes: `src/sim/SPEC.md`, `src/netcode/SPEC.md`.

All modes print a final JSON line on stdout. Non-zero exit = failure.

- `sim --ticks N [--seed S] [--players P] [--trace F] [--log F]`: offline run with scripted inputs (`games/survivor/SPEC.md`
  §input script); per-tick `"%06d %016x"` trace; `--log` writes the run's inputs as an input log (nothing replaced).
- `synctest --ticks N --window W [--seed S] [--players P]`: JSON includes `mismatches`. `W` (here and in
  `bench`) is 1 to `headless.max_window(game)`, the game's ring depth (its tick rate sets it).
- `replay --log F [--snapshot F] --trace F`: replays an input log (refused when another level or build recorded it);
  with `--snapshot` from that portable snapshot's tick, the log holding the ticks after it (an F3 note's recording,
  `src/godot/SPEC.md`).
- `session --clients N --transport loopback|udp --profile ideal|wan|bad --ticks N [--late-join P@T]
  [--log F] [--seed S] [--clock real|virtual]`: an in-process relay plus N clients with scripted inputs (threads on
  the real clock; on the virtual clock, loopback only, one thread steps everything through test time). Writes the
  relay's official input log (its recording, `src/netcode/SPEC.md`). JSON includes, per client, the verified
  checksums for every 16th tick, `desyncs`, rollback count and average/max rollback depth, stall ticks, and final
  ticks. A desync fails it.
- `relay --port P --players N --ticks T --log F` and
  `client --connect HOST:PORT --slot I --ticks T [--profile ...] [--token HEX]`: separate processes over UDP, for the
  multi-process test.
- `snapshot --ticks T --out F [--seed S] [--players P]`: run offline to tick T and write a portable snapshot.
  `resume --in F --ticks N --trace F`: restore from that snapshot and continue, tracing.
- `bench [--entities E --window W --ticks N]`: JSON with mean/p99 µs for the forward step, save, restore,
  W-tick re-sim (`resim_us`), the same re-sim of final ticks saving only the last (`resim_final_us`, a catch-up
  burst), the stepped tick's checksum (`checksum_deep_us` on the ticks peers compare, every 16th; `checksum_us` on
  the others), the portable snapshot's bytes and what each tick's save copies (`save_bytes`, `sim.save_size`); E
  entities held (`Headless.bench_prepare`, the game's own kind: the survivor's
  enemies), `entities_mean` the count it held. Without arguments it runs the game's standard benchmark
  (`Headless.bench`; W defaults to the prediction cap, `headless.prediction_window(game)`).
- `net-bench [--clients N --ticks T --profile P | --latency MS [--jitter MS] [--loss PERMILLE]] [--seed S]`: a
  session on the virtual clock (default: 4 clients, `bad`, 1,200 ticks): JSON with the wall time, each client's
  input delay, rollbacks and their depth, re-simulated, stalled and replaced ticks, the step counts and times by
  kind, the relay's and an average client's bytes per second, the relay's datagrams per second and the resends.
- `table-bench [--live L --walks W]`: a `sim.iterate`/`sim.next` walk of a 65,536-slot table that once held
  every slot and now holds L (1000) items spread across it, against a dense table holding L items: JSON
  `sparse_us` and `dense_us`, each `{"mean": µs, "p99": µs}` (src/sim/SPEC.md "Tables and handles": an alive bitmask
  comes only if this shows the scan matters). Game-independent; `uni bench` runs it once.

Conventions (`uni test --suite net` drives `relay` and `client`, `uni bench` drives `bench`; the suites call the same
procs in-process):
- Defaults: `--seed 1`, `--players 4`. `relay` and `client` have no `--seed` and use the default.
- Ticks are numbered from 1: the state after the k-th step is tick k, and `--ticks N` ends at tick N. A trace has one
  line per tick, 1..N in order (`resume` from a tick-T snapshot traces T+1..T+N). Checksums in traces and JSON are
  lowercase `%016x`.
- JSON fields: every line has `mode`; a timing is `{"mean": µs, "p99": µs}`; `ok` where the mode can fail.
  - `sim`: `ticks`, `seed`, `players`, `final_checksum` (and the game's `summary` fields). `synctest`: `ticks`,
    `window`, `seed`, `players`, `mismatches`, `first_mismatch`, `resimulated_ticks`, `final_checksum`. `replay`:
    `ticks`, `final_checksum`. `snapshot`: `tick`, `bytes`, `checksum`. `resume`: `final_tick`, `final_checksum`.
  - `session`: `clients` (a client object each), `desyncs` (relay-detected mismatches), `replaced_inputs`,
    `profile`, `transport`, `clock`, `ticks`, `relay_net` (the relay's channel stats). `relay`: `desyncs`,
    `replaced_inputs`, `finalized`, `net`. `client` prints a client object as its whole line.
  - A client object (`netcode.client_json`): `slot`, `member`, `final_tick` (last verified tick, = N on success),
    `checksums` (`[[tick, "%016x"], ...]` for every verified tick divisible by 16; a late joiner starts at its first
    verified one), `rollbacks`, `rollback_depth_avg`, `rollback_depth_max`, `stall_ticks`, `resim_ticks`,
    `join_tick`, `delay`, `delay_changes`, `rtt_ms`, `desyncs`, `ok`, `net`, `steps` and `step_us` (by kind:
    `verified`, `resim`, `predicted`).
  - `bench`: `what`, `entities`, `window`, `ticks`, the timings `step_us`, `save_us`, `restore_us`, `resim_us`,
    `resim_final_us`, `checksum_us`, `checksum_deep_us`, then `snapshot_bytes`, `block_bytes`, `save_bytes`,
    `entities_mean`,
    `mismatches`. `net-bench`: `clients`, `profile`, `latency_ms`, `jitter_ms`, `ticks`, `tick_hz`, `wall_ms`,
    `delay` (per client), `rollbacks`, `rollback_depth_avg`, `resim_ticks`, `stall_ticks`, `replaced_inputs`,
    `desyncs`, `steps`, `step_us`, `relay_bytes_per_s`, `client_bytes_per_s`, `relay_datagrams_per_s`, `resends`.
    `table-bench`: `capacity`, `live`, `walks`, `sparse_us`, `dense_us`, `checksum`.
  - `<online>-host`: `code`, `lobby_ready_ms`, `players`, `desyncs`, `finalized`, `net`, `client`.
    `<online>-client`: `join_ms`, `network`, `client`.

Network profiles: `ideal` (0 ms); `wan` (50 ms ± 15 ms one way, 2% loss, 1% duplicates, 1% reordering); `bad`
(120 ms ± 40 ms, 8% loss, 3% duplicates, 5% reordering).

## End-to-end suites

Decided in the testing sitting (#4), signed off 2026-11-09: each game has its own end-to-end suite of Odin tests
calling `unified:headless` in-process; the library provides the standard scenarios as procs and every in-repo game
calls each one explicitly; tests are named for what they check; no platform assumptions.

### Where things are

- **`unified:headless`** (`src/headless/`): a run's description (`Headless`: `game`, whose scripted player plays,
  `content`, and for the binary `summary` and `bench_*`), the in-memory runs
  (`run_sim`, `run_synctest`, `run_interleaved`, `run_replay`, `run_snapshot`, `run_resume`, `Trace`) and `session_run`. The suites use
  only this. In an offline run slot i is member i + 1 from tick 1, joining with its join record (`src/sim/SPEC.md`,
  Players); `run_synctest`'s `seats` (`Seat{tick, slot, member}`, member 0: nobody) change who holds a slot.
  Scripted commands go into offline runs as the relay places them (at most 4 of a slot per tick, the rest in the
  next ticks, in order; a leaver's waiting ones go) and every session client sends them through the netcode; a
  resume starts with none waiting.
- **`unified:headless/modes`** (`src/headless/modes/`): argument parsing, the modes, the file I/O, the bench and the
  online modes; only headless binaries import it.
- **`unified:headless/scenarios`** (`src/headless/scenarios/`): the standard scenarios, one proc each. A test-only
  sub-package (it imports `core:testing`); game binaries never import it. The `headless` lint rule covers all three.
- **Each game's suite:** `games/<game>/simulation/tests/suite_test.odin`: one `@(test)` per standard scenario call,
  then the game's own scenarios. Its reference run stays in `simulation/tests/testdata/`.
- **The toy's suite** (#67): `tests/scenarios/`, the scenarios package's own tests, with the toy's reference run in
  `tests/scenarios/testdata/`. It is the template a game's suite copies: the standard part is identical in shape.
- **The seeded-bug eval** (#123): `tests/scenarios/seeded_bugs_test.odin` plants runtime determinism bugs in the toy
  (World state not rolled back, state instances share, a value from an address) and checks that the detector meant
  for each (`rollback_every_tick`, `runs_match`, the netcode's desync detection) catches it. The static traps have
  planted cases in `tests/lint` and `tests/sim`.

### API

```odin
Suite :: struct($G: typeid) {    // G: the game type, a sim.Game (scenarios.Suite(g.Game){...})
	game:    ^G, // its scripted player plays every run
	content: []u8, // its level, if any
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
| `rollback_every_tick(t, suite, window = 8)` | restoring `window` (at most `headless.max_window(game)`) ticks back and re-simulating, every tick: 0 mismatches |
| `presence_churn(t, suite, window = 8)` | players come and go under `rollback_every_tick` (slot 0's player leaves, someone new takes slot 0, a slot empties and the first player comes back there): 0 mismatches, the newcomer is someone else, the one who came back has their handle and a returning join event |
| `runs_match(t, suite)` | two scripted runs alive at once (`run_interleaved`: the second created halfway through the first, then stepped alongside it and on after it is destroyed): every tick equal. Catches state instances share (a global, a library's static), which back-to-back runs miss |
| `session_agrees(t, suite, clients, profile)` | virtual-clock session: 0 desyncs, every client's verified checksums equal, all reach `ticks`, rollbacks > 0 unless `ideal` |
| `session_log_replays(t, suite, clients, profile)` | its own session; the relay's input log replays offline to every verified checksum |
| `late_join_agrees(t, suite, profile, player, tick)` | 0 desyncs; the joiner's checksums match from its first verified tick |
| `reference_replays(t, suite)` | replay of `ref.log` equals `ref.trace` |
| `reference_resumes(t, suite)` | resume of the snapshot equals the rest of `ref.trace` |

`profile` is `scenarios.Profile` (`.Ideal`, `.Wan`, `.Bad`: the network profiles above). Sessions run on the virtual
clock over loopback with the suite's seed and ticks; `late_join_agrees` runs `players` clients, `player` joining at
`tick`. Failures name the scenario's parameters and the first tick that differs. `session_run` returns structured
per-client results (final tick, verified checksums, rollbacks and depth, stall ticks) instead of JSON strings; the
CLI builds its JSON from them. A suite reads as a list of sentences:

```odin
@(test)
rollback_every_tick :: proc(t: ^testing.T) {scenarios.rollback_every_tick(t, &SUITE)}
@(test)
four_clients_agree_on_a_bad_network :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SUITE, 4, .Bad)}
```

The toy's suite calls `session_agrees` for 2 and 4 clients under `ideal`, `wan` and `bad`, and every other proc
once: it proves the library. A game's suite runs the minimal set that proves the game (`rollback_every_tick`, 4
clients under `bad`, a late joiner, `presence_churn`, the reference run's replay and resume) and puts the rest in
`when scenarios.LONG`.

### Running

- **Two tiers** (2026-11-11, replacing the one group of #4: on CI's few cores the games' full suites were most of
  the odin suite's time). `uni test` (the `odin` suite, in `verify` and CI) runs the toy's suite whole and each
  game's minimal set on short runs (`ticks = scenarios.LONG ? 3600 : 600`), in the same compile and parallel run as
  the unit tests; each scenario is its own test, so the runner spreads them over the cores. `uni test --long` builds
  with `-define:UNIFIED_LONG_TESTS=true` (`scenarios.LONG`): every standard scenario at full length, plus the slow
  tests a game keeps behind `when scenarios.LONG` (survivor's bot tuning check); run it by hand after a change to a
  game's rules or the netcode. One game alone: `odin test games/<game>/simulation/tests -collection:unified=src`.
- **`uni test --suite net`** keeps only the real-UDP, real-clock, multi-process test (a relay and 3 client
  processes, one under `bad`): a netcode transport test, at library level, on the toy's headless binary
  (`tests/toy/headless/`, a few lines wiring the toy into `unified:headless/modes`).
- **CI**, on every platform it tests (when each runs: the top of `.github/workflows/ci.yml`): `uni test` (every
  suite and every reference run: the cross-check), then `uni test --suite net`, then `uni bench`. Never `--long`.
- **Benchmarks are not part of the suites:** `uni bench` runs each game's `bench` mode (its standard benchmark) alone
  on a release build (reported, not gated; target: forward step + a re-sim of the prediction cap, 14 ticks at 64 Hz,
  ≤ 6 ms), and CI's job summary shows them.

### Reference runs (#61)

A reference run is a committed run every platform must reproduce. `uni record-reference <game>|toy`, on any
machine, runs that suite with `-define:UNIFIED_REGEN=true`: `reference_replays` then writes `ref.log`, `ref.trace`
and the snapshot through `run_sim` and `run_snapshot`, checks them (replay, resume), and writes `ref.json` (where it
was made: OS, architecture, Odin version, build flags, commit; when; the parameters) unless the log, trace and
snapshot came out byte for byte as committed: then ref.json stays too, and `record-reference` reports "nothing
changed" (re-recording is how to ask whether a change alters the sim). `reference_resumes` skips in
that build (it would race the writes); the other scenarios run as usual. Regenerate only after a change that
legitimately alters the simulation or the log or snapshot format, and commit the files with it, saying why. Nothing
else in the tools, suites or docs names a platform, and every build is for the machine it runs on (no `--arch` in
`uni build` or `uni setup`). CI runs both x64 and arm64, so it is the cross-architecture check.
