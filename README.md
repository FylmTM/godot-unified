# unified

A purpose-built core for **cooperative games with deterministic rollback netcode**, written in **Odin**, with
**Godot** (through GDExtension) as the host for rendering, audio, UI and the editor; rendering is never written from
scratch. It gives a game a fixed-tick deterministic sim, **Box3D** physics through
[unified-box3d](https://github.com/FylmTM/unified-box3d) (our Odin port, which saves and restores the world),
snapshots, checksums, sync-test and replays, and an input relay with prediction, rollback and late join, plus a
headless CLI and a Godot host. Code-first, built for AI agents, with fast iteration loops. Three games live
here: `games/survivor/` (a co-op survivor, the test game), `games/friendslop/` (a co-op physics sandbox) and
`games/drift/` (a co-op 2D ship arena, the 2D test game: 2D views, physics locked to a plane, a 2D level). Larger
3D co-op games follow, the first migrated later from the developer's current Unity game.

## Why

- **Unity is the bottleneck:** Editor refresh and domain reloads, crashes, dialogs that block tools, only one agent
  at a time can use the Editor, and testing co-op needs a build or multiplayer play mode.
- **Deterministic netcode without the glue:** the commercial SDK used today is great (determinism, replays,
  snapshots, headless tests), but the Unity world and the sim world are glued by a bridge, schema codegen, map baking,
  an asset DB export and physics separate from Unity's, plus a commercial service dependency.
- **Code-first, not Editor-first:** the developer never really uses the Editor. Levels come from code, art from
  Blender scripts, everything is driven from the CLI; dev tools live inside the game.

## Requirements

- **Scope:** hobby time but ambitious (agents do most of the work); features when needed, the core architecture
  designed up front; for the developer now, maybe open source later.
- **Platforms:** Steam on Windows x64, macOS ARM64 and Linux / Steam Deck. Consoles not now.
- **Crossplay macOS ARM64 ↔ Windows x64**, so determinism holds bit for bit across architectures.
- **Scale:** 2–4 players, 64 Hz (a per-game power of two), 1000+ entities, full rigid-body physics inside rollback.
- **Simulation:** f32 with a deterministic discipline (fixed point was rejected); single-threaded, parallel only
  where measurements demand it.
- **Netcode:** the host runs an input relay that stamps each tick's official inputs, so a laggy player never stalls
  the others (a peer-to-peer mesh that waits for every peer was rejected); late join from a snapshot, and a dropped
  player rejoins as a late joiner. No backend.
- **Transports** (pluggable): in-process loopback, direct UDP / LAN, and Epic Online Services (lobbies by code, P2P
  with Epic's relays as fallback). Steam later.
- **Co-op testing:** N clients per process over any transport, views on or off; headless loopback with a network
  simulator is the workhorse for tests, agents and CI.
- **Tests:** headless sim tests; replays as exact regression tests within a build, scenario tests across builds;
  per-game end-to-end suites; reference runs, regenerated on any machine, that every platform reproduces bit for bit
  (CI on Linux x64 and arm64, Windows x64 and macOS ARM64 is the cross-check).
- **Dev tools in the game:** entity picker and inspector, timeline scrub, network simulator panel with desync diffs,
  tuning sliders that write back to text files, F3 feedback, free camera, perf overlay; a level editor eventually.
- **Agent API** in the running game: query and edit state, step ticks, inject input per player, snapshots, replays,
  screenshots, scripted scenarios.
- **Gameplay code:** plain functions over typed queries, minimal magic; keep design options open.
- **Hot reload:** configs, shaders and probably UI; code reload only if it costs nothing else (fast compiles matter
  more, and agents work in parallel worktrees).
- **Levels:** friendslop's level is a Godot scene exported to a `.level` file the sim loads; how entity kinds and
  levels are authored in general is open
  ([#38](https://github.com/FylmTM/unified/issues/38)).
- **Content:** nothing ported from Unity's third-party packs; rebuilt in code or taken from what Godot provides.
- **Characters, animation, audio:** rigs are view-only and procedural (physically grabbing things is worth trying);
  prefer what the host offers and avoid licence costs.
- **UI:** game UI in Godot (GDScript allowed in the view layer); dev tools in the game; immediate-mode or reactive.
- **Version control:** git + LFS.

## How it works

All simulation state lives in one contiguous, pointer-free block (handles, not pointers). That makes a snapshot a
memcpy, a checksum a hash of the block, late join a transfer of the block, and it enables rewind / scrub,
state-keeping hot reload, and a **sync-test mode** that rolls back and re-simulates N frames every frame in single
player, comparing checksums. That mode is what makes "works in single player ⇒ works online" a property we can
check. Physics state lives in Box3D and is saved, restored and hashed alongside the block. The view reads simulation
state (predicted frames for motion, verified frames for scores, events for effects) and never writes it; player
input is the only way in.

A game is a deterministic sim package (its state, input and tick) plus a Godot project; the library supplies the
harness, physics, netcode, the headless CLI and the Godot host. [`src/README.md`](src/README.md) is how the core
works inside.

## Getting started

Toolchain (macOS ARM64, Linux x64 or Windows x64):

- **Odin** at the release and commit `pins.cfg` pins, on PATH (macOS: `brew install odin`). The CLI refuses another.
- What Odin needs anyway: **clang** on macOS and Linux; on Windows, Visual Studio Build Tools (its linker and the
  Windows SDK). Nothing in the repo is C or C++.
- **git** and **curl** (macOS, Windows 10+ and Linux ship curl).
- **Editor:** VS Code with the OLS extension picks up `ols.json` (the `unified` and `box3d` collections, the strict
  checker flags, format on save with `odinfmt.json`).

Everything else (Godot, odinfmt, Box3D, the EOS SDK) the CLI fetches or builds from `pins.cfg`. A local
Godot, EOS SDK or unified-box3d checkout can stand in through `UNIFIED_GODOT`, `UNIFIED_EOS_SDK` and `UNIFIED_BOX3D`
in a git-ignored `.env` ([`src/cli/SPEC.md`](src/cli/SPEC.md)). Then, from the repo root (`uni.cmd` on Windows):

```
./uni help                # every command (the first run builds the CLI, in about a second)
./uni test                # build and run every test package
./uni run survivor        # play it (builds its extension the first time)
./uni verify              # everything CI runs
./uni init ../mygame      # a new game repo, with unified as its submodule
```

A step-by-step guide to setting up and making a tiny game is planned
([#21](https://github.com/FylmTM/unified/issues/21)).

## Where next

- [`AGENTS.md`](AGENTS.md): roles, rules and workflow for working on unified.
- The [board](https://github.com/users/FylmTM/projects/2): current and upcoming work.
- `SPEC.md` next to each module (`src/<pkg>/SPEC.md`) and game (`games/<game>/SPEC.md`): what it does and how.
- [`tools/README.md`](tools/README.md): this repo's CLI, `uni`, and its private commands.
- [`docs/`](docs/): decisions so far (`WORK.md`), online setup (`EOS.md`), open research
  (`research/`) and phase 2 results (`archive/`).
