# testdata

friendslop's reference run (`src/headless/SPEC.md`, Reference runs): every platform must reproduce it bit for bit,
dynamic movers, joints, platforms, carries and throws included. `the_reference_run_replays` and
`the_reference_run_resumes` in `../suite_test.odin` check it in `dev.py test`.

| File | What it is |
|---|---|
| `ref.log` | Input log of 1800 ticks of 4 scripted chaos players, seed 7, on the embedded park level (`UNIL` v4 carries the level's hash) |
| `ref.trace` | Its per-tick checksums, one `"%06d %016x"` line per tick, ticks 1..1800 |
| `ref-900.snap` | Portable snapshot after tick 900 of the same run |
| `ref.json` | Where, when and how it was made, and the final checksum |

Regenerate deliberately, on any machine: `python tools/dev.py regen friendslop`, then commit the files with the
change that made it necessary.
