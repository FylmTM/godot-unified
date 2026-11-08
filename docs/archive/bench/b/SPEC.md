# Benchmark B: the host (Bevy vs Godot) on the same content

Benchmark A compared languages on a headless sim. B compares **hosts**: the view layer that draws the sim, opens
windows, takes screenshots, and sets build and startup cost. Each variant draws the same content with the same look,
driven by its language's **unchanged Benchmark A sim** (used as a library, so hashes stay identical).

| Variant | Host | Sim (from `bench/a`) | How the host is reached |
|---|---|---|---|
| `bevy-rust` | Bevy 0.20 (pinned) | Rust `sim` crate | native crate |
| `godot-cpp` | Godot 4.x | C++ `sim` library | GDExtension via `godot-cpp` |
| `godot-csharp` | Godot 4.x .NET | C# `Sim` assembly | Godot's official C# support |
| `godot-odin` | Godot 4.x | Odin `sim` package | GDExtension C API with bindings we write or generate (the path Odin and Zig share) |

Directory: `bench/b/<variant>/`. Shared assets: `bench/b/assets/`. Touch nothing outside your directory except
where told.

## Content

- **Static level:** a room from the developer's current game, exported from Blender with headless Blender
  (`blender` on PATH) to `bench/b/assets/start.glb` (glTF binary, Y-up, materials as base colours, Blender custom
  properties exported as glTF extras). Whoever needs it first exports it with a script at
  `bench/b/assets/export.py` so the export can be reproduced.
- **Dynamic content from the sim**, stepped at a fixed 60 Hz, drawn with interpolation between the previous and
  current tick:
  - 300 props (even ids cubes 1 m, odd spheres 1 m diameter)
  - 4 players (capsules, radius 0.5, height 2, in four distinct player colours)
  - 1000 agents (small instanced meshes, e.g. 0.4 m cones or cubes)

  Place the sim's arena (100 × 100 m, centred at the origin) where it fits the room. Exact alignment doesn't matter.
- **Camera:** a third-person camera following a player, about 10 m back and 6 m up, looking at the player.

## Look (stylized, matching the current game)

- Toon shading: 2–3 diffuse bands, tinted shadows, a rim light
- one directional light with shadows, hemisphere/ambient light
- SSAO if the host has it, bloom, outlines (inverted hull or post-process)

Reference: a Unity screenshot of the room, copied to `bench/b/assets/unity-ref.png`. Aim for "same family of look", not
a pixel match. Note which features you got, how, and what you couldn't.

## Modes (CLI flags, identical across variants)

- default: one window, 1600×900, following player 0.
- `--windows 4`: four OS windows (or four viewports in one window, if the host can't do multiple OS windows from
  one process; say which), each following a different player, all fed by the **same** sim instance.
- `--screenshot PATH --frames N`: render N frames (default 120), save the last frame as PNG, exit 0. Hidden or
  offscreen window if the host allows it, so agents and CI can use it.
- `--frames N` without screenshot: run N frames, print one JSON line and exit:
  `{"variant":...,"startup_ms":<process start to first presented frame>,"frame_ms_mean":...,"frame_ms_p99":...,"sim_hash":"<final sim hash at the last tick>"}`.
  Frame time is CPU frame time; vsync off if possible.

## Build interface

`./build.sh dev` and `./build.sh release` produce something runnable as `./run.sh [flags]` (the build mode is chosen
with `BUILD=dev|release`, default dev). `./fetch.sh` downloads anything needed (crates, godot-cpp, NuGet), so
`build.sh` works offline afterwards. For Godot variants, the Godot binary comes from the developer's install (`godot`
on PATH or `/Applications/Godot*.app`). Nothing Godot-specific may require opening the editor: projects are text
(`project.godot`, `.tscn` written by hand or by code) and run from the CLI. Document any import step Godot needs (the
`.godot/` import cache) and its time, because it hits every fresh worktree.

## The gameplay edit and the view edit

Two marker lines, for incremental-build measurement:
- `BENCH_EDIT_MARKER` stays in the sim's gameplay file from Benchmark A. Don't move it; the sim is built as part of
  the variant.
- `VIEW_EDIT_MARKER` goes in the view code (e.g. a constant scaling the camera distance by 1.0, reported in the JSON
  line as `"view_edit"`).

## README.md in your directory

Versions; how the sim is linked; the size of the view layer and of the bridge (LOC); which look features worked and
how; multi-window support; the headless/screenshot story; fresh and incremental build times observed informally;
papercuts; and a screenshot at `bench/b/<variant>/shot.png` from `--screenshot`.
