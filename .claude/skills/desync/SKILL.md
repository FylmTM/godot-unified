---
name: desync
description: Finding and shrinking a determinism bug in a unified game - a sync-test failure, a desync report in a session, a checksum mismatch, a reference run that fails on one platform, or a replay that diverges. How to read what the failure already names, find the first diverging tick and field with the headless binary, traces and replay regressions, shrink it to a small reproduction, and keep that as a test. Use whenever a run, test, session or CI job reports a desync, a mismatch or a divergence the change was not meant to cause.
---

# Finding a desync

A desync is a bug: the same inputs computed different bytes. Find the first tick that differs, then the first field,
then why. The failure usually names the tick already. Library paths are unified's (`unified/src/...` in a game repo);
`<game>` is optional where there is one game; every mode's options are in `./uni headless <game> -- help`.

## What the failure tells you

- **A sync-test fails** (`./uni test`, a test on `headless.Run`, the `synctest` mode): one machine, one build, and a
  re-simulation of a tick came out differently from its forward run. It prints the tick that differed and the tick
  whose rollback re-simulated it, or what the Extra's check found after a restore (`check_refs`: an orphan, a stale
  ref), or a NaN in the block. The cause is state `tick` reads that the rollback doesn't restore: a World field the
  Extra doesn't roll back, scratch kept across ticks, package-level state, something that depends on `sim.drawing`
  (`src/sim/README.md`, World; Debug draws and zones).
- **A session reports a desync** (the relay's majority vote on the checksum ticks; the dev UI, a `desync` hook,
  `session_run`'s `ok`): two machines differ. With typed reports on (the dev UI's host) the first one names the field:
  `tick 4160: enemies[12].pos.x 3.25 vs 3.5`; later ones are its consequences (`src/netcode/README.md`, Checksums and
  desyncs). Try the sync-test first: most session desyncs are rollback bugs it reproduces on one machine.
- **The reference run fails on one platform only** (a CI job): a float trap, since the same build computes
  differently on another CPU or OS: builtin `min`/`max`/`clamp` on floats, `core:math`, a NaN, an out-of-range
  float-to-int (`src/dmath/README.md`). The determinism lint (`uni test`) catches most; a type it can't see
  (`src/lint/README.md`, What it can't see) is the rest.
- **A replay regression diverges** (`replays_reproduce`): it names the first tick whose checksum or events differ and
  the leaf fields of the first stored block that differs, with both values; every block agreeing means the physics
  world differs. A change you meant: the `sim-change` skill. One you didn't: that field is where to look.
- **Two builds desync instead of refusing each other**: a rule changed without a `Game.version` bump (`sim-change`).

`examples/minimal_3d/GUIDE.md` (Gotchas: symptom, cause, fix) lists the usual causes by symptom.

## The first tick

- **One machine:** `./uni headless <game> -- synctest --ticks 600 --window 8` (`--seed`, `--players`). Its JSON's
  `first_mismatch` is the tick; stderr says which rollback re-simulated it.
- **Two builds or two machines:** `./uni headless <game> -- sim --ticks 600 --trace a.txt` on each (same `--seed`
  and `--players`), then diff the traces (`git diff --no-index a.txt b.txt`): a line per tick, `tick checksum`, and
  the first differing line is the first tick. Only every `sim.DEEP_CHECKSUM_EVERY`th tick's checksum covers the
  physics world's whole internal state, so a physics-only difference shows first on one of those. For an older build,
  check it out in a throwaway worktree (`git worktree add --detach .out/old <commit>`; never `git stash`).
- **A recording** (a dev UI build writes every session to `<user data>/recordings/`, and an F3 note carries one):
  `./uni headless <game> -- replay --log <folder>/inputs.unil` (`--snapshot <folder>/snapshot.unis` when it has one)
  checks it against the recorder's checksums and reports `diverged_tick`: the first checkpoint that differs, so the
  divergence is at or before it. Played in Godot (`--replay <folder>`), the dev UI's Timeline steps to it and the
  Inspector's `changes` root shows what each tick changed (`src/godot/README.md`, Replays).

## The first field

A replay regression reports the first differing tick and its leaf fields, through the typed diff, between any two
builds. Turn any reproduction into one:

1. Record it: `./uni headless <game> -- sim --ticks 600 --log inputs.unil` (a scripted run; or take a session
   recording's folder).
2. Put it in the game's `simulation/tests/replays/<name>/inputs.unil` (with its `snapshot.unis`, if any).
3. On the good build, `./uni test <game> --bless` writes its `expected.unie`.
4. On the bad build (or machine), `./uni test <game>`: the failure names the tick and the fields with both values.

When it's a regression worth keeping, commit the folder: it stays a test (`src/headless/README.md`, Replay
regressions).

## Shrink it

Cut until it still fails and nothing more can go:

- **Ticks:** run to just past the first differing tick.
- **The window:** `synctest --window 1` failing means the very next tick's re-simulation differs.
- **Players and seed:** `--players 1`; another `--seed` that fails sooner.
- **Rules:** with a sync-test reproduction, skip systems in `tick` one at a time (locally, never committed): the one
  whose skipping makes the mismatch go holds or reads the state the rollback misses.
- **A test:** write the reproduction as a rule test on `headless.Run` (sync-tested on every step, the test choosing
  the inputs and seating), so the fix is proven and stays proven.

## After the fix

The reproduction stays as a test (a rule test or a replay regression). Nothing is re-pinned: a fix that restores
determinism leaves the reference run and the replay regressions as they were; if they move, the fix changed the
results too (`sim-change`).
