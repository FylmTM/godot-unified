# Stack comparison: Rust, Odin, Zig, C++, C#

Built from `rust.md`, `odin.md`, `zig.md`, `cpp.md` and `csharp.md` (2026-11-07). They all use the same rubric
(`TEMPLATE.md`), and each was written by a separate researcher arguing for its stack's best realistic setup.
**Every build time in them is an estimate.** Nothing has been measured yet; the benchmark at the end fixes that.

## The finding that matters most: the host decides the families

Only one stack has a same-language renderer: **Rust + Bevy**. For the other four, the realistic host is
**Godot**, reached differently by each:

| Stack | Best host | How it's reached | Who maintains the binding |
|---|---|---|---|
| Rust | **Bevy** (same language, no bridge); fallback Godot via gdext | native crate | Bevy (churns ~3×/year) |
| C++ | Godot (GDExtension on a prebuilt engine, or LibGodot) | `godot-cpp`, official | Godot team |
| C# | Godot .NET (Stride as all-C# fallback) | official C# support, shipped by Slay the Spire 2 | Godot team |
| Odin | Godot via GDExtension C API or LibGodot | odin-godot (WIP, targets 4.4, one maintainer) or our own generator | **us**, most likely |
| Zig | Godot via GDExtension C API or LibGodot | godot-zig (stale since 12/2024) or our own generator | **us** |

Everything else (sokol, SDL3 GPU, bgfx, wgpu, raylib) means writing our own renderer, which you ruled out. So
the real choice is among four families:

1. **Rust + Bevy**: one language, the thinnest bridge, the best memory safety. Slow builds per worktree, Bevy churn.
2. **C# + Godot**: the fastest path to a working game; OctoEscape's sim code ports almost 1:1.
3. **C++ + Godot**: every library native, maximum ecosystem; memory-safety risk with agent-written code.
4. **Odin or Zig + Godot**: the fastest builds and the best fit for the state block; we'd own the Godot bindings,
   and the language and its ecosystem are young.

In every Godot family, the sim stays a separate core that Godot only reads (doc 02). That's a thinner bridge than
Unity + Quantum (no codegen, no map baking if levels come from glTF). But it's still two object models, and Godot
brings its `.godot/` import cache per worktree and lightmap baking that only runs in the editor (doc 03).

## Scorecards side by side (each researcher scored their own stack; 5 = best)

| Criterion | Rust | Odin | Zig | C++ | C# |
|---|---|---|---|---|---|
| Clean build | 2 | 4 | 3 | 3 | 4 |
| Incremental build | 3 | **5** | 3 | 4 | 4 |
| Worktree parallelism | 2 | **5** | 4 | 4 | 4 |
| C/C++ interop | 3 | 4 | **5** | **5** | 4 |
| Determinism control | 4 | 3 | 4 | 4 | 3 |
| Arena / snapshot fit | 4 | 4 | **5** | 4 | 4 |
| Safety vs agent bugs | **5** | 3 | 3 | 2 | 4 |
| Reflection / metaprogramming | 3 | 4 | **5** | 3 | **5** |
| Rendering host options | 4 | 2 | 3 | **5** | 4 |
| Physics options | 4 | 4 | 4 | **5** | 4 |
| Netcode / transports | 4 | 3 | 4 | **5** | 4 |
| UI options | 4 | 3 | 3 | **5** | 4 |
| Language stability | **5** | 3 | 1 | **5** | **5** |
| Maturity / long-term support | 4 | 2 | 2 | **5** | **5** |
| Tooling / DX | 4 | 3 | 3 | 3 | 4 |
| AI agent fluency | 4 | 2 | 2 | 4 | **5** |
| Platforms | 4 | 4 | 4 | **5** | **5** |
| **Sum (unweighted, /85)** | 63 | 58 | 58 | 71 | 72 |

My calibration notes, where the self-scores don't line up:
- **Rendering host, Odin 2 vs Zig 3.** Both reach Godot the same way: a binding generator we'd own. I'd score them
  equal (2–3).
- **Incremental build, Odin 5.** Odin has no incremental compilation; every build is a full build. The 5 rests on
  one synthetic benchmark (1M lines in 1.1–1.8 s on an M4 Pro). Plausible at our size, but unmeasured.
- **C# clean/incremental 4s** assume Godot is prebuilt and leave out Godot's per-worktree import step, which the
  other Godot stacks pay too.
- **Rust's build pain is the best documented** (sccache can't cache macro crates, dylibs or the final binary;
  Cargo's lock serializes a shared target dir). The others' build claims are thinner, which flatters them.
- Sources I checked: the Zig doc's claim that Bun moved from Zig to Rust is sourced (The Register, 2026-05-14,
  "rewrite merged").

## Weighted by what you said matters

Weights from your answers: build speed and worktrees, determinism and rendering at ×2; interop, the state-block
fit, safety, physics and agent fluency at ×1.5; the rest at ×1; platforms at ×0.5 (desktop only for now).

| | Rust | Odin | Zig | C++ | C# |
|---|---|---|---|---|---|
| Weighted average (/5) | 3.51 | 3.41 | 3.37 | **4.02** | **4.04** |

This is a conversation starter, not a verdict. Change the weights and the order moves: put "one language, no
bridge" first and Rust + Bevy wins; put build speed and the state-block fit first and Odin catches up; put
ecosystem and maturity first and C++/C# pull further ahead.

## Area by area

| Area | Winner(s) | Why | Runner-up |
|---|---|---|---|
| Build speed, worktrees | **Odin** | No cache needed; a full build is seconds | C# (no native compile), C++ with discipline |
| C library interop | **Zig**, **C++** | Zig's build compiles C/C++ from source; C++ is native | Odin (much of our list is officially vendored) |
| State block and reflection | **Zig** (comptime), **C#** (source generators + Quantum precedent) | The compiler checks layout, the registry is cheap | Odin (RTTI + tags), Rust (bytemuck + derive) |
| Determinism | Rust, Zig, C++ (tie) | No implicit FMA contraction, or one flag set covering everything | Odin and C# have specific traps (Odin `matrix` FMA on arm64 and libm in `core:math`; no spec guarantee for C#) |
| Safety vs agent bugs | **Rust** | Memory errors don't compile | C# (managed) |
| Rendering, physics, net, UI | **C++** | Everything native | C# (official Godot, EOS, FMOD SDKs), Rust (Bevy, Rapier, egui) |
| Stability and maturity | **C++**, **C#** | Standards and big vendors | Rust (language yes, Bevy no) |
| Agent fluency | **C#** | Largest stable corpus | C++, Rust |
| Reusing OctoEscape | **C#** | ~22k lines of Quantum sim code port behind a facade | — (all others rewrite) |
| "Unified": one language, no bridge | **Rust + Bevy** | Sim, view and tools in one Cargo workspace | — (all others go through Godot) |

## Each family in one paragraph

**Rust + Bevy.** The cleanest version of the vision: one language, the compiler enforcing the state block's rules,
safe code, Rapier and egui native. It pays in builds: an estimated 90–180 s clean per worktree with Bevy, a 2–6 s
relink only with dynamic linking, no good cross-worktree cache yet. And it pays in Bevy's churn and in C bindings
we'd write (EOS, LibGodot). Pick it if "unified" and safety are worth slower builds.

**C# + Godot.** The pragmatic pick: fast iteration with no native builds, the best agent fluency, official SDKs, a
proven Godot host, and the only stack where your Quantum code moves over largely intact. Its one technical
question is the big one: **no published result shows .NET floats identical across x64 and ARM64.** That takes a
day to test on your Mac plus your Windows PC, and it decides the family. Pick it if the test passes and a Godot
bridge is acceptable.

**C++ + Godot.** The maximum-ecosystem pick: every library native, Godot first-class, Jolt and Box3D determinism
proven with exactly this toolchain, the best console path. It pays in agent-written memory bugs that compile
cleanly (caught only by sanitizers and sync-test at runtime), in build-hygiene discipline, and in macro-based
reflection until C++26 reflection reaches clang (~2027).

**Odin + Godot** (and Zig). The "builds don't matter anymore" pick: full rebuilds in seconds, nothing to cache per
worktree, the most natural arena language, rich RTTI. It pays in owning the Godot bindings (a generator from
Godot's `extension_api.json`, which agents could build), in a small ecosystem and core team, low agent fluency,
and a few determinism traps that need lints. **Zig vs Odin:** Zig has the better C build system and comptime, but
it's pre-1.0 with silent breaks every release, and on ARM Macs it still compiles through LLVM (an estimated 2–8 s
incremental), which removes most of its build-speed advantage on your machine. Today Odin is the stronger of the
two for this project.

## Measured: benchmark A (2026-11-07, `bench/a/RESULTS.md`)

The same headless sim core (300 Box3D bodies, 1000 swarm agents, pointer-free block, per-tick XXH3) in all five
languages on the M4 Pro:
- **Determinism:** all five languages produce byte-identical 3600-tick traces, in dev and release, and C# with both
  the JIT and NativeAOT. This weakens the biggest risk for C# (on ARM64; x64 is still to test).
- **Builds:**

  | | Rust | Odin | Zig | C++ | C# |
  |---|---|---|---|---|---|
  | Fresh worktree, dev | 5.4 s | 0.84 s | 4.6 s | 1.45 s | 2.0 s |
  | One-line change, dev | 0.29 s | 0.42 s | 1.43 s | 0.25 s | 0.55 s |
  | One-line change, release | 0.43 s | 1.6 s | 5.6 s | 0.28 s | 0.56 s |

  Every stack is fast at this size. The self-scored estimates were too pessimistic for lean Rust (the 90–180 s
  figure is Bevy's, i.e. the host) and too optimistic for Zig on macOS.
- **Speed:** within about 8% across the native languages (297–322 µs/tick; physics dominates). C# is 12–18% slower.
- **Glue to call one C library:** C++ 2 lines, Zig 27 (generated), C# 127, Odin 261 (the vendored binding was stale),
  Rust 428.

Score changes this justifies: Rust clean build 2 → 4 and worktrees 2 → 4 *for the sim* (Bevy stays untested); Zig
incremental 3 → 2 on macOS; C# determinism 3 → 4 (pending x64).

## Measured: x86-64, hosts, scale (2026-11-08)

Details in `bench/x86/RESULTS.md`, `bench/b/RESULTS.md`, `bench/s/RESULTS.md` and `bench/s/PERF.md`.

- **Cross-architecture determinism (emulated):** all five languages, in dev/release (and C# JIT/AOT), match ARM64
  bit for bit on x86-64 macOS (Rosetta, with and without AVX2) and x86-64 Linux. Still open: real x86 hardware,
  AVX-512, and Windows (MSVC CRT, win-x64 .NET).
- **Hosts:**

  | | Fresh worktree (dev) | Edit (sim / view) | Build dir | Headless screenshots |
  |---|---|---|---|---|
  | Bevy + Rust | 2.0 min | 1.5 / 1.4 s | 5.9 GB | yes |
  | Godot + C++ | 7.1 s | 0.3 / 0.9 s | ~125 MB | window flashes |
  | Godot + C# | 4.6 s | 0.6 / 0.6 s | <1 MB | window flashes |
  | Godot + Odin | 1.4 s | 0.4 / 0.5 s | 3 MB | window flashes |

  | Godot + Rust (gdext) | 24 s | 0.6 / 0.5 s | 1.5 GB | window flashes |

  Odin (and by extension Zig) reaches Godot through a 695-line binding generator we own (1–2 weeks to full coverage,
  then 2–4 days a year). Godot + Rust keeps Rust's safety at a fifth of Bevy's fresh-build cost. The remaining cost is
  compiling gdext's generated bindings (10 s with a trimmed fork).
- **Scale, 100k-line game, same in all five languages, bit-identical:**

  | | Fresh dev | Leaf edit | Core edit | Fresh release | Runtime (best idiomatic) |
  |---|---|---|---|---|---|
  | Rust | 10.9 s | 0.87 s | 4.42 s | 10.7 s | 475 µs |
  | Odin | 1.3 s | 0.84 s | 0.86 s | 1.8 min (15 min with fast hashing code) | 523 µs |
  | Zig | 11.5 s | 8.3 s | 8.5 s | 32 s | 477 µs |
  | C++ | 2.8 s | 0.33 s | 1.9 s (1.3 unity) | 3.2 s | 471 µs |
  | C# (.NET 8) | 2.7 s | 0.88 s | 1.6 s | 2.7 s | 1294 µs (AOT) |

What the measurements changed:
- **Rust:** its worktree problem is Bevy's, not the language's. A lean Rust sim scales fine except for core edits.
- **Odin:** the "no renderer" weakness is now a bounded cost. A new weakness is release builds at scale.
- **Zig:** on macOS it loses its claimed build-speed advantage entirely (no incremental build, no fast backend on ARM).
- **C#:** determinism concern mostly retired (still needs Windows), but a measured ~2.7× runtime penalty in gameplay
  code, which rollback multiplies.
- **C++:** best or near-best on every build and runtime number. Its open risk, memory bugs in agent-written code,
  isn't something these benchmarks measure.

## Measured: agent productivity (2026-11-08, `bench/c/RESULTS.md`)

The same feature task (grab and throw: state, hash, new Box3D calls, scenarios) and the same bug hunt, with the same
prompt, 2 runs per language:
- **Every run in every language passed every check** (C1 18/18, C2 9/9), with 0–4 failed builds per run.
- **C1 mean tokens:** Odin 153k, Zig 159k, Rust 196k, C++ 199k, C# 210k. Two harness problems (a fragile physics
  check, a .NET build hang) and n = 2 make these differences inconclusive. The variation within a language is as large
  as between languages.
- **The predicted fluency penalty for Odin and Zig didn't show.** With an existing codebase to follow, agents wrote
  them as cheaply as Rust, C++ or C#.
- **C2 was too easy to discriminate** (all bugs found by reading in 2–3.5 min). The planted edge bug did show the
  safety difference: Rust, Odin and C# fail loudly at the exact index; Zig release dies with SIGBUS and no message;
  C++ silently corrupts memory and produces a wrong hash with exit 0.

## Measured: C# on .NET 10 (2026-11-08, `bench/NET10.md`)

- Hashes unchanged on ARM64 and x64 (Rosetta, JIT ± AVX2, NativeAOT).
- About 5–15% faster than .NET 8. Benchmark A NativeAOT is 323 µs/tick, within ~5–10% of native. The generated 100k
  gameplay is still ~2.6× slower than native (1230 µs AOT vs 471–523 µs).
- Dev builds are unchanged once the trim/AOT analyzers run only in Release. With them on, incremental builds at 100k
  regress from 1.6 s to ~16 s (cause not pinned down).
- Godot + C# works on .NET 10: fresh worktree 2.1 s, edits ~0.5 s, startup 664 ms.

## What would decide it: measure, don't estimate

**Benchmark A: the same headless sim core in all five languages** (needs Odin, Zig and CMake installed):
- the same scenario everywhere: a pointer-free state block, 1000 swarm agents, 300 Box3D bodies (Box3D is plain C,
  so every language uses the *same* physics, which keeps it fair), xxHash checksums, sync-test re-simulating 8 frames
- measured on the M4 Pro: clean build, incremental build after a one-line gameplay change, a fresh git worktree
  (cold, and with each stack's best cache), ticks per second, and lines of binding glue
- determinism: the per-tick hash trace from your Mac compared with your Windows PC. For C#, this is the RyuJIT
  cross-architecture test.

**Benchmark B: the host**, on the same Blender-exported chamber with a toon look:
- Bevy (for Rust) vs Godot (for everyone else), headless and in four windows
- measured: startup time, rebuild-to-pixels time, first-frame shader hitches, and how close the look gets

A tells us which language feels best day to day and whether C# floats survive crossplay. B tells us whether Godot's
bridge and editor-shaped workflow are acceptable, or whether Bevy's single-language world is worth its cost.
