# `unified:headless`: offline runs, sessions, the game binary

Status: signed off 2026-11-18 (#333)

Three packages: `unified:headless` (`src/headless`), the in-memory runs and `session_run`, which the end-to-end
suites use; `unified:headless/modes`, a game's headless binary (only binaries import it); and
`unified:headless/scenarios`, the standard scenarios (test-only: it imports `core:testing`, binaries never do). The
`headless` lint rule covers all three. Formats and the behaviour behind the runs: `src/sim/SPEC.md`,
`src/netcode/SPEC.md`.

## The binary

A game's `simulation/headless/main.odin` calls `modes.run(&GAME, {content, bench, bench_prepare}, variants,
lobbies, extra)`: a run can pick one of the `variants` (another tuning) by name, a level file replaces the
content, `lobbies` opts into lobby services (`eos.lobby`: it links the SDK), `extra` adds the game's own modes
(`modes.Mode{name, options, help, run}`, parsed and checked like the library's). `uni headless` builds it when stale
and runs it; the binary's `help` lists every mode and its options.
The runs are played by the game's scripted player (`sim.Game.scripted_input`, `scripted_commands`).

- `sim`: an offline run; its per-tick trace and input log.
- `synctest`: an offline run that re-simulates the last W ticks every tick; fails on any tick that differs.
- `replay`: replays an input log (refused when another build or level recorded it), optionally from a portable
  snapshot's tick (an F3 note's recording, `src/godot/SPEC.md`).
- `session`: a relay and scripted clients in process on the virtual clock behind a network profile (`session_run`):
  rollbacks, stalls, step times, bytes per second, a late joiner's join; a desync fails it. `uni bench` runs it.
- `relay`, `client`: separate processes over local UDP on the real clock.
- `bench`: the game's standard benchmark (`Headless.bench`, `bench_prepare` holding its population): step, save,
  checksum, a portable snapshot's encode, a restore and a re-sim at the prediction cap every tick. `uni bench` runs
  it.
- `<lobby>-host`, `<lobby>-client` (a game that opts in): a scripted session over the lobby service, two processes
  (`src/eos/SPEC.md`).

Conventions:

- Every mode prints one JSON object as its last stdout line (`mode`, and `ok` where it can fail); non-zero exit =
  failure; a bad or unknown option exits 2. A timing is `{"mean": µs, "p99": µs}`.
- Ticks are numbered from 1: the state after the k-th step is tick k, and a run of N ticks ends at tick N. A trace has
  one line per tick, `"%06d %016x"`, in order. Checksums in traces and JSON are lowercase `%016x`.
- A client's result (`netcode.client_json`) is the same object everywhere: the `session` mode's results, `client`'s
  line, a lobby mode's, the Godot host's result line.
- `relay` and `client` run seed 1.

## Runs

`Headless{game, content, bench, bench_prepare}` describes a game's runs. In an offline run (`run_sim`, `run_synctest`,
`run_interleaved`, `run_replay`, `run_snapshot`, `run_resume`, the stepped `Run`) slot i is member i + 1 from tick 1,
joining with its join record (`src/sim/SPEC.md`, Players); `seats` (`Seat{tick, slot, member}`, member 0: nobody)
change who holds a slot. A tick takes the commands each slot's script sends for it; a script that sends more than a
tick takes (`sim.COMMANDS_PER_SLOT`) fails the run: offline there is no relay to hold the rest.

`session_run(&headless, Session_Config{clients, profile, ticks, seed, late_tick, late_slot})` runs a relay and
scripted clients over loopback on one thread through virtual time (as fast as it computes, deterministically); a
`late_tick` of 0 means everyone starts together. Its result: `ok` (every client verified every tick and left
cleanly, nothing desynced), the first desync with its typed detail, the relay's input log, each client's
`Client_Result`, the relay's channel stats, and a late joiner's join (Hello to playing, and the bytes it took).

Network profiles: `netcode.PROFILES[.Ideal | .Wan | .Bad]` (`src/netcode/SPEC.md`).

## End-to-end suites

Each game has its own suite of Odin tests calling the library in process
(`games/<game>/simulation/tests/suite_test.odin`): one `@(test)` per standard scenario, named for what it checks, then
the game's own scenarios, with its reference run's constants in its `Suite`. The toy's suite (`tests/scenarios/`) is
the template a game's copies, and proves the library: it runs every scenario.

```odin
Suite :: struct($G: typeid) {    // G: the game type, a sim.Game
	game:    ^G, // its scripted player plays every run
	content: []u8, // its level, if any
	players: int, // scripted players in offline runs
	seed:    u64,
	ticks:   u32, // length of offline runs and sessions
	ref:     Reference,
}
Reference :: struct {            // run_sim(seed, players) for `ticks` ticks, pinned by hashes
	seed, players, ticks, snapshot_tick, // the snapshot taken at snapshot_tick resumes to `ticks`
	checkpoints: [4]u64,           // the checksum at ticks / 4, ticks / 2, 3 * ticks / 4 and ticks
	trace, snapshot, log: u64,     // the hashes of every tick's checksum, the snapshot's and the log's bytes
}
```

| Proc | Passes when |
|---|---|
| `rollback_every_tick(t, suite, window = 8)` | restoring `window` ticks back and re-simulating, every tick: 0 mismatches (each re-simulated tick's checksum and events as the first run's), no NaN in the block |
| `presence_churn(t, suite, window = 8)` | players come and go under `rollback_every_tick`: 0 mismatches, the Extra agrees after every restore |
| `runs_match(t, suite)` | two runs alive at once (the second created halfway through the first): every tick equal. Catches state instances share, which back-to-back runs miss |
| `session_agrees(t, suite, clients, network)` | a virtual-clock session: 0 desyncs, every client's checksums equal, all reach `ticks`, the relay's log replays to them, rollbacks > 0 unless `.Ideal` |
| `late_join_agrees(t, suite, network, slot, tick)` | 0 desyncs; the joiner's checksums match from its first verified tick; the log replays to them |
| `reference_reproduces(t, suite)` | the reference run's checkpoints and hashes are the suite's constants; its log replays, and its snapshot resumes, to the same checksums |

**Two tiers.** The default run covers the toy's suite whole and each game's minimal set (`rollback_every_tick`, 4
clients under `bad`, a late joiner, `presence_churn`, the reference run) on short runs, each scenario its own test so
the runner spreads them over the cores. The long tier (`scenarios.LONG`) runs every standard scenario at full length
and the slow tests a game keeps behind it.

## Reference runs

A reference run is a run every platform must reproduce, pinned in the suite as constants: the checksums at four
checkpoints, the hash of every tick's checksum, and the hashes of the input log's and the snapshot's bytes, so this
platform both computes and encodes what every other does. A mismatch names the first checkpoint that differs and
prints the literal to paste: paste it only after a change that alters the simulation or the log or snapshot format,
saying why (the `sim-change` skill). The log and snapshot carry compat, so a version or pin bump moves their hashes
while the checkpoints and trace stay. To find the first tick that differs between two builds, compare the
`sim` mode's traces from both.
