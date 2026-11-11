# testdata

The toy game's reference run: the library's own cross-platform proof (`src/headless/SPEC.md`, Reference runs), with
no game or physics in it. `the_reference_run_replays` and `the_reference_run_resumes` in `../suite_test.odin` check it
in `uni test`.

| File | What it is |
|---|---|
| `ref.log` | Input log of 1800 ticks, 4 scripted players, seed 7 |
| `ref.trace` | Its per-tick checksums, one `"%06d %016x"` line per tick, ticks 1..1800 |
| `ref-900.snap` | Portable snapshot after tick 900 of the same run |
| `ref.json` | Where, when and how it was made, and the final checksum |

Regenerate deliberately, on any machine: `uni record-reference toy`, then commit the files with the change that
made it necessary.
