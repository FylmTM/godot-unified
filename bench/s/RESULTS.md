# Scale test: results (2026-11-08, Apple M4 Pro, macOS 26.7, quiet machine)

One language-neutral game description (`gen/IR.md`) was generated at three scales. Each scale was emitted as an
idiomatic project in five languages, on top of Benchmark A's sim core:

| Scale | Features | Groups | Systems | Lines: Rust (rustfmt) / Odin / Zig / C++ / C# |
|---|---|---|---|---|
| 10k | 8 | 5 | 34 | 20k / 11k / 16k / 11.5k / 15k |
| 50k | 40 | 7 | 155 | 97k / 50k / 79k / 55k / 73k |
| 100k | 80 | 8 | 324 | 194k / 99k / 157k / 110k / 145k |

Line counts depend on each language's formatter and brace style. Compare languages **by scale (the same game), not by
lines**.

Structure per language (from each emitter's README):
- **Rust:** a core crate, a crate per feature group, a module per feature.
- **Odin:** a core package, a package per group (no import cycles).
- **Zig:** a core module, a module per group in `build.zig`.
- **C++:** a `.h`/`.cpp` per feature, a static library per group (plus an optional unity build).
- **C#:** a core project, an assembly per group.

**Determinism at scale:** all five languages produce identical per-tick hashes at every scale, all agreeing with
the Python reference interpreter. The final hashes after 1000 ticks are `13fa2f2f…` (10k), `101223b3…` (50k) and
`ffd51a02…` (100k).

Measured with `bench/s/measure.sh` (hyperfine; wall-clock medians). "Fresh" = a new worktree copy with empty local
build dirs and warm global caches. Edit points (IR.md §13):
- **leaf:** a constant in a feature nothing depends on
- **mid:** an exported helper that 3–5 features use
- **core:** a field added to the shared `Transform` component that every feature reads

## Dev builds (what agents iterate with)

| | Fresh 10k | Fresh 50k | Fresh 100k | Leaf 100k | Mid 100k | Core 100k | Peak memory 100k |
|---|---|---|---|---|---|---|---|
| Rust | 6.4 s | 8.3 s | 10.9 s | 0.87 s | 1.83 s | 4.42 s | 0.45 GB |
| Odin | **1.0 s** | **1.1 s** | **1.3 s** | 0.84 s | 0.84 s | **0.86 s** | 0.88 GB |
| Zig | 5.6 s | 7.8 s | 11.5 s | 8.31 s | 8.31 s | 8.49 s | 1.04 GB |
| C++ | 1.7 s | 2.2 s | 2.8 s | **0.33 s** | **0.30 s** | 1.91 s | **0.13 GB** |
| C++ (unity build) | 1.6 s | 2.1 s | 2.3 s | – | – | 1.33 s | 0.13 GB |
| C# | 2.8 s | 2.4 s | 2.7 s | 0.88 s | 0.96 s | 1.61 s | 0.18 GB |

Incremental builds across the three scales:

| | Leaf 10k / 50k / 100k | Core 10k / 50k / 100k |
|---|---|---|
| Rust | 0.35 / 0.54 / 0.87 s | 0.79 / 2.48 / 4.42 s |
| Odin | 0.45 / 0.63 / 0.84 s | 0.44 / 0.62 / 0.86 s |
| Zig | 2.00 / 4.64 / 8.31 s | 2.03 / 4.65 / 8.49 s |
| C++ | 0.28 / 0.26 / 0.33 s | 0.67 / 1.25 / 1.91 s |
| C# | 0.67 / 0.81 / 0.88 s | 0.96 / 1.25 / 1.61 s |

## Release builds

| | Fresh 10k | Fresh 50k | Fresh 100k | Peak memory 100k |
|---|---|---|---|---|
| Rust | 5.1 s | 7.5 s | 10.7 s | 0.31 GB |
| Odin | 6.6 s | 38 s | **1.8 min** | 1.36 GB |
| Zig | 10.6 s | 19.5 s | 32 s | 1.65 GB |
| C++ | **1.6 s** | **2.4 s** | **3.2 s** | 0.13 GB |
| C# (JIT; the optimising happens at run time) | 2.4 s | 2.3 s | 2.7 s | 0.18 GB |

## Runtime speed (release, µs per tick, median of 3 × 1000 ticks, ~300 µs of it is physics and swarm)

| | 10k | 50k | 100k |
|---|---|---|---|
| Rust | 256 | 406 | 596 |
| C++ | 265 | 491 | 780 |
| Odin | 310 | 676 | 1174 |
| Zig | 343 | 921 | 1728 |
| C# (JIT, includes warm-up) | 573 | 1687 | 3622 |

**Investigated (`PERF.md`):** most of that spread came from the per-tick hash path, not the gameplay. Serializing
the 1.2 MB state field by field, then XXH3, was written slowly in some emitters:
- C++ and Zig wrote through a writer that aliased its own pointer.
- Odin used four bounds-checked byte stores per u32.
- Rust had two bounds checks per field and no cross-crate inlining.
- Zig's and Odin's standard-library XXH3 is slow on arm64.

The gameplay systems themselves cost about the same in Rust, C++, Zig and Odin (~160–210 µs at 100k). With idiomatic
fixes (hashes unchanged), best µs per tick:

| | 10k | 50k | 100k |
|---|---|---|---|
| Rust (ThinLTO, local writer copy, one unchecked write) | 239 | 349 | 475 |
| C++ (local writer copy) | 236 | 353 | 471 |
| Zig (C xxhash via `zig cc`, local writer) | 228 | 336 | 477 |
| Odin (word stores) | 242 | 363 | 523 |
| C# NativeAOT | 316 | 631 | **1294** |
| C# JIT, first 1000 ticks (steady state at 100k ≈ 1295) | 525 | 1595 | 3221 |

- **The four native languages are equal.** C# (.NET 8) runs this generated gameplay code about 2.7× slower even with
  NativeAOT. RyuJIT doesn't turn branches into conditional selects (0 `fcsel` vs LLVM's 245 in one system), and it
  doesn't inline small helpers in large methods. No JIT setting fixed it. .NET 10 wasn't tested.
- **Odin's release-build problem gets worse with the fast code:** the 100k release build goes from 108 s to 894 s.
- Under rollback, sim cost is multiplied by the number of re-simulated frames, so a 2.7× gap in gameplay code matters
  more here than in a normal game.

## What it shows

- **Odin's dev loop is flat**: every edit is a full rebuild, yet that's under 0.9 s at 100k, and fresh worktrees cost
  about 1 s. The price is release builds: LLVM optimises the whole program as one module on one thread, which takes
  1.8 min at 100k. `-use-separate-modules` gets that to about 2 s but runs about 1.6× slower.
- **C++ is fastest for leaf and mid edits** (≈0.3 s, flat with size) and has the cheapest fresh and release builds.
  The core edit is where headers bite (1.9 s, or 1.3 s with a unity build).
- **Rust scales well for leaf edits** (0.87 s at 100k), but core edits grow with size (4.4 s at 100k). That's partly
  because the group crates depend on each other almost in a straight line, so cargo can't build them in parallel.
  Fresh worktrees cost ~11 s at 100k (without Bevy).
- **Zig rebuilds the whole program on any edit**, about 8.3 s at 100k on macOS. Its incremental mode
  (`-fincremental`) aborts when it loads the Box3D static library on Mach-O, and the fast self-hosted backend isn't
  usable on ARM macOS. On x86-64 Linux, where both work, this would look very different.
- **C# is flat everywhere** (MSBuild's ~0.7 s floor dominates; core 1.6 s at 100k), with a warm compiler server.
  Runtime is the open question: see the investigation above.
