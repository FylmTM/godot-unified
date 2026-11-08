# testdata

Per-language reference files for the cross-platform tests T7 and T8 (`spec/CORE.md` §4). They're generated on
**macOS ARM64** and committed. CI (Linux x64, Windows x64) must reproduce them bit-for-bit. Hashes are per language,
so every language has its own directory: `testdata/cpp/`, `testdata/odin/`, `testdata/rust/`.

| File | What it is |
|---|---|
| `ref.log` | Input log (spec §1 format: `UNIL`, version, seed, players, ticks, then 17 bytes per tick) of an offline run: 3600 ticks, 4 players, seed 7, scripted inputs, nothing replaced |
| `ref.trace` | Per-tick checksums of that run, one `"%06d %016x"` line per tick, ticks 1..3600 |
| `ref-1800.snap` | Portable snapshot (state block plus Box3D state) after tick 1800 of the same run |
| `ref.json` | Provenance: when, on what platform and commit, the exact commands, and the final checksum |

The tests:

- **T7:** `unified replay --log ref.log --trace out` must equal `ref.trace`.
- **T8:** `unified resume --in ref-1800.snap --ticks 1800 --trace out` must equal lines 1801–3600 of `ref.trace`.

## Regenerating

Regenerate only on purpose: after a change that legitimately alters the simulation, the checksum, or the log or
snapshot format.

```
python tools/check.py <lang> --regen        # refuses anywhere but macOS ARM64 unless --force
```

It builds (release), then runs exactly:

```
unified sim      --ticks 3600 --players 4 --seed 7 --trace ref.trace --log ref.log
unified snapshot --ticks 1800 --players 4 --seed 7 --out ref-1800.snap
```

Before copying the files here, it self-checks them:

- `replay` of the new `ref.log` must reproduce `ref.trace`.
- `resume` of the new snapshot must reproduce ticks 1801–3600.
- The log header must match the run's seed, players and ticks.

It then writes `ref.json` and runs the selected tests as usual. Commit all four files together. `.gitattributes`
marks `*.log`/`*.snap` as binary and keeps `*.trace` LF, so Windows checkouts compare cleanly.
