# Benchmark B: results (2026-11-08, Apple M4 Pro, macOS 26.7, quiet machine)

Four hosts draw the same content: a room exported from Blender, plus the unchanged Benchmark A sim
(300 props, 4 players, 1000 agents) at 60 Hz with interpolation. They all use the same toon look, support 4 OS windows
on one sim, and have a screenshot mode. Measured with `bench/b/measure.sh` (hyperfine). A fresh worktree means
Benchmark A's sources plus the variant's sources copied to a new tree, then the offline fetch and the build.

All four variants reach Benchmark A's sim hash `d106cbf36b441bbd` at tick 3600. Each was verified by its implementer;
the measured runs below run in real time, so they stop at different ticks.

## Builds

| | Fresh worktree, dev | Fresh, release | Sim edit, dev | View edit, dev | View edit, release | Peak memory (fresh dev) | Build dir |
|---|---|---|---|---|---|---|---|
| **Bevy 0.20.1 + Rust** | **2.0 min** | 1.5 min | 1.48 s | 1.43 s | 3.92 s | 3.6 GB | 5.9 GB |
| **Godot 4.7.2 + C++** (godot-cpp 10, trimmed to the classes used) | 7.1 s | 7.0 s | **0.29 s** | 0.91 s | 1.01 s | 0.17 GB | 89 MB + 34 MB godot-cpp |
| **Godot 4.7.2 + C#** (.NET 8) | 4.6 s | 2.2 s | 0.56 s | 0.57 s | **0.62 s** | 0.18 GB | <1 MB |
| **Godot 4.7.2 + Odin** (own binding generator) | **1.35 s** | 2.8 s | 0.44 s | **0.45 s** | 2.02 s | 0.44 GB | 3 MB |

**Godot 4.7.2 + Rust (godot-rust/gdext 0.5.5, `api-4-7` + `lazy-function-tables`)**, added later, measured on a quiet
machine:

| | Fresh worktree, dev | Fresh, release | Sim edit, dev | View edit, dev | View edit, release | Peak memory (fresh dev) | Build dir |
|---|---|---|---|---|---|---|---|
| Godot + Rust | 24.0 s | 35.9 s | 0.63 s | 0.53 s | 0.79 s | 3.5 GB | 0.8 GB dev + 0.7 GB release |

Compiling gdext's generated bindings (`godot-core`) dominates its fresh builds. A patched codegen that keeps only the
used classes gave a 10.1 s fresh dev build at 1.0 GB, but that's a fork to maintain, so it isn't the default. Edits are
as fast as the other Godot variants. Fresh builds are about 5× faster than Bevy and about 3–17× slower than the other
Godot variants. Startup 608 ms, frame 3.4 ms; view 501 Rust + 57 shader lines, bridge 128, 4 `unsafe` sites.

## Runtime (release, 1600×900, one window, 5 runs × 600 frames)

| | Startup to first frame (warm, median) | Frame time, mean | Notes |
|---|---|---|---|
| Bevy | **424 ms** | 8.0 ms | About 1.5 ms of main-thread CPU per frame; the first run after a build takes ~2 s. Truly headless screenshots. |
| Godot + C++ | 603 ms | 8.3 ms | |
| Godot + C# | 729 ms | **6.5 ms** | Zero garbage collections over 6000 frames. |
| Godot + Odin | 610 ms | 8.3 ms | About 1.8 ms CPU per frame. |

Frame times around 8.3 ms are the display's 120 Hz cap (vsync couldn't be fully disabled on macOS in every host). So
the frame numbers show that all four are comfortably GPU-light at this content, not how they'd rank under load.

## View layer size and how it reaches the host

| | Bridge (sim → view) | View code | Binding cost |
|---|---|---|---|
| Bevy | 98 | 672 Rust + 102 WESL shader | none, same language |
| Godot + C++ | 131 | 457 C++ + 57 shader | official godot-cpp |
| Godot + C# | 58 | 418 C# + 93 shader | official, part of Godot .NET |
| Godot + Odin | inside the view code (+ 94 lines of binding runtime glue) | 691 Odin (incl. shader) | 695-line generator → 18.5k lines for 42 classes (141k for all 1037 classes; type-checks in 0.24 s) |

## Findings

- **The host decides worktree cost, and Bevy is the expensive one.** A fresh worktree takes 2 minutes and 6 GB of
  disk, against 1.4–7 s and at most 125 MB for the Godot variants. Once a worktree is warm, Bevy's edits (≈1.5 s) are
  fine, but agents in fresh worktrees pay minutes each time.
- **Godot's import step doesn't apply here.** Every Godot variant loads the glTF at runtime and needs no `.godot/`
  import pass, so a fresh worktree has no editor-shaped cost. (godot-cpp needs one config line written by its build
  script, because `--import` crashes on exit when an extension registers classes.)
- **Odin + Godot works, at a known cost.** The bindings are ours to generate and maintain: about 1–2 weeks to reach
  godot-cpp's coverage, then 2–4 days a year. Object lifetimes are manual (a missed release leaked 822 objects until it
  was fixed), so a lifetime-safe wrapper would be part of that work.
- **Look parity:** all four reach the same family of toon look (bands, tinted shadows, rim, shadows, SSAO, bloom,
  outlines). Bevy's toon shading meant copying its internal lighting loop into our shader, and 0.20's switch to the
  WESL shader format broke most examples. Godot's `light()` hook made the shader shorter.
- **Screenshots for agents and CI:** Bevy renders truly headless (no window). The Godot variants have to show or flash
  a window, because Godot's `--headless` mode doesn't render.

## Caveats

- Informal numbers from the implementers (under load) are in each variant's README. This file has the quiet-machine
  measurements only.
- Single content scale. A large level or many materials would stress shader compilation, which caused 1–3 s hitches on
  first use in the Godot variants and about 2 s on Bevy's first run.
