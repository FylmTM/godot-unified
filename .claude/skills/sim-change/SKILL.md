---
name: sim-change
description: What to do when a change alters what the deterministic simulation computes - a reference run or the Box3D golden trace no longer reproduces, a game's rules or tuning change, the state layout, input, command or snapshot format changes, or the netcode wire protocol changes. Covers regenerating reference runs, the golden trace, protocol bumps, and the benchmarks. Use before committing any change to a sim package, src/physics, src/b3, src/netcode or the unified-box3d pin, and whenever uni test reports a reference run or golden trace mismatch.
---

# Changing what the simulation computes

The committed reference runs and the Box3D golden trace are the proof that every platform computes the same thing.
They change only on purpose, never to make a test pass.

## When a reference run or the golden trace fails

`./uni test` replays every game's reference run (`games/<game>/simulation/tests/testdata/`, the toy's
in `tests/scenarios/testdata/`) and checks `GOLDEN` in `tests/b3` (and `GOLDEN_CHARACTERS` and `GOLDEN_FIELD` in `tests/physics`). A mismatch means the
simulation changed.

1. **Was it meant to?** A rules, tuning or physics change: yes. A refactor, a tooling change, a view-only change or
   a dependency bump you thought neutral: no, so find the cause. Check main in a throwaway worktree
   (`git worktree add --detach .out/main-check origin/main`, run the check there, `git worktree remove --force .out/main-check`); never
   `git stash`, the stash is shared by every session. A determinism lint failure or a float-order change (summation order, a new `core:math` call) is the usual cause.
2. **If it was meant to:** regenerate, on any machine, and commit the files with the change that caused them:

   ```
   ./uni record-reference <game>      # or: record-reference toy
   ```

   It lists the files that changed. For a Box3D change, update `GOLDEN` in `tests/b3/golden_test.odin` to the
   value the failing test prints.
3. **Say why** in the commit message and the PR: what changed in the simulation and why the old results are no longer
   right.
4. Run CI on all four platforms before merging (below).

Details: `src/headless/SPEC.md` (End-to-end suites, Reference runs).

## Full CI before merging

A PR that touches `src/physics`, `src/b3`, the `[box3d]` pin or a game's sim runs CI on all four platforms before it
merges, whether or not its results changed:

```
gh workflow run ci.yml --ref <branch> -f macos=true
```

The goldens and reference runs must reproduce on Linux x64 and arm64, Windows x64 and macOS ARM64, and a PR's own CI
skips macOS (it runs nightly on main). Wait for the run to pass and link it in the PR.

## The long suites

`./uni test` runs only each game's minimal set of standard scenarios, on short runs. A change to a game's rules or
tuning, `src/physics`, `src/netcode` or the rollback path also runs the long variant once before the PR:

```
./uni test --long                  # every standard scenario of every game at full length, survivor's tuning check
./uni test --suite net --long      # when netcode changed: the real-UDP run for 15 s
```

## Format and protocol changes

- **State layout, input, commands, player count, tick rate, game name or version, or the `[box3d]` pin:**
  `sim.compat_of` changes with them, so peers on different builds refuse each other at hello, and a replay or
  snapshot from another build is refused. Nothing to bump by hand. Reference runs are regenerated (above), since the
  log and snapshot carry compat.
- **A game's rules or tuning** (it computes differently with the same layouts): bump that game's `Game.version`.
- **The library's own simulation** (`src/sim`, `src/dmath`, `src/physics`, `src/b3`): when a change makes a reference
  run or a golden trace compute differently, bump `sim.LIBRARY_VERSION` (`src/sim/sim.odin`) with a note on what
  changed, in the same PR. A refactor, a comment or a tooling change that reproduces every reference run and golden
  doesn't bump it.
- **The netcode wire protocol** (anything a datagram, hello, snapshot transfer or command message carries):
  bump `PROTOCOL_VERSION` in `src/netcode/proto.odin` with a note on what changed. Nothing else to bump: an EOS
  lobby carries the build (`compat` and the protocol), so a joiner on another build is told so before joining
  (`src/eos/SPEC.md`). Update `src/netcode/SPEC.md`. The datagram header has its own `DGRAM_VERSION`
  (`src/netcode/channel.odin`).
- **The snapshot or input log format:** bump `SNAP_VERSION` (`src/sim/snapshot.odin`) or `LOG_VERSION`
  (`src/sim/log.odin`) with a note on what changed, then regenerate the reference runs. The level format has its own
  `VERSION` (`src/level/level.odin`).

## Speed

A change to a sim, `src/physics`, `src/netcode` or the rollback path runs the benchmarks too:

```
./uni bench
```

Target: forward step plus a re-sim at the prediction cap (14 ticks at 64 Hz) within 6 ms; `uni bench` also reports
each game's session under `bad` (`net-bench`), which a netcode change should not make worse. A re-sim that disagrees with the forward run fails the
bench: that is a determinism bug, not a speed problem.
