# Task C2: bug hunt

You're maintaining an existing deterministic simulation (a headless benchmark of a co-op game). The codebase in your
directory is meant to implement `bench/a/SPEC.md` (linked as `../SPEC.md`): Box3D physics, 4 players, 300 props,
1000 swarm agents, a pointer-free state block, and a per-tick XXH3 hash. The same spec is implemented in several
languages, and every correct implementation produces bit-identical per-tick hashes.

## The reports

Users report two problems with this build:

1. Its trace doesn't match the reference implementation. The reference trace for the default run is at
   `../../../harness/reference-3600.txt` (output of `--ticks 3600 --trace PATH`; a 20000-tick reference is next to it
   as `reference-20000.txt`).
2. Long sessions (`--ticks 20000`) sometimes crash or misbehave.

## What to do

- Find and fix the bugs. Treat `SPEC.md` as the source of truth for behaviour.
- Fix them the way you would on a real team: minimal, targeted changes in this language's idiom, keeping the
  codebase's existing structure. Don't rewrite modules or replace the implementation.
- **Use only `./build.sh dev|release` to build.** It logs each build, and that log is part of the measurement.
- Touch nothing outside your directory.

## Done means

- `python3 ../../../harness/check_c2.py .` passes. It builds release and dev, compares the 3600-tick release trace to
  the reference byte-for-byte, and runs 20000 ticks in both dev and release, which must finish without a crash and
  match `reference-20000.txt`.
- `NOTES.md` (≤ 30 lines) lists each bug you found: the symptom, the root cause (file and line), and your fix. Also
  note how you located it and anything that was hard.
