# 00: Synthesis and proposed stack

Pulls together research docs 01–08 (2026-11-07). Each claim below links back to the doc that carries its sources.
Nothing here is decided until the developer agrees. Items marked **(decide)** need an answer.

> **Status: the language is reopened.** Docs 01–08 assumed Rust. The developer asked for an even comparison of
> Rust, Odin, Zig (plus C++ and C# as references) on one rubric: `stacks/TEMPLATE.md`, with results in
> `stacks/*.md` and `stacks/COMPARISON.md`. The language-neutral findings below still hold: the pointer-free state
> block, floats with discipline, the input relay, the physics seam as top risk, the control protocol, and
> the spike order. The Rust-specific picks (Bevy, egui, Kira) depend on that comparison.

## The stack in one picture

```
 one Cargo workspace, all Rust
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │ game binary (dev build)                                                      │
 │                                                                              │
 │  host = Bevy 0.20, pinned (03)          sim = engine-agnostic crate (02)     │
 │  ───────────────────────────            ─────────────────────────────────    │
 │  windows: N clients, split or headless  one pointer-free state block         │
 │  view: reads &Frame (predicted /        (bytemuck types, generational        │
 │        previous / verified), owns       handles, sparse-set tables, globals, │
 │        view-only state (character rig)   inline collections)                  │
 │  render: custom toon material, probes   + physics world                      │
 │  game UI: bevy_ui + bevy_flair (06)        behind a SnapshotPart trait (01)  │
 │  dev UI: egui, built on our type        systems: plain fns, fixed order      │
 │          registry (06, 08)              math: glam scalar + libm only        │
 │  audio: bevy_seedling (Kira fallback)   snapshot = memcpy + physics.save     │
 │  VFX: in-house shader effects (07)      checksum = xxh3; sync-test always on │
 │  control server: JSON-RPC on a local                                         │
 │    socket → `uni` CLI / MCP (08)        net = engine-agnostic crate (05)     │
 │                                         relay thread: owns the clock, stamps │
 │                                         inputs; client: predict + rollback   │
 │                                         transports: loopback+netsim / UDP or │
 │                                         QUIC / Steam SDR / later EOS         │
 └──────────────────────────────────────────────────────────────────────────────┘
 headless test runner: links sim + net only, no Bevy, no GPU (02, 04, 08)
```

The rule that holds it together: **`sim` and `net` never depend on Bevy.** Bevy is the view and the window. That
keeps tests fast, keeps the sim's build small, makes Godot a real fallback, and confines Bevy's API churn (about three
breaking releases a year, 03) to the view layer.

## What each doc concluded

| # | Topic | Recommendation | Main risk it left open |
|---|---|---|---|
| 01 | Numbers + physics | IEEE `f32` with discipline, not fixed point. The physics engine is picked by a spike. Swarm agents (1000+) live in our block, not in physics. About 200–400 awake rigid bodies. | Physics snapshot cost and cross-arch determinism, unmeasured |
| 02 | Sim structure | Custom store: one pointer-free block in Rust (about 2–4k lines). No off-the-shelf ECS: none gives one pointer-free block, and bevy_ggrs has registration traps. Map views by handle plus a kind/origin key, so a rollback can't hand one entity's view to another. | The physics seam; how the borrow checker feels when systems write to several tables |
| 03 | Host / renderer | **Bevy**, pinned per release. Godot as fallback. Nothing else beats both. | Baked bounce light (Bevy consumes irradiance volumes but can't bake them); banded toon in Bevy's material system; shader compile hitches |
| 04 | Language + iteration | All Rust, no scripting or WASM layer for now. Optimize build time per worktree. Hot reload tiered: configs/shaders by file watch, UI by subsecond, sim by "rebuild, restart, replay". Keep a C-like sim boundary so WASM stays possible. | Whether cloning a warm `target/` into a new worktree keeps cargo's cache; real Apple Silicon build times |
| 05 | Netcode | Relay star: the relay (a thread in the host process, or headless on a VPS) owns the clock and finalizes ticks. Adaptive input delay from 1 tick, prediction capped at 10, state ring of 16. Bit-packed redundant inputs, about 5–10 KB/s. Late join = zstd state block + input tail. | Rollback CPU with physics; physics snapshot size; `steamworks-rs` in practice |
| 06 | UI | Two layers: **egui** for dev tools; **bevy_ui + BSN + bevy_flair** for game UI. Watch Blitz/Dioxus and PanGui; Noesis as paid fallback. | Bevy UI churn; crates lagging 0.20; no MSDF text path found (text may blur during scale animations) |
| 07 | Anim / audio / VFX | Port the character rig as a host-agnostic crate; no clip controllers needed yet. **bevy_seedling**, Kira as fallback. Rollback-aware sound in the engine. Small in-house shader VFX library. No FMOD. | seedling has no Bevy 0.20 release yet; an audit found undefined behaviour in Firewheel |
| 08 | Agent tooling | One `Session` API with three front ends (in-process tests, `uni` CLI, MCP adapter) over a per-instance local socket, so no ports. Type registry first. Every edit goes through sim input as a tick-stamped debug command. | Physics state in snapshots (scrub, sync-test and replays depend on it); unreliable GPUs on hosted macOS CI |

## Where the docs agree (and so do I)

- **The physics seam is the riskiest piece.** Docs 01, 02, 05 and 08 each name it independently, so it's the first
  spike. The relay-stamped loop eases it: always roll back to the last *verified* frame, so it's one physics save and
  one restore per tick, not one per predicted frame (01).
- **Rollback CPU, not bandwidth, is the budget** (01, 05). That's why the proposed input delay starts at 1 tick
  (0 suits cheap sims, but 300 rigid bodies are not cheap).
- **Determinism is enforced by tooling:** a pinned toolchain, `-ffp-contract=off` for C dependencies, one math module,
  clippy `disallowed-methods` for `f32::sin` and its relatives and `HashMap` iteration, sync-test on by default, and
  per-tick checksum traces compared across macOS ARM, Windows x64 and Linux in CI (01, 02, 08).

## Conflicts between the docs, resolved

1. **Pinned Bevy 0.20 vs crates that lag it** (seedling, bevy-inspector-egui, bevy_steamworks). Resolution:
   - **Audio:** start on Kira, which already supports 0.20. Move to seedling when it catches up. Audio events come from
     our sim either way, so the swap stays small.
   - **Inspector:** we build our own on egui. It inspects *sim* state through our type registry (08), not Bevy's
     World, so bevy-inspector-egui is at most a helper for view-side debugging.
   - **Steam:** use the plain `steamworks` crate inside `net`. No Bevy wrapper.
2. **"No hot reload" vs subsecond for UI** (04 vs 06). Not a real conflict: subsecond only patches the view-side
   binary crate. That fits UI and dev tools, the one place you wanted hot reload. The sim never needs it.

## Decisions for the developer

1. **(decide) Bevy as host, with the render spike as the gate.** If the spike can't reach an acceptable look,
   including some bounce-light answer, switch to Godot before the slice, not after.
2. **(decide) Bounce light.** Pick one:
   - (a) Start with realtime light plus hemisphere/SH ambient and SSAO, and accept the gap.
   - (b) Write our own probe baker (a headless bake into irradiance volumes, cached by the level's content hash). This
     is the APV equivalent and maybe 1–2 weeks of agent work (estimate).
   - (c) Bake in Blender and export.

   I'd start with (a) and plan (b).
3. **(decide) Repo layout.** Engine and the game slice in one workspace (`crates/` for the engine, `games/<game>/`
   for the slice) while the engine's API is still moving, and split later. Or two repos from day one. I'd start with
   one workspace.
4. Proposed defaults to accept unless you object:
   - Kira first, seedling later
   - input delay starting at 1 tick
   - sync-test always on in dev
   - no scripting layer
   - hot reload only for configs, shaders and UI

## Spike plan (ordered by risk)

Each spike is a throwaway under `spikes/` with written pass/fail criteria, taken from the doc in brackets. Spikes 1–4
are independent and can run as parallel agents in separate worktrees.

1. **Determinism + physics** [01, 02]: the store, the physics engine, 300 props with spawns and
   despawns, 4 kinematic capsules, 1000 swarm agents. It runs a relay-stamped rollback loop with sync-test.
   - Pass: identical per-tick hashes across macOS ARM, Windows x64 and Linux in GitHub Actions.
   - Pass: at most 6 ms per tick while re-simulating 8 frames.
   - Measure: snapshot size and save/restore time.
2. **Render** [03]: one level room exported from Blender as glTF with custom properties, drawn with the
   toon material, shadows, SSAO, bloom and outlines, in four windows at once.
   - Pass: you judge it side by side with a Unity screenshot.
   - Measure: startup time and first-frame shader hitches.
3. **Net** [05]: relay plus two clients in one process over loopback with the network simulator (latency, jitter,
   loss), then over UDP, then over Steam SDR between your Mac and your Windows PC.
   - Pass: no desync over 10 minutes of scripted input at 150 ms and 5% loss.
4. **Build speed** [04]: a workspace shaped like the target.
   - Measure: sim-crate incremental build, host incremental build, and a fresh worktree from a cloned warm `target/`,
     on your Mac.
   - Pass: sim tests rebuild in about 5 s or less, and a fresh worktree reaches a working build in about 60 s or less.
5. **Tooling** [08], after spike 1: control socket plus `uni` CLI with `step`, `input`, `snapshot save/load` and
   `screenshot`, driving spikes 1–3.

Then the **port slice**: one chamber, character movement, jump, toy carry and throw, two players, F3 (screenshot + snapshot
+ replay + note), and sync-test on throughout. The UI spike (HUD, emote wheel, inspector [06]) and the rig port [07]
come with the slice.
