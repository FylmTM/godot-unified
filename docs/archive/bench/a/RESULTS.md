# Benchmark A: results (2026-11-07, Apple M4 Pro, 14 cores, 48 GB, macOS)

Same headless sim core (SPEC.md): 300 Box3D bodies, 4 players, 1000 swarm agents with a grid and ray casts,
pointer-free state block, XXH3 per tick, 16-slot snapshot ring. Measured with `scripts/measure.sh`
(hyperfine; 3 runs for fresh builds, 10 for incremental dev, 5 for incremental release, 5 runs of the release binary
for tick speed) with nothing else running.

Toolchains: Rust 1.98.1, Odin dev-2026-11, Zig 0.17.1, Apple clang 21 + CMake 4.4.5 + Ninja 1.13.2, .NET SDK 8.0.133.

## Determinism

**All 11 binaries produce byte-identical 3600-tick traces** (final hash `d106cbf36b441bbd`): Rust, Odin, Zig, C++
and C#, each in dev and release, plus C# NativeAOT. So five compilers and two .NET code generators (RyuJIT and
NativeAOT) give the same f32 results on ARM64 when the spec's rules are followed. **Not yet tested: x64 (Windows).**
That's the cross-architecture half, and it needs the developer's Windows PC or a CI runner.

## Build and run times

"Fresh" = a new worktree copy: local build dirs empty; global caches warm (cargo registry, NuGet packages, zig global
cache); prebuilt Box3D shared through `deps/`. The ecosystem's offline restore step is included (C#: `dotnet
restore`; Rust: `cargo fetch --offline`). "Incr" = a one-line change to the gameplay file, then rebuild.

| | Rust | Odin | Zig | C++ | C# |
|---|---|---|---|---|---|
| Fresh worktree, dev | 5.40 s | **0.84 s** | 4.64 s | 1.45 s | 2.01 s |
| Fresh worktree, release | 3.91 s | 1.97 s | 8.67 s | **1.42 s** | 1.50 s |
| Fresh dev, Box3D from source | 7.27 s | n/a (no C compiler) | 7.27 s | **2.74 s** | n/a (no C compiler) |
| Fresh dev with sccache (warm) | 4.57 s | – | – | **1.00 s** | – |
| Fresh dev, *empty* global cache | – | – | 72 s | – | – |
| Incremental, dev | 0.29 s | 0.42 s | 1.43 s | **0.25 s** | 0.55 s |
| Incremental, release | 0.43 s | 1.59 s | 5.64 s | **0.28 s** | 0.56 s |
| Release speed (µs/tick, median of 5) | 322 | **297** | 310 | 304 | 360 (JIT), 342 (AOT, one run) |
| Box3D glue (lines) | 372 + 56 build.rs | 261 | 27 + ~45 in build.zig | **2** | 127 |
| Sim code (lines, gameplay file) | 468 (159) | 404 (128) | 416 (134) | 364 (127) | 380 (128) |
| Local build dir size | 73 MB | 3 MB | 170 MB | 7 MB | 5 MB |

## What this does and doesn't tell us

- **At this size, every stack is fast.** Every incremental dev build is under 1.5 s, and every fresh worktree under
  9 s. The codebase is about 1k lines plus Box3D, so this measures the toolchains' fixed costs, not scaling with a
  50k-line game.
- **Lean Rust doesn't have a worktree problem; Bevy might.** A fresh worktree is 5.4 s with two small crates.
  sccache barely helps (4.6 s). The 90–180 s estimate in `docs/research/stacks/rust.md` is about Bevy's dependency
  tree, so it belongs to the host choice (benchmark B), not to Rust as a sim language.
- **Odin is the fastest to a first build** (0.84 s dev, no cache to warm), but its release incremental (1.6 s) is a
  full rebuild every time, and the 261 lines of bindings had to be hand-written because `vendor:box3d` was stale.
- **C++ wins nearly every build row** once deps are prebuilt, and needs no glue. Its remaining costs are the ones a
  benchmark can't show: memory-safety bugs and header growth.
- **Zig was the slowest here, against its reputation.**
  - On ARM macOS the self-hosted debug backend produced a binary that wouldn't run, so builds go through LLVM.
  - A release incremental build takes 5.6 s.
  - With an empty global cache, a build takes 72 s (it builds the translate-c tool and compiler-rt first).
  - Its C-from-source story did work smoothly.
- **C# is close to native** for builds (0.55 s incremental with the compiler server warm) and about 12–18% slower
  per tick. Physics dominates the tick in every language (~300 µs), so language speed differences are small.

## Caveats

- Same-path fresh copies let path-keyed caches (sccache) hit, which is a best case for sccache.
- C#'s fresh dev time varied (1.5–2.8 s) depending on whether the compiler server was already warm.
- The Zig binary prints its JSON line without a trailing newline (a minor spec deviation; it doesn't affect results).
- macOS only. Windows numbers (and x64 determinism) still to come.
