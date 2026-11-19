---
name: sim-change
description: What to do when a change alters what a game's deterministic simulation computes - its reference run or a replay regression no longer reproduces, its rules or tuning change, its Input, commands, Setup or Profile change layout, or a unified bump moves its results. Covers re-pinning the reference run, blessing replay regressions, Game.version, the long suites and the benchmark. Use before committing any change to a game's sim package, and whenever uni test reports a reference run or replay regression mismatch.
---

# Changing what a game's simulation computes

A game's reference run (the `REFERENCE` constant in its `simulation/tests/`) is the proof that every platform
computes the same thing, and its replay regressions (`simulation/tests/replays/`) that its recorded sessions still play
the same. They change only on purpose, never to make a test pass. In a game repo, library paths are unified's
(`unified/src/...`); `src/headless/README.md` (Reference runs, Replay regressions) has how both work.

## When a reference run or a replay regression fails

1. **Was it meant to?** A rules, tuning or physics change: yes. A refactor, a tooling change, a view-only change or
   a unified bump you thought neutral: no, so find the cause (the `desync` skill: where two builds part). Run the
   old code in a throwaway worktree (`git worktree add --detach .out/main-check origin/main`, run the check there,
   `git worktree remove --force .out/main-check`); never `git stash`, the stash is shared by every session. A
   determinism lint failure or a float-order change (summation order, a new `core:math` call) is the usual cause.
2. **If it was meant to:** paste the `REFERENCE :: scenarios.Reference{...}` literal the failing test prints over the
   game's `REFERENCE`, in the same commit as the change. A replay regression (`replays_reproduce` names its first
   differing tick and fields) is blessed with `./uni test <game> --bless`, its `expected.unie` committed with the
   change. Only the `snapshot` and `log` hashes moving (the checkpoints and `trace` unchanged) means the format or the
   build's compat changed, not the results: a unified bump does that.
3. **Bump `Game.version`** with every rule or tuning change, so builds that would compute differently refuse each other
   at hello instead of desyncing (`src/sim/README.md`, Build identity). A layout change needs no bump: `sim.compat_of`
   covers the layouts of the types, the tick rate and the levels' hash by itself.
4. A recording whose Input, commands, Setup or Profile changed layout can't be blessed: record the session again
   (`src/headless/README.md`, Replay regressions).
5. **Say why** in the commit message: what changed in the simulation and why the old results are no longer right.

## The long suites

`./uni test` runs only the game's minimal set of standard scenarios, on short runs. A change to the game's rules,
tuning, physics or anything on the rollback path also runs the long variant once before handing back:

```
./uni test --long    # every standard scenario at full length, and each replay regression as a sync-tested run
```

## Speed

A change to the sim runs the benchmark too: `./uni bench` (the target, a forward step, a restore, a re-sim at the
prediction cap and a deep checksum at their p99, is in `uni bench -h`; it also reports the game's sessions, which a
change should not make worse). A re-sim that disagrees with the forward run fails the bench: that is a determinism
bug (the `desync` skill), not a speed problem.
