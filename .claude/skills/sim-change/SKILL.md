---
name: sim-change
description: What to do when a change alters what the deterministic simulation computes - a reference run, a replay regression or the Box3D golden trace no longer reproduces, a game's rules or tuning change, the state layout, input, command or snapshot format changes, or the netcode wire protocol changes. Covers regenerating reference runs, the golden trace, protocol bumps, and the benchmarks. Use before committing any change to a sim package, src/physics, src/netcode or the unified-box3d pin, and whenever uni test reports a reference run, replay regression or golden trace mismatch.
---

# Changing what the simulation computes

The reference runs' constants and the Box3D golden traces are the proof that every platform computes the same thing,
and a game's replay regressions that its recorded sessions still play the same. They change only on purpose, never to
make a test pass.

## When a reference run or the golden trace fails

`./uni test` runs every game's reference run (`reference_reproduces`, its constants in the game's
`simulation/tests/` suite, the toy's in `tests/scenarios/suite_test.odin`) and checks the golden
traces in `tests/physics` (`BOX3D_GOLDEN`, Box3D alone; `GOLDEN_CHARACTERS`, `GOLDEN_FIELD` and `GOLDEN_TERRAIN`). A mismatch means the simulation changed.

1. **Was it meant to?** A rules, tuning or physics change: yes. A refactor, a tooling change, a view-only change or
   a dependency bump you thought neutral: no, so find the cause. Check main in a throwaway worktree
   (`git worktree add --detach .out/main-check origin/main`, run the check there, `git worktree remove --force .out/main-check`); never
   `git stash`, the stash is shared by every session. A determinism lint failure or a float-order change (summation order, a new `core:math` call) is the usual cause.
2. **If it was meant to:** paste the `REFERENCE :: scenarios.Reference{...}` literal the failing test prints over the suite's `REFERENCE`, and
   for a Box3D change `BOX3D_GOLDEN` in `tests/physics/box3d_test.odin`, in the same commit as the change. A replay
   regression (`replays_reproduce`: its first differing tick and fields) is blessed with `./uni test <game> --bless`,
   its `expected.unie` committed with the change (`src/headless/README.md`, Replay regressions). Only the `snapshot`
   and `log` hashes moving (the checkpoints and `trace` unchanged) means the format or compat changed, not the
   results. To find where two builds part: `./uni headless <game> -- sim --trace FILE` on each, compare the files.
3. **Say why** in the commit message and the PR: what changed in the simulation and why the old results are no longer
   right.
4. Run CI on all four platforms before merging (below).

Details: `src/headless/README.md` (End-to-end suites, Reference runs).

## Full CI before merging

A PR that touches `src/physics`, the `[box3d]` pin or a game's sim runs CI on all four platforms before it
merges, whether or not its results changed:

```
gh workflow run ci.yml --ref <branch> -f macos=true
```

The goldens and reference runs must reproduce on Linux x64 and arm64, Windows x64 and macOS ARM64, and a PR's own CI
skips macOS. Wait for the run to pass on the other three and link it in the PR; macOS doesn't block the merge (its
runners often never start). After the merge, `main`'s run covers macOS: if it fails there, fix it first.

## The long suites

`./uni test` runs only each game's minimal set of standard scenarios, on short runs. A change to a game's rules or
tuning, `src/physics`, `src/netcode` or the rollback path also runs the long variant once before the PR:

```
./uni test --long                  # every standard scenario of every game at full length, survivor's tuning check
./uni test --suite net --long      # when netcode changed: the real-UDP run for 15 s
```

## Format and protocol changes

What changed decides what is bumped; each constant's comment says it too. What `sim.compat_of` covers (its doc
comment; `src/sim/README.md`, Build identity) is never bumped by hand: peers on different builds refuse each other at
hello, and a replay or snapshot of another build is refused.

| Constant | Guards | Bump when |
|---|---|---|
| `Game.version` (the game's) | the game's results | its rules or tuning compute differently with the same layouts |
| `sim.LIBRARY_VERSION` (`src/sim/sim.odin`) | the library's results | `src/sim`, `src/dmath` or `src/physics` make a reference run or golden trace compute differently (not a refactor that reproduces them) |
| `netcode.PROTOCOL_VERSION` (`src/netcode/proto.odin`) | the wire | anything a datagram, message, snapshot transfer or EOS packet carries changes; every datagram carries it, and an EOS lobby's build attribute too |
| `sim.SNAP_VERSION` (`src/sim/snapshot.odin`) | the snapshot's bytes | the snapshot format changes |
| `sim.LOG_VERSION` (`src/sim/log.odin`) | the input log's bytes | the log format changes |
| `level.VERSION` (`src/level/level.odin`) | a `.level` file's bytes | the level format changes |

A bump of any of the first two, or of the snapshot or log format, moves the reference runs' hashes: regenerate them
(above). A protocol change updates the layout where the code states it (`netcode.Msg`, the `channel.odin` and
`window.odin` headers) in the same diff.

## Speed

A change to a sim, `src/physics`, `src/netcode` or the rollback path runs the benchmarks too:

```
./uni bench
```

The target (a forward step, a restore, a re-sim at the prediction cap and a deep checksum, at their p99) is in
`uni bench -h`; `uni bench` also reports each game's sessions (`session` under `bad`, and under `wan` with a late
joiner: each client step's time, the join and its snapshot transfer), which a netcode change should not make worse. A re-sim that disagrees with the forward run fails the
bench: that is a determinism bug, not a speed problem.
