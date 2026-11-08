# unified: context

`unified` is a purpose-built core for cooperative games with deterministic rollback netcode: Photon Quantum's model
(deterministic sim, input relay, prediction and rollback), code-first, AI-agent-first, with fast iteration loops.
It is written in **Odin**, with **Godot** as the host for rendering, audio, UI and the editor. Rendering is never
written from scratch.

The testbed is a slice of OctoEscape (`/Users/dmitry.v/work/personal/OctoEscape`): a 3D co-op game where players are
octopuses, currently built on Unity 6 + Photon Quantum 3. Its agent guide (`AGENTS.md`), `docs/ai/architecture.md`,
`docs/QUANTUM.md` and `docs/ai/workflow.md` show how it is built today.

## Why

- Unity is the bottleneck: Editor refresh and domain reloads, crashes, dialogs that block tools, only one agent at a
  time can use the Editor, and testing co-op needs a build or multiplayer play mode.
- Quantum is great (determinism, replays, snapshots, headless tests), but it has costs: the Unity world and the
  Quantum world are glued together by a bridge, `.qtn` codegen, map baking, an asset DB export, physics separate from
  Unity's, and a commercial service dependency (we want Steam relay instead).
- The developer never really uses the Editor: levels are built from code, art comes from Blender scripts, everything
  is driven from the CLI. Dev tools should live inside the game.

## Decisions

- **Language: Odin** (sign-off pending). C++, Rust, C# and Zig were prototyped and benchmarked; the research and
  results are in `archive/`.
- **Host: Godot 4.7.x via GDExtension** (LibGodot only if GDExtension blocks something concrete).
- **Physics: Box3D**, our fork with world save/restore. Jolt is the fallback.
- **Numbers:** f32 with deterministic discipline (decided; fixed point rejected).
- **Netcode:** Quantum-style host relay (decided; GGPO-style mesh rejected).

## Requirements (the developer's answers, 2026-11-07)

- **Scope**: hobby time, but ambitious, because AI agents do most of the work. Build features when they're needed;
  design the core architecture carefully up front. For now the engine is for the developer; it may be open-sourced
  later.
- **Platforms**: Steam on Windows x64, macOS ARM, Linux / Steam Deck. Consoles ignored for now (a theoretical path is
  nice, not required).
- **Crossplay Mac ARM ↔ Windows x64 is required**, so determinism must hold across architectures.
- **Scale**: 2–4 players, 60 Hz, up to 1000+ entities (survivor / tower-defense style sections). Full rigid-body
  physics is wanted (physics-sandbox games), inside rollback.
- **Simulation threading**: single-threaded and deterministic first; parallel only where measurements demand it.
- **Netcode**: Quantum-style. The host runs an input relay that stamps the official inputs for each tick, so a laggy
  player never stalls the others. Late join is built (phase 2); reconnect comes later. No
  backend.
- **Transports** (pluggable): in-process loopback, direct UDP / LAN, a self-hosted relay, Steam (Datagram Relay), later
  maybe Epic Online Services.
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
- **Octopus rig**: view-only and procedural today; physically grabbing things is worth experimenting with.
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

Current research is in `docs/research/` (physics, simulation structure, netcode, agent tooling, prior art, Godot
integration, view binding, AI tooling). Research
on the stacks and hosts we didn't choose is in `docs/archive/`.
