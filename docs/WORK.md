# Work

Updated 2026-11-09. Language: **Odin**. Host: **Godot via GDExtension**.

## Phases

1. **Physics rollback spike:** done. The Box3D fork is bit-exact under rollback and across ARM64/x64.
2. **Core prototype** (sim + netcode, headless): done (`archive/PHASE2.md`). Odin chosen (final sign-off pending).
3. **Architecture and Godot integration:** now. Design decisions below, spikes in progress, then module specs.
4. **The library for real:** built from the signed-off specs, with a demo game in this repo.
5. **The OctoEscape slice.**

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

- **CLI in Odin**, replacing every `tools/*.py` script (migrated into subcommands, then deleted). `--json` output
  and a time budget on every command.
- **Skills ship as a Claude Code plugin inside the `unified` repo** (`.claude-plugin/marketplace.json`,
  `skills/<name>/SKILL.md`). `unified init` commits `.claude/settings.json` in the game repo
  (`extraKnownMarketplaces` with a `directory` source at `./unified`, plus `enabledPlugins`). Skills load in place,
  so they always match the library. The `unified` repo uses the same mechanism with path `./`. To verify: the relative
  path works.
- **Live-game tooling split:**
  - Anything that affects the sim goes through typed control-socket commands, recorded as tick-stamped debug commands
    (replayable; generic set-by-path via reflection).
  - View-side inspection uses a dev-only GDScript eval that can't touch sim state.
- **No mandatory Godot editor** (target). The headless-Godot investigation decides whether an editor bridge is ever
  needed.

- **Testing layers**, each run with `unified test <layer>` and a time budget:
  - **L0 module:** `odin test` per package, plus a Box3D suite (every call we use, exact save/restore,
    cross-platform golden traces, old replays still play after an upgrade). Under 3 s.
  - **L1 sim:** scenarios asserting by reflection path, sync-test always on, fuzzing with shrinking. Under 10 s.
  - **L2 netcode:** in-process sessions on a **virtual clock** with the seeded network simulator. Under 10 s.
  - **L3 multi-instance:** real UDP processes, plus headless Godot game smoke tests.
  - **L4 cross-platform:** committed reference traces and snapshots, replayed in CI.
  - **View logic** (`unified:view`) is tested in Odin at L1 speed.
- **Golden screenshots in CI from the start**, tolerance-based, using whatever the headless-Godot investigation
  proves renders in CI.
- **F3 captures everything cheap:** screenshot, snapshot, input log, frame dump, view state (scene tree and
  view-side values), net stats, note, build info. A recording is snapshot plus input log, replayed deterministically.
- **Dev UI is immediate-mode**, chosen between microui and Dear ImGui by a spike.

## Done

- Odin-only cleanup merged: `src/` collection, `tests/` packages, `tools/dev.py`, OLS and odinfmt config, Odin-only
  CI (green on Linux and Windows, run 42519083182), Box3D with the static C runtime on Windows, null-handle and `core:math` fixes.
- Docs reviewed; the other stacks archived in `docs/archive/`.
- Upstream Odin XXH3 streaming fix: odin-lang/Odin#8257 is open, from `FylmTM/Odin:fix-xxh3-streaming-tail`. Its CI
  waits for a maintainer to approve workflows.

## In discussion (this thread)

1. **Godot follow-ups:** how entity kinds and levels are authored (code/data-first recommended,
   `docs/research/11-view-binding.md`), default interpolation and smoothing per kind, the 1000-scene-view benchmark.
2. **Dev tooling and AI:** CLI command set and control-protocol details (spec to come); headless Godot investigation
   pending.
3. **Testing strategy:** layers decided; the testing spec is to come.

## In progress (sessions)

- **GDExtension spike** (1 day, includes class registration groundwork): sim and netcode on our own thread with p99
  jitter under 1 ms, the editor opens the project, game-library hot reload under 1 s, a gamepad on macOS, headless
  hashes in CI.
- **Dev UI spike:** microui (Odin vendor) vs Dear ImGui (Odin bindings plus our own Godot backend, or `imgui-godot`):
  integration effort, dependency cost, quality, performance.
- **Headless Godot investigation** (also: what renders in CI for golden screenshots): cold/warm `--import`, headless
  scene edits via `--script`, screenshots without an editor, editor open while agents edit (reload dialog), 5
  worktrees in parallel.

## Next (after sign-offs)

- After the spikes: move the local, untracked `bench/` (12 GB of old benchmark sources) to
  `~/work/personal/unified-bench` and drop its `.gitignore` line.
- Module specs for the agreed architecture, each signed off before building.
- The `unified` CLI (replaces `tools/*.py`).
- Box3D fork: public load-from-bytes API, clearing stale bytes, and a full test suite for our use of Box3D.
- A test scenario that forces explosions and barrel respawns inside rollback windows.

## Deferred

- Windows ARM64, Linux ARM64; real Windows hardware beyond CI.
- Box3D's AVX2 path (compiled out today) as a separate CI job.
