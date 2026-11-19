# `unified:headless`: offline runs, sessions, the game binary

A game played without Godot: by its scripted player (`sim.Game.scripted_input`, `scripted_commands`), offline or
through the netcode, for its tests, its benchmarks and the network suites. Three packages, one `headless` lint rule:

- `unified:headless`: the in-memory runs and `session_run`. A game's tests and end-to-end suite use it.
- `unified:headless/modes`: a game's headless binary. Only binaries import it.
- `unified:headless/scenarios`: the standard end-to-end scenarios. Test-only: it imports `core:testing`, so a binary
  never imports it.

It uses `sim` (the runs, the input log, snapshots) and `netcode` (relay, clients, links, network profiles); the
formats and the behaviour behind the runs are theirs (`src/sim/README.md`, `src/netcode/README.md`). A game opts into
a lobby service by handing one to `modes.run` (`eos.lobby`), so this package never imports a platform SDK.

## The binary

A game's `simulation/headless/main.odin` calls `modes.run(&GAME, ...)`; `uni headless` builds it when stale and runs
it, and the binary's `help` lists every mode and its options. The modes:

- offline, in memory: `sim` (a run, its trace and input log), `synctest` (a rollback every tick), `replay` (an input
  log, optionally from a portable snapshot's tick: an F3 note's recording, `src/godot/README.md`), `predict-stats`
  (how many rollbacks `sim.Game.predict_input` would save on a log: a game adopts a hook when its own recordings of
  real play say so, never on the scripted player's, whose inputs are held for a fixed period);
- `session`: a relay and scripted clients in process on the virtual clock behind a network profile (`session_run`);
  `uni bench` runs it;
- `relay`, `client`: separate processes over local UDP on the real clock (`uni test --suite net`);
- `bench`: the game's standard benchmark (`modes.run`'s `bench`, `sim.Game.bench_prepare` holding its population);
  `uni bench` runs it;
- `<lobby>-host`, `<lobby>-client` when the game opts into a lobby service: a scripted session over it, two processes
  (`src/eos/README.md`);
- the game's own modes (`modes.Mode`): the one way a game's repo adds a mode. Each mode's options are a struct parsed
  with `core:flags` in Unix style (`modes.parse`), the library's and a game's alike, so `help` shows what the struct
  declares and an unknown option fails.

Conventions every mode keeps:

- Its last stdout line is one JSON object (`mode`, and `ok` where it can fail); a non-zero exit is a failure, and a
  bad or unknown option exits 2 (`modes.die`).
- Ticks are numbered from 1: the state after the k-th step is tick k, and a run of N ticks ends at tick N.
  Checksums, in traces and JSON alike, are lowercase 16-digit hex.
- A client's result (`netcode.client_json`) is the same object everywhere: the `session` mode's results, `client`'s
  line, a lobby mode's, the Godot host's result line.
- The processes of one session (`relay`, `client`, the lobby modes) run seed 1, so they agree without passing one.

## Runs

Every run takes the game (`^G`, a `sim.Game`) and plays it on `game.levels`. In an offline run slot i is member i + 1 from tick 1, joining with its join record (`src/sim/README.md`,
Players), and `Seat`s change who holds a slot. Offline there is no relay to hold commands back, so a script that
sends more than a tick takes fails the run (`Scripted_Commands`).

The stepped `Run` is what a game's own tests start from: a run the test steps itself, sync-tested on every step,
played by the scripted player or by the test's own inputs, with the test seating people and pinning the state it
changes. Its doc comment has the walk-through.

`session_run` puts a relay and scripted clients on one thread over loopback, each client's link behind the network
simulator (`netcode.PROFILES`, `src/netcode/README.md`), and steps them through virtual time: as fast as it computes,
and deterministic, so a session is a test. The `relay` and `client` modes are the same session on the real clock
between processes.

## End-to-end suites

Each game has its own suite of Odin tests calling the library in process (`examples/<game>/simulation/tests/`, from
`suite_test.odin`): one `@(test)` per standard scenario (`unified:headless/scenarios`, one proc each, named for what
it checks), then the game's own scenarios, its reference run's constant
(`REFERENCE`), the determinism lint (`lint.check_game`) and its extension's install check (`godot.install_problems`:
what Godot would refuse at load, caught by `uni test`). A new game copies minimal_3d's
(`examples/minimal_3d/simulation/tests/`, what `uni init` copies). The toy's suite (`tests/scenarios/`) proves the
library: it runs every scenario.

**Two tiers.** The default run covers the toy's suite whole and each game's minimal set (a few standard scenarios,
its reference run and its replay regressions; the game's suite says which) on short runs, each scenario its own test so the runner spreads them over the cores. The long tier (`scenarios.LONG`, `uni test
--long`) runs every standard scenario at full length, and the slow tests a game keeps behind it.

## Reference runs

A reference run is a run every platform must reproduce, pinned in the game's tests as one constant
(`REFERENCE :: scenarios.Reference{...}`, checked by `scenarios.reference_reproduces`): the checksums at four
checkpoints, the hash of every tick's checksum, and the hashes of the input log's and the snapshot's bytes, so this
platform both computes and encodes what every other does. CI runs it on every platform, which makes it the
cross-platform determinism check.

A mismatch prints the literal to paste: paste it only after a change that alters the simulation or the log or
snapshot format, saying why (the `unified-sim-change` skill). The log and snapshot carry the build's compat, so a version or
pin bump moves their hashes while the checkpoints and the trace stay.

## Replay regressions

A recorded session kept with a game's tests as one that must reproduce: the gameplay of real play, checked tick by
tick, without a hand-written scenario. Each is a replay folder in the game's `simulation/tests/replays/<name>/`, as
the game writes them (a session recording's or an F3 note's `inputs.unil`, and the `snapshot.unis` it continues when
it starts after tick 0; `src/godot/README.md`, Replays), so the game's replay session plays a failing one. Beside it
`expected.unie` holds what the build that blessed it computed: every tick's checksum and events, and the state block on
the ticks peers compare (`sim.DEEP_CHECKSUM_EVERY`), each packed as its difference from the one before. The recording
itself is never rewritten.

The suite's `scenarios.replays_reproduce` replays every folder (`headless.regression_run`). A divergence names the
first tick whose checksum or events differ, then the leaf fields of the first stored block from there on that differs,
with both values, through the typed diff the op log uses (`sim.state_changes`); when every block agrees, what differs
is the Extra (the physics world). `uni test --long` replays each recording as a sync-tested run too (`Run`): rollback
on real play's inputs, which no scripted player sends.

**The results decide, never the build's identity.** A recording replays whatever compat or levels it was recorded and
blessed with, so a refactor or a pin bump that computes nothing differently passes, and a rules change or a re-baked
level fails at its first tick. After a meant change, `uni test <game> --bless` writes a new expectation for each
recording that diverges or has none (a warning names each and where it diverged), committed with the change (the
`unified-sim-change` skill). A new regression is a copied folder, then a bless. A recording whose Input, commands, Setup or
Profile changed layout (or whose snapshot no longer loads) can't be blessed: record a new one. `uni init` leaves
minimal_3d's recordings out of a new game: a game records its own.
