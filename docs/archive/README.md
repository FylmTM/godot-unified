# Archive

Results of finished phases that the current code still leans on. Not maintained; code paths they mention no longer
exist.

| File | Why it's kept |
|---|---|
| `PHASE2.md` | Phase 2 verdict for the core (sim + rollback netcode) and the baseline numbers for its benchmarks. |
| `bench/x86/RESULTS.md` | Cross-architecture determinism evidence: x86-64 traces (Rosetta, Linux amd64) byte-identical to ARM64, Box3D's 4- and 8-wide solvers included. |

The full archive (stack research and benchmarks for C++, Rust, C#, Zig, Odin, Bevy and the hosts we didn't choose,
the phase 2 cross-language comparison) is in git at commit 6994822:
`git show 6994822:docs/archive/<path>` (list it with `git ls-tree -r --name-only 6994822 docs/archive`).
