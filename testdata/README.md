# testdata

Reference files for the cross-platform tests T7 and T8 (`spec/headless.md`, T1-T9). They are generated on **macOS ARM64**
and committed; CI (Linux x64, Windows x64) and the Rosetta check must reproduce them bit for bit.

| File | What it is |
|---|---|
| `ref.log` | Input log (`UNIL` v2, spec/sim.md: seed, slots, input size, ticks, then per tick present + replaced masks and 4 × 4 input bytes) of an offline run: 3600 ticks (64 Hz), 4 players, seed 7, scripted inputs, nothing replaced |
| `ref.trace` | Per-tick checksums of that run, one `"%06d %016x"` line per tick, ticks 1..3600 |
| `ref-1800.snap` | Portable snapshot (`UNIS` v2: state block plus Box3D state) after tick 1800 of the same run |
| `ref.json` | Provenance: when, on what platform and commit, the exact commands, and the final checksum |

- **T7:** `survivor replay --log ref.log --trace out` must equal `ref.trace`.
- **T8:** `survivor resume --in ref-1800.snap --ticks 1800 --trace out` must equal lines 1801–3600 of `ref.trace`.

## Regenerating

Only on purpose: after a change that legitimately alters the simulation, the checksum, or the log or snapshot
format. `python tools/dev.py check --regen` (refuses anywhere but macOS ARM64 unless `--force`) builds the survivor's
headless binary (release), then runs exactly:

```
survivor sim      --ticks 3600 --players 4 --seed 7 --trace ref.trace --log ref.log
survivor snapshot --ticks 1800 --players 4 --seed 7 --out ref-1800.snap
```

It self-checks the new files before copying them here (replay of `ref.log` reproduces `ref.trace`, resume of the
snapshot reproduces ticks 1801–3600, the log header matches the run), writes `ref.json`, then runs the tests.
Commit all four files together. `.gitattributes` marks `*.log`/`*.snap` binary and keeps `*.trace` LF, so Windows
checkouts compare cleanly.
