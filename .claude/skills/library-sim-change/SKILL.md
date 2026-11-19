---
name: library-sim-change
description: What a change to what unified's own deterministic code computes needs on top of the sim-change skill - the Box3D golden traces, the toy game's reference run, the library, protocol, snapshot, log and level format versions, the net suite and the cross-platform CI check. Use before committing any change to src/sim, src/dmath, src/physics, src/netcode, src/level or the unified-box3d pin, and whenever uni test reports a golden trace mismatch.
---

# Changing what the library computes

The `sim-change` skill is how any game's reference run and replay regressions are re-pinned, and the long suites and
the benchmark; it holds here for every example game. This is what only this repo adds.

## The golden traces and the toy's reference run

`./uni test` also runs the toy's reference run (`REFERENCE` in `tests/scenarios/suite_test.odin`) and checks the
golden traces in `tests/physics` (`BOX3D_GOLDEN`, Box3D alone; `GOLDEN_CHARACTERS`, `GOLDEN_FIELD` and
`GOLDEN_TERRAIN`). A mismatch means the library computes differently: the same questions as a game's (`sim-change`),
and after a meant change the printed literals are pasted in the same commit, `BOX3D_GOLDEN` in
`tests/physics/box3d_test.odin` for a Box3D change. A library change moves every example's reference run too: re-pin
each one it moves.

## CI

The goldens and reference runs must reproduce on Linux x64 and arm64, Windows x64 and macOS ARM64. The PR's own run
covers the first three and is the check before merging: no extra dispatch. macOS doesn't block the merge: `main`'s
run after it covers macOS, and if it fails there, fix it first (AGENTS.md, Workflow).

## The long suites

A change to `src/physics`, `src/netcode` or the rollback path runs, beside `./uni test --long`:

```
./uni test --suite net --long      # when netcode changed: the real-UDP run for 15 s
```

## Format and protocol changes

What changed decides what is bumped; each constant's comment says it too. What `sim.compat_of` covers (its doc
comment; `src/sim/README.md`, Build identity) is never bumped by hand: peers on different builds refuse each other at
hello, and a replay or snapshot of another build is refused.

| Constant | Guards | Bump when |
|---|---|---|
| `sim.LIBRARY_VERSION` (`src/sim/sim.odin`) | the library's results | `src/sim`, `src/dmath` or `src/physics` make a reference run or golden trace compute differently (not a refactor that reproduces them) |
| `netcode.PROTOCOL_VERSION` (`src/netcode/proto.odin`) | the wire | anything a datagram, message, snapshot transfer or EOS packet carries changes; every datagram carries it, and an EOS lobby's build attribute too |
| `sim.SNAP_VERSION` (`src/sim/snapshot.odin`) | the snapshot's bytes | the snapshot format changes |
| `sim.LOG_VERSION` (`src/sim/log.odin`) | the input log's bytes | the log format changes |
| `level.VERSION` (`src/level/level.odin`) | a `.level` file's bytes | the level format changes |

A bump of `LIBRARY_VERSION`, or of the snapshot or log format, moves every reference run's hashes: regenerate them.
A protocol change updates the layout where the code states it (`netcode.Msg`, the `channel.odin` and `window.odin`
headers) in the same diff.

## Speed

`./uni bench` reports every game's sessions (`session` under `bad`, and under `wan` with a late joiner: each client
step's time, the join and its snapshot transfer), which a netcode change should not make worse.
