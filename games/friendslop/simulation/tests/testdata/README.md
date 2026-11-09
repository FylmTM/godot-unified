# testdata

friendslop's reference run for the cross-platform test F5, generated on **macOS ARM64** and committed; every CI
platform and the Rosetta check must reproduce it bit for bit.

| File | What it is |
|---|---|
| `ref.log` | Input log of 1800 ticks of 4 chaos players, seed 7, on the embedded park level (`UNIL` v3 carries the level's hash). Dynamic movers, joints, platforms, carries and throws |
| `ref.trace` | Per-tick checksums of that run, one `"%06d %016x"` line per tick, ticks 1..1800 |
| `ref.json` | Provenance: when, on what platform and commit, the exact command, and the final checksum |

- **F5:** `friendslop replay --log ref.log --trace out` must equal `ref.trace`.

`python tools/dev.py check --regen` rewrites these with the survivor's (see
`games/survivor/simulation/tests/testdata/README.md`).
