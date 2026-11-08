# Work

Updated 2026-11-08. Language: **Odin**. Host: **Godot via GDExtension**.

## Decided

- **Generics:** libraries are generic over each game's types with compile-time parametric polymorphism
  (`net.Client(My_State, My_Input)`).
- **v1 covers all four areas** (core + physics + netcode, replays and dev tools, Godot view layer, CLI and skills),
  at least minimally. Until every piece is proven end to end, demo and test games live **inside this repo**;
  OctoEscape migrates only after that.
- **State model: (c) hybrid.** Games own typed fixed tables; `unified` discovers them by Odin RTTI over the game's
  `State`, so the inspector, desync diff, set-by-path, serialization and dumps need no per-component code. No code
  generation. Evidence: `experiments/state-models/REPORT.md` (branch `claude/state-models-proto-840d93`, not merged).
  Open details go into the core module spec: how tables are detected, whether `using` means "component", optional
  components, cross-table helpers.
- **Consumption:** each game pins `unified` as a git submodule. A committed launcher (`./unified`) builds the CLI
  from that same submodule (cached by source hash), so library and CLI always match. The CLI checks the pinned Odin
  and Godot versions.
- **Config:** `unified.cfg` in Godot's ConfigFile syntax (the same as `project.godot`), read with Odin's
  `core:encoding/ini`. No TOML. It holds only what the CLI needs before building or running (name, tests,
  benchmarks and budgets, CI platforms, extra collections). Runtime settings live in game code and data.
- **Game repo layout** (conventions, not config):
  ```
  /             Godot project root (res://) and Odin workspace root
  project.godot, unified.cfg
  unified/      submodule; ships its own .gdignore
  simulation/   game sim code (Odin); .gdignore created by `unified init`
  game/         everything Godot: scenes, scripts, assets
  .uni/         all artifacts (CLI cache, Box3D builds, game library, F3 feedback, test output), hidden, git-ignored
  .godot/       Godot import cache
  ```
  `unified check` fails if Godot imported anything outside `game/`. To verify in the GDExtension spike: the library
  loads and exports from hidden `res://.uni/bin/`.

- **Godot route: GDExtension.** LibGodot stays a later option (our init runs unchanged under a LibGodot host).
- **View binding: (C) hybrid.**
  - A `.tscn` scene per rich entity kind, with a `SimView` root.
  - MultiMesh bulk views (`SimBulkView`) for 1000+ entities.
  - Rollback-aware view logic in a host-independent Odin package, `unified:view`: interpolation, error smoothing,
    pooling, event confirm/cancel.
  - Views keyed by deterministic spawn keys; events routed to their entity's view.
- **Bindings register Godot classes from the start**, so `SimView` and `SimBulkView` are visible in the editor and
  GDScript view scripts can talk to the sim (like Quantum view scripts in Unity). Budget: ~1–2 weeks of binding work.
- **View logic:** GDScript by default; Odin for anything performance-critical or shared across games (e.g. the
  tentacle rig).

## Done

- Odin-only cleanup merged: `src/` collection, `tests/` packages, `tools/dev.py`, OLS and odinfmt config, Odin-only
  CI, Box3D with the static C runtime on Windows, null-handle and `core:math` fixes.
- Docs reviewed; the other stacks archived in `docs/archive/`.
- Upstream Odin XXH3 streaming fix drafted in `~/work/personal/odin` (branch `fix-xxh3-streaming-tail`,
  `PR_DRAFT.md`). It's for the developer to submit.

## In discussion (this thread)

1. **Godot follow-ups:** how entity kinds and levels are authored (code/data-first recommended,
   `docs/research/11-view-binding.md`), default interpolation and smoothing per kind, the 1000-scene-view benchmark.
2. **Dev tooling and AI:** the `unified` CLI in Odin, text-first Godot work, our own skills in `.claude/skills`
   (`12-ai-tooling.md`).
3. **Testing strategy:** every layer, F3 feedback, frame dumps, replays, smoke tests, CI benchmarks.

## Next (after sign-offs)

- GDExtension spike (1 day, includes class registration groundwork): sim and netcode on our own thread with p99 jitter under 1 ms, the editor opens the
  project, game-library hot reload under 1 s, a gamepad on macOS, headless hashes in CI.
- Module specs for the agreed architecture, each signed off before building.
- The `unified` CLI (replaces `tools/*.py`).
- Box3D fork: public load-from-bytes API, clearing stale bytes, and a full test suite for our use of Box3D.
- A test scenario that forces explosions and barrel respawns inside rollback windows.

## Deferred

- Windows ARM64, Linux ARM64; real Windows hardware beyond CI.
- Box3D's AVX2 path (compiled out today) as a separate CI job.
