# 03: Host engine and renderer

Researched 2026-11-07. **(unverified)** marks claims I couldn't confirm from a primary source (memory, inference
or one secondary article). Version facts come from bevy.org, godotengine.org, crates.io and docs.godotengine.org.

## TL;DR and recommendation

**Build on Bevy (0.20, pinned) as the host and view. The deterministic `sim` crate stays engine-agnostic. Godot 4 is
the fallback, chosen only if the spike shows Bevy can't reach the target look or can't produce baked bounce
light.** Nothing else beats both.

Why Bevy wins for *this* project:

1. **One language, one build, no bridge.** The whole reason for `unified` is to delete the Unity↔sim glue: two
   worlds, codegen, asset DB export and import steps. With Bevy, sim, view, dev tools and agent API are one Cargo
   workspace. View systems read `&Frame` with the sim's own Rust types, `cargo run` starts the game, and there is no
   project import cache per worktree. With Godot + godot-rust, the Rust sim lives inside a C++ engine with its own
   scene tree, object model, `.godot/` import cache and editor-centric resources. That is a thinner version of the
   same bridge.
2. **Code-first by construction.** Bevy has no editor (it isn't shipped yet, and we don't want one). Everything is
   code, glTF, WGSL/WESL and RON/TOML. Godot is code-capable but editor-shaped: LightmapGI bakes only in the editor,
   assets go through the editor's importer, and its docs and community assume the editor.
3. **The target topology fits.** N windows and cameras in one `App` are first-class: `multiple_windows` and
   `split_screen` examples ship with Bevy. Headless rendering to an image is an official example. Bevy's
   `RemotePlugin` (BRP) already has an MCP server (`bevy_brp_mcp` 0.23, which tracks Bevy 0.20). Godot allows
   **one `GodotInstance` per process** ([docs](https://docs.godotengine.org/en/stable/classes/class_godotinstance.html)).
   Multiple views would have to be multiple viewports inside it, which is fine but means Godot owns the process.
4. **The renderer covers the look, except baked GI.** Bevy has custom materials (`ExtendedMaterial` over
   `StandardMaterial`), fullscreen materials (0.18), cascaded shadows with PCSS, contact shadows (0.19), SSAO, bloom,
   SSR, distance fog, volumetric fog, several tonemappers, color grading, vignette (0.19), chromatic aberration,
   DoF, MSAA/FXAA/SMAA/TAA, irradiance volumes, reflection probes with parallax correction (0.19), lightmaps, area
   lights (0.19), and Solari path tracing (0.20, needs hardware RT). **The gap is baking.** Bevy consumes
   irradiance volumes and lightmaps but cannot bake them
   ([0.13 notes](https://bevy.org/news/bevy-0-13/), still true as far as I can find).

The price, stated plainly: **Bevy breaks its API about three times a year** (0.18 in Jan, 0.19 in Jun, 0.20 in Oct
2026), the ecosystem lags each release by 0–8 weeks, and agents' training data is full of stale Bevy APIs.
Mitigation: pin, upgrade deliberately in one agent-run pass per release, keep the view layer thin, and keep the sim
free of Bevy (see 02).

Biggest unknowns, which the spike must settle: (a) a credible bounce-light path matching APV, without hand baking in
an editor; (b) whether Bevy's material and shader system makes the full `Stylized` shader (banded toon with shadow
tint, wrap and rim, plus shadows and probes) easy, compared with Godot's first-class `light()` function; (c) shader
pipeline compile hitches on first draw **(unverified, known historically)**.

## Comparison

Scores are relative to this project's needs (✓ good, ~ workable, ✗ poor).

| | Bevy 0.20 | Godot 4.7 (4.8 beta) | Fyrox 1.0 | Stride 4.4 | Wicked Engine | Filament / The Forge | O3DE 26.05 |
|---|---|---|---|---|---|---|---|
| Language | Rust | C++ core; GDScript / C# / Rust (gdext) | Rust | C# | C++ | C++ (C for Forge) | C++ |
| Sim as separate core, host = view | ✓ same language, in-process | ~ via GDExtension; two object models | ✓ | ~ language switch | ~ C++ FFI | ✓ library | ✗ heavy framework |
| Code-first, no editor | ✓ native | ~ possible; importer and bakes are editor-side | ✗ editor-centric | ~ CLI templates exist; editor Windows-only | ~ | ✓ (but no engine) | ✗ |
| Build / iterate | ~ Rust incremental with `dynamic_linking`; shader + asset hot reload; hot-patching opt-in | ✓ engine prebuilt; ~ Rust dylib reload | ~ | ✓ .NET | ✗ C++ builds | ✗ C++ | ✗ very long C++ builds |
| N views per process | ✓ multi-window, multi-camera | ~ one instance, many viewports and windows | ~ | ? | ? | ✓ (Filament views) | ✗ |
| Headless | ✓ no-window runner; render to image | ✓ `--headless` (dummy renderer, no pixels) | ~ | ~ | ? | ✓ | ~ |
| Stylized look ceiling vs effort | ✓ high, more code | ✓ high, least effort | ~ OpenGL 3.3 | ~ | ✓ high | ~ Filament restricts lighting models | ✓ high, high effort |
| Baked / static GI | ~ consumes probes and lightmaps; **no baker** | ✓ LightmapGI (editor bake), VoxelGI, SDFGI realtime | ✓ built-in lightmapper **(unverified)** | ~ light probes (editor) | ✓ DDGI, path-traced lightmap bake | ✗ | ✓ |
| Blender glTF + custom props | ✓ `GltfExtras`, `bevy_skein` 0.7 (0.20) | ✓ extras → metadata (4.x, **verify**), `GLTFDocumentExtension` | ~ | ~ | ~ | ~ gltfio | ~ |
| Win / macOS ARM / Linux / Deck | ✓ (wgpu: DX12/Vulkan/Metal) | ✓ (D3D12 / Metal / Vulkan) | ~ macOS on deprecated GL | ~ macOS via MoltenVK (new in 4.4) | ~ macOS Metal 4 since early 2026 | ✓ / ~ | ✗ macOS weak |
| Stability | ✗ breaking every 4–5 months | ✓ stable 4.x API | ✓ 1.0 (Mar 2026) | ✓ | ~ single maintainer | ✓ | ✓ |
| Licence | MIT/Apache-2.0 | MIT | MIT | MIT | MIT | Apache-2.0 | Apache-2.0/MIT |
| Community / longevity | ✓ large; 501(c)(3) foundation; 200+ contributors per release | ✓ largest OSS engine | ~ one main dev | ~ small | ✗ one dev | ✓ Google / Confetti | ~ |
| AI-agent fit | ~ strong Rust, docs.rs and examples; stale training data | ✓ GDScript data; ~ gdext data thin | ✗ | ~ | ✗ | ~ | ✗ |

## Candidates

### Bevy (recommended)

- **State.** 0.20 released 2026-10-08 ([news](https://bevy.org/news/bevy-0-20/)); 0.20.1 on 2026-10-28 (crates.io).
  Cadence: 0.17 Sep 2025, 0.18 Jan 2026, 0.19 Jun 2026, 0.20 Oct 2026 ([news index](https://bevy.org/news/)).
  Each release has an official migration guide. 0.20 itself broke shaders (WESL replaces Bevy's WGSL dialect; plain
  WGSL still works) and BSN syntax.
- **Renderer features for us.** See the TL;DR list. Sources: [0.19](https://bevy.org/news/bevy-0-19/) for contact
  shadows, GPU-driven batching, vignette, parallax-corrected cubemaps, physically based SSR and area lights;
  [0.18](https://bevy.org/news/bevy-0-18/) for fullscreen materials; [0.20](https://bevy.org/news/bevy-0-20/) for
  Solari on Metal, mesh shaders, WESL and `ctt` texture compression. Solari needs hardware ray tracing (and on macOS
  has no denoiser yet), so it is **not a baseline**: the Steam Deck has no RT. It could be useful *offline*, as an
  in-engine probe baker (idea, unbuilt).
- **GI options.** Irradiance volumes (voxel probe grids sampled per pixel, conceptually like APV), reflection probes
  and lightmaps, all *consumed* only. Today's baking route is Blender EEVEE light-probe volumes exported by the
  community `bevy-baked-gi` tool ([repo](https://github.com/pcwalton/bevy-baked-gi)). It's old, and **whether it works
  with Blender 4.2+ EEVEE Next is unverified**. A native baker is still only a tracking issue (#12233).
- **Code-first and agents.** No editor. Scenes come from code (BSN `bsn!` macro, 0.19+) or glTF. BRP is JSON-RPC
  over HTTP, so an agent can query and mutate ECS state, and `bevy_brp_mcp` / `bevy_brp_extras` add screenshots and
  input ([docs.rs](https://docs.rs/bevy_brp_mcp)). 08-agent-tooling builds our own control server on the same shape.
- **Iteration.** Shaders and assets (including glTF) hot reload with the `file_watcher` feature. Rust hot-patching
  via Dioxus `subsecond` is opt-in since 0.17, with limits (new functions aren't patchable; large workspaces are
  slower) ([0.17 coverage](https://gamefromscratch.com/bevy-0-17-released/)). Incremental view-crate builds of a few
  seconds with `dynamic_linking` **(unverified for our size; see 04)**.
- **Multiple instances.** One `App` per process (winit allows one event loop), but many windows and cameras per app.
  N client views = N windows (or viewports), each camera seeing shared static level entities plus its own client's
  dynamic entities via `RenderLayers`. **Whether lights and shadows respect `RenderLayers` is unverified.** It doesn't
  matter much, since the level's lights are the same for all clients.
- **Headless.** The official `headless_renderer` example drops winit, runs `ScheduleRunnerPlugin` and copies a
  render target to the CPU ([source](https://docs.rs/bevy/latest/src/headless_renderer/headless_renderer.rs.html)).
  Fully window-less sim tests don't need Bevy at all.
- **Ecosystem for 0.20** (checked on crates.io, 2026-11-07): `bevy_enhanced_input` 0.27 ✓, `bevy_hanabi` 0.20 (GPU
  particles) ✓, `bevy_mod_outline` 0.14 (hull and jump-flood outlines, released today) ✓, `bevy_egui` 0.43 ✓,
  `bevy-inspector-egui` 0.38 ✓, `bevy_skein` 0.7 (Blender ↔ reflected components) ✓, `bevy_kira_audio` 0.27 ✓,
  `bevy_framepace` ✓, `bevy_vector_shapes` ✓, `bevy_rich_text3d` ✓, `avian3d` 0.8 ✓. **Still on 0.19:**
  `bevy_seedling` 0.8, `bevy_steamworks` 0.17. **Abandoned by churn:** `iyes_perf_ui` (0.16),
  `bevy_mod_billboard` (0.14). This lag pattern is the real cost of Bevy.
- **Platforms.** wgpu → DX12 or Vulkan on Windows, Metal on macOS, Vulkan on Linux and Deck. Shipped evidence: Tiny
  Glade shipped on bevy_ecs with its own renderer (widely reported). Few shipped 3D games use Bevy's renderer at
  scale **(unverified count)**.

### Godot 4 (fallback)

- **State.** 4.6 (Jan 2026): Jolt is the default 3D physics, D3D12 is the Windows default, LibGodot is in
  ([Phoronix](https://phoronix.com/news/Godot-4.6-Released)). 4.7 (Jun 2026): HDR output, AreaLight3D
  ([GamingOnLinux](https://www.gamingonlinux.com/2026/06/godot-engine-4-7-is-out-bringing-a-new-asset-store-hdr-support-steam-frame-support/)).
  4.7.2 on 18 Aug. **4.8 beta 2 on 29 Oct 2026** ([blog](https://godotengine.org/blog/)), with directional specular
  in lightmaps, contact shadows, multi-bounce AO and texture streaming
  ([4.8 beta 1](https://godotengine.org/article/dev-snapshot-godot-4-8-beta-1/)). 4.5 added a stencil buffer with
  built-in outline / x-ray stencil modes, and a shader baker against compile stutter.
- **Renderer for us.** It is the strongest *out of the box*. `StandardMaterial3D` has toon diffuse and specular
  modes, and spatial shaders have a custom `light()` function: our banded toon with shadow tint, wrap and rim is a
  natural fit. Also SSAO and SSIL, SSR (overhauled in 4.6), glow, AgX/ACES/Filmic tonemapping, volumetric fog,
  `CompositorEffect` for custom screen-space passes, `ReflectionProbe` (can update at runtime: no bake), and
  `GPUParticles3D`.
- **GI.** LightmapGI bakes lightmaps plus probes for dynamic objects, but **only in the editor; it can't be baked in
  an exported project** ([class docs](https://docs.godotengine.org/en/stable/classes/class_lightmapgi.html)).
  VoxelGI (bakeable) and SDFGI (realtime, Forward+ only) are the alternatives. HDDAGI, SDFGI's successor, is still an
  open PR as far as I can tell (#119869) **(unverified status)**. A headless editor run with a bake script could
  automate LightmapGI **(unverified)**.
- **Integration options.** (1) *Godot hosts, Rust is a GDExtension* (godot-rust `godot` 0.5.5; v0.5 broke the API
  in early 2026 ([migration](https://godot-rust.github.io/book/migrate/v0.5.html))). It's mature, but Godot owns the
  process and main loop, and every view object is a Godot `Node` or `RID` mirrored from sim handles. (2) *Rust hosts
  Godot via LibGodot*: the C API ships in 4.6. Restart and host-window embedding are still being merged
  ([GodotCon talk](https://talks.godotengine.org/godotcon-ams-2026/talk/DQXZZC/)), it's **one instance per process**,
  and there are no official Rust bindings (only an experimental third-party crate). (3) Drive `RenderingServer`
  directly (no nodes) from Rust: documented and fast, but it gives up the conveniences that are Godot's reason to
  exist.
- **Code-first friction.** Assets need the importer (`godot --headless --import`, a `.godot/` cache per worktree)
  unless loaded at runtime with `GLTFDocument`. glTF extras → node metadata landed in 2024 **(verify the version)**,
  and `GLTFDocumentExtension` hooks import otherwise. `--headless` uses a dummy renderer, so screenshots need a real
  (possibly hidden) window **(unverified)**.
- **Agents.** The most GDScript training data of any open engine. gdext's Rust API is generated from Godot's stable
  class DB, so it's predictable, but its training data is thin.

### Others

- **Fyrox 1.0** (Rust, MIT; [1.0 post](https://fyrox.rs/blog/post/fyrox-game-engine-1-0-0/), Mar 2026). Stable API
  and an editor-centric workflow. The renderer is **OpenGL 3.3** ([FAQ](https://fyrox-book.github.io/introduction/faq.html)),
  deprecated on macOS, with a wgpu move called hard. Essentially one maintainer. No.
- **Stride 4.4** (C#, MIT; [release](https://github.com/stride3d/stride/releases/tag/releases%2F4.4.0), Oct 2026).
  Linux and macOS builds are now first-class, macOS via MoltenVK, Vulkan 1.3 and D3D12 reworked. The editor is
  Windows-only (Proton on Linux). Choosing it means C# for the sim (see 04 on cross-arch floats), and the community
  is small. No.
- **Wicked Engine** (C++, MIT). An impressive renderer (DDGI, path-traced lightmap baking, SSR, ocean), designed to
  be embedded as a library. macOS (Metal 4) only since early 2026 ([devlog](https://turanszkij.itch.io/wicked-engine/devlog)),
  one maintainer, little training data, and C++ build times. The best "C++ renderer library" if we ever leave Rust.
  Not now.
- **Filament** (C++, Apache-2.0). A superb, small PBR library with multiple views, headless rendering and gltfio. But
  materials pick from fixed shading models (lit, unlit, cloth, subsurface) **(custom light loops restricted:
  unverified detail)**, there's no GI beyond IBL and SH, no particles, and no asset pipeline. A toon look with
  shadows is awkward.
- **The Forge** (Apache-2.0). An AAA-grade cross-platform rendering *framework*: you write the renderer on top. That
  violates "rendering is never written from scratch".
- **bgfx / sokol / raw wgpu / Raylib.** Abstraction layers or simple renderers. With Raylib (zlib), SSAO, cascaded
  shadows, bloom, probes and outlines are all ours to write. Odin ships bindings for raylib, sokol and wgpu, so an
  Odin path means writing a renderer. Zig's Mach is still pre-1.0 and quiet. No.
- **O3DE 26.05** ([release notes](https://www.docs.o3de.org/docs/release-notes/)). Atom is a strong renderer, but the
  framework is huge, editor-first, has very long C++ builds and weak macOS. No.
- **Flax** (C++/C#). A good renderer (SDF GI), but source-available with a royalty licence and editor-first. No.
- **Renderling** (Rust, wgpu, GI-focused). Last crate release Sep 2024: too early.

## What the target look needs, and coverage

| Need (today in URP) | Bevy | Godot |
|---|---|---|
| Stylized lit shader: palette color, vertex colors, banded toon (1–4 bands, softness), shadow tint, wrap, lit rim, world noise, height gradient, sway | `ExtendedMaterial<StandardMaterial, _>` or a custom `Material` calling `bevy_pbr` lighting functions; vertex sway in the vertex stage. Band and tint logic must hook into the light loop. **This is the spike's core question** | Spatial shader with `light()` and `vertex()`: first-class, least effort |
| PBR path for chrome and glossy slick (toon off) | `StandardMaterial` | `StandardMaterial3D` |
| Inverted-hull ink outline | `bevy_mod_outline` (vertex extrusion) | next-pass material or 4.5 stencil Outline mode |
| Screen-space looks (depth+normal outlines, posterize, pixelate, paper, halftone, hue isolate) | depth/normal prepass + fullscreen material or a post-process render-graph node | `CompositorEffect` (compute) with depth and normal-roughness buffers |
| Interactable highlight rim (mask after transparents, rim after post) | custom render-graph node, or `bevy_mod_outline` jump-flood | stencil (4.5+) or next pass |
| Glass, hologram (additive), three water looks (screen-space refraction and reflection, depth foam) | transmission, SSR, depth prepass in custom materials | `SCREEN_TEXTURE` / `DEPTH_TEXTURE` in shaders, SSR |
| One shadowed key light per room, the rest unshadowed; cookies | per-light `shadows_enabled`; cookies **(unverified in 0.20)** | per-light shadows; projector textures |
| HDR, bloom with threshold, neutral/ACES tonemap, exposure, grading, split toning, vignette, grain, chromatic, DoF | all built in except grain (custom); split toning via `ColorGrading` sections **(approximation)** | glow, tonemappers, adjustments, LUT; vignette and grain custom |
| Per-room post volumes (2 m blend) | no volume system: lerp camera components from code (simple, and ours) | one `Environment` per world: lerp from code |
| Exp² fog per room | `DistanceFog` (ExponentialSquared) | depth fog (exponential) |
| SSAO + vertex AO | SSAO + vertex colors | SSAO / SSIL |
| **APV bounce** (per-pixel probes, no UV2, dynamic objects lit the same) | irradiance volumes, but **baking is external or ours** | LightmapGI probes (editor bake, needs UV2 for static) or SDFGI (no bake) |
| One box-projected reflection probe per room | parallax-corrected cubemap (0.19); capture **ours** (render 6 faces at load) | `ReflectionProbe` box projection, update "once" at runtime |
| MSAA 4× / FXAA / SMAA / render scale at runtime | built in | built in |
| GPU particles, world-space text | `bevy_hanabi`, `bevy_rich_text3d` | `GPUParticles3D`, `Label3D` |

Verdict: **Godot covers the look with less work; Bevy covers everything with more code, except probe baking, which
neither gives us code-first.** The look is mostly custom shaders and screen-space passes we own in either engine. In
Unity we already wrote them, so porting them is a known cost.

**Baked bounce without an editor**, options in order of preference to test:
1. **Bake our own irradiance volume at level load (or cache it on disk keyed by the level's content hash)** with a
   small GPU or CPU path tracer over the level's static meshes and lights. Rooms are small (≤ 30 m), so a 0.5–1 m
   probe grid is thousands of probes: seconds on the GPU **(estimate)**. It fits "no baking step": the bake is a
   derived cache, like a shader cache. Solari's code is a reference.
2. Bake probe volumes in Blender (our models already come from Blender scripts) and export with `bevy-baked-gi` or
   our own exporter: Blender stays the source of truth, but it's a pipeline step and EEVEE Next compatibility is
   unknown.
3. Bake lighting into vertex colors in Blender (Cycles): cheap and robust for static chunky geometry, but no bounce on
   dynamic characters.
4. Godot fallback: LightmapGI via a scripted headless editor bake, or SDFGI with no bake at all.

## Risks and unknowns

- **API churn (high, certain).** Three breaking Bevy releases a year, BSN and shader syntax included. Each costs an
  upgrade pass and waiting for crates (`bevy_seedling` and `bevy_steamworks` still lag 0.20). Mitigate: pin, keep
  third-party crates few and replaceable, vendor small ones, give an agent the official migration guide, and keep the
  sim Bevy-free so churn never touches gameplay or determinism tests.
- **Stale agent knowledge (medium).** Models write 0.12–0.15-era Bevy. Mitigate: the agent guide points at the
  pinned version's examples in the Cargo registry and at docs.rs; `cargo check` catches the rest. Godot's API is
  stabler, but gdext data is thin too.
- **Baked GI (high).** No first-party baker on Bevy; editor-only bake on Godot. Our own probe baker is new work
  (maybe 1–2k lines **(estimate)**) and quality-sensitive (leaks through thin walls, as APV already shows).
- **Toon lighting integration in Bevy (medium).** Banding inside Bevy's clustered PBR loop (with shadows, probes and
  multiple lights) may mean forking `pbr_functions` / `pbr_lighting` WGSL, which breaks across releases.
- **Shader compile hitches (medium, unverified for 0.20).** Pipelines compile asynchronously on first use, so meshes
  pop in. The current Unity game already warms up shaders before captures. Needs a warmup or pre-compile pass.
- **wgpu/Metal platform bugs (low–medium).** Mac is the primary dev machine; wgpu's Metal backend is mature but less
  battle-tested than Godot's own.
- **Look ceiling vs Unity (medium).** URP-specific polish (APV quality, mature SMAA/TAA, Volume blending) has to be
  matched by hand. Judge by side-by-side captures, not feature lists.
- **Bevy project health (low).** A foundation, paid maintainers, 200+ contributors per release. Still pre-1.0, with
  no 1.0 date.
- **Godot as fallback (medium).** Choosing it later costs a rewrite of the view layer only, if 02's rule holds: the
  sim never imports host types.

## Spike proposal: "one chamber, toon look, four windows"

**Goal:** prove or disprove Bevy as the host on the real look, before committing view code. Agent-time about 3–5
days. Run the Godot comparison only if Bevy fails a look or GI criterion.

**Setup.** Take one LabExperiments chamber (built by its existing Blender script, palette and light brief). Add a
glTF exporter path to the script: same meshes, vertex colors, `palette.json`, and node custom properties for
colliders, entity kinds and lights (as glTF extras or `KHR_lights_punctual`). Load it in a Bevy 0.20 app.

**Work items.**
1. glTF + extras → view entities and a stub sim-entity list (the collider and entity data parsed, proving the level
   path without baking).
2. Port `Stylized` (toon bands, shadow tint, wrap, rim, noise, height gradient, vertex AO) as a Bevy material, plus
   `Stylized Outlined` (`bevy_mod_outline`) and one screen-space pass (depth+normal outlines) as a fullscreen
   material.
3. Room atmosphere: one shadowed key light plus unshadowed fills, exp² fog, SSAO, bloom (threshold ~1), neutral and
   ACES tonemapping, exposure and grading, and a box-projected reflection probe captured at load.
4. Bounce: try option 1 (an in-engine irradiance-volume bake with a content-hash cache) for one day. If it
   isn't viable, try option 2 or 3.
5. Four windows in one process, each its own camera, plus a "client" with its own dynamic props (`RenderLayers`),
   driven by a trivial deterministic stub sim.
6. CLI: `--headless --screenshot out.png --camera <name>` renders without a visible window and exits; BRP enabled.

**Pass / fail.**
- **Look:** the developer judges side-by-side captures (same camera) against the Unity Play Mode capture of the
  chamber as "as good or better" on at least 3 of 4 angles. The toon bands respect shadows and multiple lights.
- **Bounce:** dynamic objects (a character stand-in) pick up colored bounce from the room. No editor and no manual step:
  rebuilding the level from the Blender script plus `cargo run` reproduces it.
- **Perf:** chamber at 1080p ≤ 6 ms GPU on an M-series Mac; 60 fps at 1280×800 on a Steam Deck (or Linux iGPU stand-in).
- **Iteration:** shader edit visible ≤ 1 s with no restart; Blender re-export visible without a restart; view-crate
  incremental build ≤ 5 s; cold start to first frame ≤ 2 s; no visible shader pop after a warmup step.
- **Topology:** 4 windows at 60 fps in one process; headless screenshot works on macOS and Linux CI.
- **Agent fit:** a fresh agent with only the repo's guide completes one Bevy-API task (e.g. add a post effect
  parameter) without human help.
- **Fail → Godot spike** (1–2 days, same chamber via gdext). Compare look effort and the LightmapGI / SDFGI result,
  and weigh them against the bridge and editor costs above.

## Sources

Bevy: [news index](https://bevy.org/news/) · [0.20](https://bevy.org/news/bevy-0-20/) ·
[0.19](https://bevy.org/news/bevy-0-19/) · [0.18](https://bevy.org/news/bevy-0-18/) ·
[0.13 (irradiance volumes, lightmaps, external baking)](https://bevy.org/news/bevy-0-13/) ·
[bevy-baked-gi](https://github.com/pcwalton/bevy-baked-gi) ·
[headless_renderer example](https://docs.rs/bevy/latest/src/headless_renderer/headless_renderer.rs.html) ·
[split_screen example](https://bevy.org/examples/3d-rendering/split-screen/) ·
[Skein](https://github.com/rust-adventure/skein) · [bevy_brp_mcp](https://docs.rs/bevy_brp_mcp) ·
[0.17 hot-patching coverage](https://gamefromscratch.com/bevy-0-17-released/) · crate versions from the crates.io
API (2026-11-07).
Godot: [blog](https://godotengine.org/blog/) ·
[4.8 beta 1](https://godotengine.org/article/dev-snapshot-godot-4-8-beta-1/) ·
[4.6 (Phoronix)](https://phoronix.com/news/Godot-4.6-Released) ·
[4.7 (GamingOnLinux)](https://www.gamingonlinux.com/2026/06/godot-engine-4-7-is-out-bringing-a-new-asset-store-hdr-support-steam-frame-support/) ·
[GodotInstance, one per process](https://docs.godotengine.org/en/stable/classes/class_godotinstance.html) ·
[LibGodot talk](https://talks.godotengine.org/godotcon-ams-2026/talk/DQXZZC/) ·
[LightmapGI, editor-only bake](https://docs.godotengine.org/en/stable/classes/class_lightmapgi.html) ·
[4.5 stencil (i-programmer)](https://i-programmer.info/news/144-graphics-and-games/18319-godot-45-adds-stencil-buffer-.html) ·
[HDDAGI (GameFromScratch)](https://gamefromscratch.com/godot-new-global-illumination-system-hddagi/) ·
[godot-rust v0.5 migration](https://godot-rust.github.io/book/migrate/v0.5.html).
Others: [Fyrox 1.0](https://fyrox.rs/blog/post/fyrox-game-engine-1-0-0/) ·
[Fyrox FAQ (OpenGL)](https://fyrox-book.github.io/introduction/faq.html) ·
[Stride 4.4](https://github.com/stride3d/stride/releases/tag/releases%2F4.4.0) ·
[Wicked Engine devlog](https://turanszkij.itch.io/wicked-engine/devlog) ·
[O3DE release notes](https://www.docs.o3de.org/docs/release-notes/).
