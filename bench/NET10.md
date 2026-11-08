# C#: .NET 8 vs .NET 10 (2026-11-08, Apple M4 Pro)

All C# benchmark projects were retargeted from `net8.0` to `net10.0` (SDK 10.0.403, runtime 10.0.14); .NET 8 was then
uninstalled. The .NET 8 results are kept in `*/results/net8/`. Same machine, same scripts, quiet machine.

## Determinism

The hashes didn't change. Benchmark A gives `d106cbf36b441bbd` in dev, release and NativeAOT on ARM64, and the traces
are byte-identical on x64 under Rosetta: JIT, JIT with AVX2 advertised, and NativeAOT (`x86_64` binaries). The scale
test hashes at 10k, 50k and 100k are unchanged.

## Builds

| | .NET 8 | .NET 10 |
|---|---|---|
| Benchmark A: fresh worktree, dev | 2.01 s | 1.55 s |
| Benchmark A: one-line edit, dev | 0.55 s | 0.52 s |
| Scale 100k: fresh worktree, dev | 2.72 s | 3.08 s |
| Scale 100k: leaf / mid / core edit, dev | 0.88 / 0.96 / 1.61 s | 0.85 / 0.91 / 1.59 s |
| Scale 100k: fresh release | 2.66 s | 2.87 s |

**Watch out for one .NET 10 regression.** With `IsAotCompatible=true`, which turns on the trim/AOT/single-file Roslyn
analyzers, an incremental 100k-line build takes **~16 s instead of ~1.6 s** in both Debug and Release. On .NET 8 the
same analyzers cost almost nothing. Turning off only those three analyzers restores 1.6 s.

Curiously, a *fresh* Release build with the analyzers on is still fast (2.6 s), so the cost appears in incremental
compiles. The cause isn't pinned down; it may be an SDK issue worth reporting. The projects now enable
`IsAotCompatible` only for Release, the usual practice of keeping heavy analyzers out of the inner loop. The dev
numbers above are with that change. A Release incremental build at 100k still costs ~16 s.

Two .NET 10 changes needed script fixes:
- A NativeAOT publish must be self-contained (`SelfContained=true`).
- The launcher script had the runtime version 8 hard-coded.

## Runtime (µs per tick)

| | .NET 8 | .NET 10 | Native best (Rust/C++/Zig/Odin) |
|---|---|---|---|
| Benchmark A, JIT | 360 | **336** | 297–322 |
| Benchmark A, NativeAOT | 342 | **323** | |
| Scale 10k, JIT (first 1000 ticks) | 573 | 515 | |
| Scale 100k, JIT (first 1000 ticks) | 3622 | 3060 | |
| Scale 10k / 50k / 100k, NativeAOT, optimized code (`perf/csharp`) | 316 / 631 / 1294 | **290 / 595 / 1230** | 228–242 / 336–363 / 471–523 |
| Scale 100k, JIT steady state (10,000 ticks), optimized code | ~1295 | 1332 | |

- **.NET 10 is ~5–15% faster** than .NET 8, and on Benchmark A (physics-dominated) C# is now within ~5–10% of the
  native languages.
- **On the generated gameplay code it's still ~2.6× slower than native at 100k.** The cause is the same as on .NET 8:
  RyuJIT turns few branches into conditional selects and doesn't inline small helpers in large methods. .NET 10 emits
  some `fcsel` now (37 in the whole AOT binary, against ~42,000 in the C++ build). Rollback multiplies sim cost, so
  this gap matters for the 1000-entity target.

## Godot + C#

Builds and runs on .NET 10 with only the target framework changed. Godot 4.7.2's `Godot.NET.Sdk` accepts
`net10.0`.

| Godot + C# | .NET 8 | .NET 10 |
|---|---|---|
| Fresh worktree, dev / release | 4.6 / 2.2 s | **2.1 / 2.0 s** |
| Sim edit / view edit, dev | 0.56 / 0.57 s | 0.51 / 0.53 s |
| Startup (warm median) | 729 ms | 664 ms |
| Frame time, mean | 6.5 ms | 3.5 ms |
