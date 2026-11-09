# unified: context

`unified` is a purpose-built core for cooperative games with deterministic rollback netcode
(deterministic sim, input relay, prediction and rollback), code-first, AI-agent-first, with fast iteration loops.
It is written in **Odin**, with **Godot** as the host for rendering, audio, UI and the editor. Rendering is never
written from scratch.

The first real game will be a 3D co-op game, migrated later from the developer's current Unity game.

## Why

- Unity is the bottleneck: Editor refresh and domain reloads, crashes, dialogs that block tools, only one agent at a
  time can use the Editor, and testing co-op needs a build or multiplayer play mode.
- The commercial deterministic netcode SDK used today is great (determinism, replays, snapshots, headless tests), but
  it has costs: the Unity world and the sim world are glued together by a bridge, schema codegen, map baking, an asset
  DB export, physics separate from Unity's, and a commercial service dependency.
- The developer never really uses the Editor: levels are built from code, art comes from Blender scripts, everything
  is driven from the CLI. Dev tools should live inside the game.

## Decisions

- **Language: Odin** (signed off 2026-11-09). C++, Rust, C# and Zig were prototyped and benchmarked; what's kept is in
  `archive/README.md`.
- **Host: Godot 4.7.x via GDExtension** (LibGodot only if GDExtension blocks something concrete).
- **Physics: Box3D**, our fork with world save/restore.
- **Numbers:** f32 with deterministic discipline (decided; fixed point rejected).
- **Netcode:** a host-run input relay stamps the official inputs (decided; a peer-to-peer mesh where every peer
  waits for every other peer's inputs was rejected).

## Requirements (the developer's answers, 2026-11-07)

- **Scope**: hobby time, but ambitious, because AI agents do most of the work. Build features when they're needed;
  design the core architecture carefully up front. For now the engine is for the developer; it may be open-sourced
  later.
- **Platforms**: Steam on Windows x64, macOS ARM, Linux / Steam Deck. Consoles ignored for now (a theoretical path is
  nice, not required).
- **Crossplay Mac ARM ↔ Windows x64 is required**, so determinism must hold across architectures.
- **Scale**: 2–4 players, 64 Hz (a per-game power of two), up to 1000+ entities (survivor / tower-defense style
  sections). Full rigid-body physics is wanted (physics-sandbox games), inside rollback.
- **Simulation threading**: single-threaded and deterministic first; parallel only where measurements demand it.
- **Netcode**: relay-stamped rollback. The host runs an input relay that stamps the official inputs for each tick,
  so a laggy player never stalls the others. Late join from a snapshot works, and a player who drops or leaves can
  rejoin the running match as a late joiner. No backend.
- **Transports** (pluggable): in-process loopback, direct UDP / LAN, and online play through Epic Online Services
  (lobbies by code + P2P with Epic's relays as fallback; shipped in `survivor-v0.1.1`, `spec/eos.md`). Steam
  (Datagram Relay) later.
- **Co-op testing**: N clients per process × a transport, with views on or off (headless). Headless loopback with a
  network simulator is the workhorse for tests, agents and CI.
- **Tests**: headless sim tests; replays as exact regression tests within one build (scenario tests checking outcomes
  across builds); cross-platform checksum CI (Mac vs Windows).
- **Dev tools in-game**: entity picker and inspector, timeline scrub (rewind and branch from snapshots), a network
  simulator panel with desync diffs, tuning sliders that write back to text files, F3 feedback, a free camera, a perf
  overlay. An in-game level editor eventually.
- **Agent API** in the running game: query and edit state, step ticks, inject input per player, snapshots and
  replays, screenshots, scripted scenarios.
- **Gameplay code style**: plain functions over typed queries, minimal magic; keep design options open.
- **Hot reload**: nice to have, not at the expense of everything else. Agents work in parallel git worktrees and gain
  little from it; fast compiles matter more. Must have: configs, shaders, and probably UI. Experimental tech (Roc,
  WASM, ...) is fine if it fits really well.
- **Levels**: Blender (glTF + custom properties) + code; an in-game editor later. No baking step.
- **Content**: nothing gets ported from Unity's third-party packs; rebuild in code or use what the renderer provides.
- **Character rigs**: view-only and procedural; physically grabbing things is worth experimenting with.
- **Animation / audio**: unknown needs; prefer whatever the host offers; avoid licence costs (FMOD only if it's
  clearly worth it).
- **UI**: game UI in Godot (GDScript allowed in the view layer); dev tools in-game. Prefers immediate-mode or
  reactive.
- **Version control**: git + LFS.

## Key design idea so far

All simulation state lives in one contiguous, pointer-free block (handles, not pointers). That makes a snapshot a
memcpy, a checksum a hash of the block, late join a transfer of the block, and it enables rewind / scrub, state-keeping
hot reload, and a **sync-test mode** that rolls back and re-simulates N frames every frame in single player, comparing
checksums. That mode is what makes "works in single player ⇒ works online" a property we can check. The view reads
simulation state (predicted frames for motion, verified frames for scores, events for effects) and never writes it;
player input is the only way in.

Settled designs live in `spec/`. Open research is in `docs/research/` (agent tooling, view binding, AI tooling).
`docs/archive/` keeps the phase 2 results; research on the stacks and hosts we didn't choose is in git history.
