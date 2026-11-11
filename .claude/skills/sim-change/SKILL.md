---
name: sim-change
description: What to do when a change alters what the deterministic simulation computes - a reference run or the Box3D golden trace no longer reproduces, a game's rules or tuning change, the state layout, input, command or snapshot format changes, or the netcode wire protocol changes. Covers regenerating reference runs, the golden trace, protocol and lobby-bucket bumps, and the benchmarks. Use before committing any change to a sim package, src/physics, src/netcode or the Box3D fork, and whenever uni test reports a reference run or golden trace mismatch.
---

# Changing what the simulation computes

The committed reference runs and the Box3D golden trace are the proof that every platform computes the same thing.
They change only on purpose, never to make a test pass.

## When a reference run or the golden trace fails

`./uni test` replays every game's reference run (`games/<game>/simulation/tests/testdata/`, the toy's
in `tests/scenarios/testdata/`) and checks `GOLDEN` in `tests/b3` (and `GOLDEN_MOVERS` in `tests/physics`). A mismatch means the simulation changed.

1. **Was it meant to?** A rules, tuning or physics change: yes. A refactor, a tooling change, a view-only change or
   a dependency bump you thought neutral: no, so find the cause. Bisect with `git stash` or the previous commit; a
   determinism lint failure or a float-order change (summation order, a new `core:math` call) is the usual cause.
2. **If it was meant to:** regenerate, on any machine, and commit the files with the change that caused them:

   ```
   ./uni record-reference <game>      # or: record-reference toy
   ```

   It lists the files that changed. For a Box3D change, update `GOLDEN` in `tests/b3/golden_test.odin` to the
   value the failing test prints.
3. **Say why** in the commit message and the PR: what changed in the simulation and why the old results are no longer
   right.
4. Run CI on all four platforms before merging (`gh workflow run ci.yml --ref <branch>`): CI is the cross-check that
   the new reference runs reproduce on Linux x64 and arm64, Windows x64 and macOS ARM64.

Details: `src/headless/SPEC.md` (End-to-end suites, Reference runs).

## Format and protocol changes

- **State layout, input, commands, player count, tick rate, game name or version:** `sim.compat_of` changes with
  them, so peers on different builds refuse each other at hello. Nothing to bump by hand. Reference runs are
  regenerated (above), since the log and snapshot carry the layout.
- **The netcode wire protocol** (anything a datagram, hello, snapshot transfer or command message carries):
  bump `PROTOCOL_VERSION` in `src/netcode/proto.odin` with a note on what changed, and bump every game's lobby
  bucket with it (`*_BUCKET` in each game's `simulation/extension/extension.odin`, and survivor's `EOS_BUCKET` in
  `simulation/headless/online.odin`). Each sits next to an `#assert` on the protocol number, which fails until you
  update it with the bucket. Update `src/netcode/SPEC.md`. The datagram header has its own `DGRAM_VERSION`
  (`src/netcode/channel.odin`).
- **The snapshot or input log format:** bump `SNAP_VERSION` (`src/sim/snapshot.odin`) or `LOG_VERSION`
  (`src/sim/log.odin`) with a note on what changed, then regenerate the reference runs. The level format has its own
  `VERSION` (`src/level/level.odin`).

## Speed

A change to a sim, `src/physics`, `src/netcode` or the rollback path runs the benchmarks too:

```
./uni bench
```

Target: forward step plus an 8-tick re-sim within 6 ms. A re-sim that disagrees with the forward run fails the
bench: that is a determinism bug, not a speed problem.
