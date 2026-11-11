# testdata

The survivor's reference run (`src/headless/SPEC.md`, Reference runs): every platform must reproduce it bit for bit.
`the_reference_run_replays` and `the_reference_run_resumes` in `../suite_test.odin` check it in `uni test`.

| File | What it is |
|---|---|
| `ref.log` | Input log of an offline run with the `stress` tuning: 3600 ticks, 4 scripted players, seed 7 |
| `ref.trace` | Its per-tick checksums, one `"%06d %016x"` line per tick, ticks 1..3600 |
| `ref-1800.snap` | Portable snapshot after tick 1800 of the same run |
| `ref.json` | Where, when and how it was made, and the final checksum |

Regenerate deliberately, on any machine: `uni record-reference survivor`, then commit the files with the change
that made it necessary.
