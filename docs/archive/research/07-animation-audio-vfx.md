# 07: Animation, audio and VFX

Research for `unified` (2026-11-07). Hosts compared: Bevy (0.20, released 2026-10-08) and Godot (4.7 stable).
Claims marked **(unverified)** were not confirmed from a primary source during this research.

## TL;DR and recommendations

- **The testbed needs little from an animation system.** Everything that moves in the current game is procedural: the
  main character's rig (Verlet + FABRIK), code-driven creature walks and the collectibles. No Animator controllers are
  in use. So the core need is **"write bone transforms from code every frame"**, plus glTF skinning and morph targets.
  Clip blending is a later, smaller need. Both hosts cover it. **Write the rig yourself** (port the rig as a
  host-agnostic Rust crate); don't depend on any engine's IK.
- **Keep gameplay timing in the sim, in ticks.** The game already does this (hit times and hit arcs are sim data): "the
  simulation decides, the rig sells it". Avoid root motion and animation-driven hitboxes. If they are ever needed,
  bake them: pull data out of the clips into sim assets and sample them by tick.
- **Audio**: no middleware. On **Bevy**, use **bevy_seedling (Firewheel)**, with **bevy_kira_audio** as the
  conservative fallback. Don't use plain `bevy_audio` (no buses or effects). On **Godot**, the built-in audio
  (buses, `AudioStreamRandomizer`, `AudioStreamInteractive`, Area reverb) is enough. FMOD is free at this scale
  but closed source, GUI-authored, and only reachable from Rust through community bindings: not worth it now.
- **Rollback sound**: put it in the engine, not the host. Fire feedback on predicted events, deduplicate by
  (type, entity, tick, hashed fields), and on cancel fade out over a few ms. Celebrations play from verified
  events. Loops come from state, not events. This works with any audio library that has voice handles,
  stop-with-fade and a start offset.
- **VFX**: on **Godot**, `GPUParticles3D` + `ParticleProcessMaterial` + flipbooks + shader materials. On **Bevy**,
  `bevy_hanabi` works but is "under heavy development". The game's feel rules cap a frequent hit at about 20–30
  particles, so a small in-house CPU particle and mesh-effect layer (instanced, defined in code or text) is a credible
  alternative and the most agent-friendly. Cartoon looks come mostly from **shaders on simple meshes** (erosion,
  scrolling noise, toon ramps) and flipbooks, not from particle counts.

## What the game actually needs

| Area | Need | Engine feature it maps to |
|---|---|---|
| Main character | 8 arms, Verlet chains pulled to goal shapes, FABRIK reach, world collision, written to the skinned model's bones; squash/stretch on springs | skinning + per-frame joint writes + view-side raycasts |
| Other creatures, collectibles | procedural walk cycles, claw clacks, faces, idles | same; maybe blendshapes for faces |
| Future clip characters | Blender glTF clips, cross-fades, an upper-body layer (mask), additive hit reactions, clip events for footsteps | clip player + blend tree + masks + additive + events |
| Juice | damped springs, easing, hit-stop per view, no camera shake | plain code; tweens nice to have |
| Sound | 3–6 random takes, ±1–2 semitone pitch, 3D linear rolloff 4–40 m, non-spatial "news", voice cap 3–4 per clip, 50 ms merge, priorities, voice ducking 4–6 dB, music under voice, synthesized gap-fillers | buses, sends/sidechain or bus tweens, voice pools with stealing, random containers, streaming |
| Voice | Character lines with subtitles, a synthesized warble fallback | streaming playback + a procedural generator node |
| VFX | puffs, sparks, stars, dust rings along surface normals, trails, dizzy ring billboards; short (0.2–2 s); ≤ 20–30 particles per frequent hit; strict colour language; no glow but the flash | small particle bursts, flipbooks, mesh effects, billboards |

Root motion, ragdolls, retargeting and motion matching are not needed.

## Animation

### Bevy

- **Clips and graph**: `AnimationPlayer` + `AnimationGraph`. Node types are `Clip`, `Blend` (weights normalized) and
  `Add` (additive, not normalized) ([docs.rs bevy_animation 0.20.1](https://docs.rs/bevy_animation/latest/bevy_animation/graph/enum.AnimationNodeType.html)).
  0.15 added animation masks (upper/lower body), additive blending, clip events and the generic `Curve` API that can
  animate any component field ([Bevy 0.15](https://bevy.org/news/bevy-0-15/)). Transitions and `AnimationEvent`
  observers are in the current API ([docs.rs](https://docs.rs/bevy/latest/bevy/animation/index.html)).
- **glTF**: clips load from glTF. 0.18 added `GltfExtensionHandler` for custom extension data, with an example that
  builds an `AnimationGraph` at load time ([Bevy 0.18](https://bevy.org/news/bevy-0-18/)). 0.19 culls skinned meshes
  using their animated joints and batches morph targets ([Bevy 0.19](https://bevy.org/news/bevy-0-19/)). There is
  nothing new on animation in 0.18–0.20. No built-in state machine, root motion or retargeting **(unverified for
  0.20; none appears in the docs read)**.
- **IK**: none built in. The crates are stale: `bevy_mod_inverse_kinematics` targets Bevy 0.16
  ([docs.rs](https://docs.rs/crate/bevy_mod_inverse_kinematics/latest)), `bevy_fabrik` targets 0.15
  ([docs.rs](https://docs.rs/bevy_fabrik)), and `bevy_ik` is abandoned ([GitHub](https://github.com/gschup/bevy_ik)).
  This doesn't matter, because the character rig needs a custom solver anyway. glTF joints are ordinary entities with
  `Transform`s, so a rig system writes them directly after animation runs. That fits the "plain functions over
  typed queries" style well.

### Godot

- **Clips and graph**: `AnimationPlayer` / `AnimationTree` (state machines, blend spaces, one-shot and add nodes,
  filters as masks). They are mature and editor-centric, but the resources are text (`.tres`), so agents can edit
  them. `AnimationMixer` has a deterministic option and can be advanced manually, so a view can drive it from sim
  time ([Godot IK article](https://godotengine.org/article/inverse-kinematics-returns-to-godot-4-6/)).
- **Procedural**: the `SkeletonModifier3D` pipeline (4.4+) is where code poses bones after animation. 4.5 added
  `SpringBoneSimulator3D` and `BoneConstraint3D`. 4.6 brought IK back: `TwoBoneIK3D`, `SplineIK3D`, `FABRIK3D`,
  `CCDIK3D`, `JacobianIK3D` and `LimitAngularVelocityModifier3D`, with 19 new modifiers across 4.4–4.6 ([Godot,
  Dec 2025](https://godotengine.org/article/inverse-kinematics-returns-to-godot-4-6/)). `SpringBoneSimulator3D` would
  give secondary motion for free. The character rig would be a custom modifier, or bone poses written
  from the GDExtension side. 4.7 added animation editor polish and `Tween.tween_await()`
  ([4.7 release page](https://godotengine.org/releases/4.7/)).
- Godot's toolset here is clearly richer. The question is whether `unified` uses it: if the sim is Rust and Godot is
  only the view, every animation call crosses GDExtension.

### Engine-agnostic

- **ozz-animation** (C++, MIT): a runtime-only library for sampling, blending and skinning jobs, with offline tools
  to convert glTF and FBX ([GitHub](https://github.com/guillaumeblanc/ozz-animation)). `ozz-animation-rs` is a Rust
  rewrite of the runtime aimed at cross-platform determinism for lockstep games
  ([lib.rs](https://lib.rs/crates/ozz-animation-rs)). It needs nightly Rust, and its licence and maintenance were
  not checked **(unverified)**. It is the obvious pick if sim-side clip sampling is ever needed.
- **The rig itself**: the current rig is a few hundred lines of math (Verlet, FABRIK, springs). As a host-free crate
  (`glam` in, joint transforms out, with a raycast callback for world collision) it works under either host and in
  headless screenshot tests. **This is the most valuable animation work item.**

### Animation-driven gameplay under rollback

The full answer is to bake animation controllers (states, transitions, clips) into deterministic sim assets, so
under predict/rollback animations snap to the correct state and clip time. Bones sampled from clips can then drive
hitboxes, and root motion can run inside the movement system. That is real cost: a baker, fixed-point curve
sampling, and a second animation state machine in the sim. For `unified`:

1. **Default**: gameplay timing is tick constants and simple shapes in the sim (as today). The view poses to match:
   the slap's swing "runs ahead so the lagging tip arrives on time". No clips in the sim.
2. **If needed later**: extract the few curves that matter (a hitbox bone path, event ticks) from glTF **at load
   time**, which respects the no-baking rule, into sim assets, then sample them by tick with deterministic floats.
   `ozz-animation-rs` or a tiny keyframe sampler would do.
3. Avoid root motion. Locomotion stays in the sim and code (KCC), and clips follow it.

## Audio

### Bevy options

| Option | Status (Nov 2026) | Fit |
|---|---|---|
| `bevy_audio` (built in, rodio) | basic playback and spatial; a Bevy contributor calls its API "somewhat flawed" and rodio unsuitable for games ([audit](https://hackmd.io/@bevy/firewheel_and_seedling)) | too thin: no buses, effects or ducking |
| **bevy_seedling** (Firewheel) | 0.8 = Bevy 0.19, Firewheel 0.12 ([docs.rs](https://docs.rs/bevy_seedling/latest/bevy_seedling/)); the README table shows **no 0.20 release yet** ([GitHub](https://github.com/corvusprudens/bevy_seedling)) | sampler pools, buses as labelled nodes, per-sample effects, sends, Freeverb, spatial + optional HRTF, an audio clock and scheduled `AudioEvents` |
| **bevy_kira_audio** (Kira) | 0.27 = Bevy 0.20, tracks latest Bevy ([GitHub](https://github.com/NiklasEi/bevy_kira_audio)) | channels, effects (filter, reverb, delay, compressor, EQ), but "limited" spatial (volume and pan only) |
| Kira directly | MIT/Apache, backend-agnostic, mixer tracks, clocks, tweens, spatial; no Doppler yet ([GitHub](https://github.com/tesselode/kira)) | host-agnostic: survives a host change |

The audit of Firewheel/seedling recommends upstreaming both into Bevy as `bevy_audio`'s successor. It praises the
real-time care (no allocation or blocking on the audio thread), but finds "non-trivial undefined behavior" and only
a cpal backend. There is no consensus or date yet ([hackmd](https://hackmd.io/@bevy/firewheel_and_seedling)).
**Pick seedling** for its architecture and likely future, and **budget for version lag** (one Bevy release behind
right now). Kira is the safe fallback.

### Godot

Built in: a bus layout with effects (compressor with sidechain for ducking, reverb, EQ). `AudioStreamPlayer3D` has
attenuation models, `max_polyphony` (cuts the oldest), `area_mask` to route through Area3D reverb buses (e.g.
underwater), Doppler, emission cones and panning strength ([4.7 docs](https://docs.godotengine.org/en/stable/classes/class_audiostreamplayer3d.html)).
`AudioStreamRandomizer` covers takes and pitch. `AudioStreamInteractive` gives music clips with beat- and bar-synced
transitions ([docs](https://docs.godotengine.org/en/stable/classes/class_audiostreaminteractive.html)). 4.7 revamped
the bus UI ([4.7 RC notes](https://godotengine.org/article/release-candidate-godot-4-7-rc-3/)). This covers every
feel rule except the 50 ms merge and priority stealing, which are small code.

### Middleware and spatial libraries

- **FMOD**: free "Indie" licence for annual revenue under $200k and a development budget under $600k
  ([fmod.com/licensing](https://fmod.com/licensing), from search snippets; the page didn't render for me, so
  treat the exact figures as **unverified**). It needs registration and in-game credit **(unverified)**. Binaries
  can't be redistributed or statically linked. Rust bindings are community-made: `libfmod` (generated, tracks FMOD
  versions), `fmod-oxide` (hand-written safe API) and `bevy_fmod` (demos target Bevy 0.16)
  ([libfmod](https://github.com/lebedec/libfmod), [fmod-oxide](https://github.com/speak2erase/fmod-oxide),
  [bevy-fmod-demos](https://github.com/chainhackers/bevy-fmod-demos)). Its value is the FMOD Studio GUI for sound
  designers, which works against a code-first, CLI-driven workflow.
- **Wwise**: free Indie plan for a production budget up to $250k, per title, with periodic budget check-ins
  ([pricing](https://www.audiokinetic.com/pricing), [philosophy](https://blog.audiokinetic.com/en/wwise-licensing-and-pricing-philosophy/)).
  There is no Rust story worth naming. Avoid.
- **Steam Audio**: fully open source (Apache 2.0) since 4.5.2 in Feb 2024 ([Phoronix](https://phoronix.com/news/Steam-Audio-SDK-Fully-Open)).
  It is free and strong (HRTF, occlusion, reflections), but a cute co-op game with linear rolloff doesn't need it.
  Keep it as a later option.
- **Others**: `oddio` (Rust, spatial with Doppler, MIT/Apache; low activity, no releases listed,
  [GitHub](https://github.com/Ralith/oddio)). miniaudio (C, public domain / MIT-0) and SoLoud (C++, zlib) are fine
  but add FFI for no gain over Kira or Firewheel **(not re-checked)**.

## VFX and particles

- **Godot**: `GPUParticles3D` with `ParticleProcessMaterial`, sub-emitters, trails, collision, attractors and
  turbulence ([docs](https://docs.godotengine.org/en/stable/tutorials/3d/particles/index.html)). Flipbooks come from
  "Particle Billboard" plus H/V frames and anim speed/offset
  ([docs](https://docs.godotengine.org/en/stable/tutorials/3d/particles/process_material_properties.html)). There
  are custom particle shaders and `CPUParticles3D`, and 4.7 added particle scale and rotation
  ([4.7](https://godotengine.org/releases/4.7/)). Effects are `.tscn`/`.tres` text, which agents can write.
- **Bevy**: `bevy_hanabi` (GPU compute) has spawners and bursts, shape emitters, forces, collision with the depth
  buffer, trails/ribbons, mesh particles, an expression graph, and output modifiers including `FlipbookModifier`,
  `ColorOverLifetimeModifier` and `SizeOverLifetimeModifier` ([README](https://github.com/djeedai/bevy_hanabi),
  [docs 0.19](https://docs.rs/bevy_hanabi/0.19.0/bevy_hanabi/modifier/output/index.html)). It is authored purely in
  Rust code (good for agents). Caveats: it is self-described as "under heavy development", and docs.rs failed to
  build 0.20.0. `bevy_enoki` is CPU particles with sprite-sheet animation, but **2D only**
  ([README](https://docs.rs/crate/bevy_enoki/0.7.0/source/README.md)).
- **How cartoon VFX are really built** (general practice, **not sourced here**): most stylized hits are a few
  hand-made meshes (spheres, rings, cones, star shapes) with an unlit shader doing alpha erosion (a noise texture
  thresholded by a lifetime curve), scrolling UVs, polar UVs for rings, a toon ramp and vertex-colour tint, plus 5–20
  billboard particles for sparkle. Flipbooks cover puffs and smoke. CartoonFX packs are exactly this. With the
  colour rules and particle budget in the feel rules, a **library of ~10 shader-driven "primitives" + a tiny burst
  emitter**, parameterized by impact strength ("one parameter drives every layer"), would replace
  CartoonFX.
- **Agent-friendliness**: best is effects as data (RON/TOML: emitter params, curves, colour from the palette tokens)
  hot-reloaded, with the agent API's screenshot and time-stepping to judge the result. hanabi's Rust builder is
  second best, because each change recompiles unless effects are serialized (hanabi supports serialized effect
  assets). Godot `.tres` works, but its schemas are large and less discoverable to agents than a project-specific
  format.

## Rollback considerations

The usual model for sim events under rollback:
- events fire from predicted frames
- duplicates from re-simulation are suppressed by hashing event id, tick and fields (jittery fields
  like positions are left out)
- each predicted event is later **confirmed or cancelled**
- synced events fire only on verified frames: no false positives, some latency

The current game already uses it this way.

For `unified`, this belongs in the engine core, host-agnostic:

1. **Event key** = (type, entity handle, tick, hashed fields). The view keeps a set of played keys inside the
   rollback window. Re-simulation that produces the same key plays nothing new.
2. **Cancel**: a key that doesn't reappear by the time its tick is verified is cancelled. Audio fades the voice out
   over 10–30 ms if it is still playing (a stopped "pop" is fine; the feel rules say a cancelled puff "never plays
   twice").
   VFX fade out early.
3. **Late discovery**: an event first seen during a rollback for a tick N frames ago plays with a start offset, or
   is skipped if it is short and stale. `bevy_roll_safe` (Bevy 0.19) provides a rollback-safe `bevy_audio` wrapper.
   Its roadmap still lists "seeking in time-critical audio" ([GitHub](https://github.com/johanhelsing/bevy_roll_safe)).
   That is a useful reference, not a dependency.
4. **Verified-only** for celebrations and irreversible news (a goal done, a door opening for good), as the current
   game does today.
5. **Loops and continuous sound come from state, not events** (crawl patter from predicted velocity, machine hum
   from entity state). State-driven audio is rollback-proof by construction.
6. **Audio library requirements**: voice handles, stop with fade, a start offset/seek, and per-bus volume tweens.
   Kira, Firewheel and Godot all meet them. Godot needs a small tween to stop with a fade.

Visual animation stays view-side and needs no rollback. It reads predicted state, smoothed, and
derives clip time from sim ticks so a correction doesn't restart a clip.

## Per-host summary

| | Bevy 0.20 | Godot 4.7 |
|---|---|---|
| Clip playback + blend/additive/masks/events | built in (`AnimationGraph`) | built in (`AnimationTree`), richer (state machines, blend spaces) |
| IK / procedural | none; write joint `Transform`s (own rig crate) | `SkeletonModifier3D`, FABRIK/CCD/TwoBone IK, spring bones |
| Character rig | own crate, natural fit | own crate across GDExtension, or a custom modifier |
| Audio | **bevy_seedling** (fallback bevy_kira_audio) | built in buses + 3D players + randomizer + interactive music |
| Rollback audio | engine event layer (own) | engine event layer (own) |
| Particles | bevy_hanabi (GPU, code) or in-house CPU bursts | GPUParticles3D + process material + flipbooks |
| Cartoon shaders | WGSL/WESL materials (hot-reloadable) | Godot shading language, visual shader optional |
| Licence cost | none | none |
| Avoid | `bevy_audio` for this game, stale IK crates, FMOD | FMOD/Wwise plugins, AnimationTree for the character rig |

## Risks and unknowns

- **Version lag on Bevy**: seedling has no 0.20 release yet; hanabi 0.20 failed to build on docs.rs. Every Bevy
  bump can block on 3–4 third-party crates. Pin versions, and keep the rig and the event layer host-free.
- **Firewheel maturity**: the audit found undefined behaviour and only a cpal backend. Upstreaming isn't scheduled.
- **Godot boundary cost**: if Godot is only the view over a Rust sim, using AnimationTree, particles and audio means
  marshalling across GDExtension every frame. Godot's tools are better, but less of them is reachable "code-first".
- **The developer can't easily judge animation and audio quality**: lean on the feel rules' numbers (pitch ranges,
  durations, budgets) as tests, and on agent screenshots and recordings. Audio has no screenshot. Consider an
  in-game audio debug overlay (active voices, bus levels, last 20 events), plus offline renders that an agent can
  analyse (peak, LUFS: seedling has a `loudness` analyzer).
- **FMOD and Wwise terms** came from snippets and secondary sources. Re-check before ever adopting.
- **Hidden need for clips**: if future enemies are clip-animated (bought or AI-generated assets), Bevy lacks a
  state machine and root motion. That's fine with code-driven state, but it's work.
- **Cartoon VFX art direction** without CartoonFX is a content gap, not an engine gap. Budget agent time for a
  primitive library and a review loop.
