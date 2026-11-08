# Stack: Rust

Researched 2026-11-07. Versions come from the crates.io API on that day unless a link says otherwise. **[estimate]**
means my own extrapolation, which the benchmark round should replace. **[unverified]** means one secondary source or
memory. Docs 01–08 assumed Rust; I reuse their facts but re-argue every conclusion here. Per the brief, this doc is
the toughest critic of Rust, aimed squarely at the two worries: per-worktree build cost and C-binding friction.

## 1. Best realistic setup

Two host variants, one shared core. The core is the same in both, and that rule is what makes Rust viable at all:
**`sim` and `net` are small crates that never depend on the host.**

| Layer | Pick | Notes |
|---|---|---|
| Toolchain | Rust **1.99.1** stable (released 2026-10-15, [blog](https://blog.rust-lang.org/releases/)), edition 2024, pinned with `rust-toolchain.toml` | Nightly only for build-speed experiments (Cranelift, `-Zthreads`) |
| Sim state | Own store: one `#[repr(C)]` block of `bytemuck::Pod` tables, generational handles, fixed-capacity collections (doc 02, about 2–4k lines) | `bytemuck` 1.25 |
| Math | `glam` 0.34 with `scalar-math` + `libm` 0.2 | Same config Rapier/Parry test for determinism |
| Physics | **Rapier 0.36.1** (`enhanced-determinism`) or Box3D via `boxddd` 0.4 | |
| Host A | **Bevy 0.20.1**, pinned, `default-features = false` with only the plugins we use, `bevy/dynamic_linking` in dev | The feature-rich option |
| Host B | **wgpu 30 + winit 0.30 + our thin forward renderer**, or **Godot 4.7 via gdext `godot` 0.5.5** (Godot hosts, Rust is a GDExtension) | sokol via `floooh/sokol-rust` and SDL3 GPU via `sdl3` 0.22 are thinner still |
| Game UI | A: `bevy_ui` + BSN (+ `bevy_flair`). B (wgpu): egui skinned, or Clay/Taffy + own SDF quads. B (Godot): Control nodes | Doc 06 |
| Dev UI | **egui 0.37** (`bevy_egui` 0.43 on Bevy; `egui-wgpu` on wgpu); `dear-imgui-rs` 0.22 on Godot | |
| Audio | **Kira 0.12.6** (host-agnostic), `bevy_seedling`/Firewheel later; FMOD via `fmod-oxide` only if wanted | |
| Net | own relay protocol; loopback + netsim; `quinn` 0.11.12 for UDP/QUIC; `steamworks` 0.13.1 for SDR; EOS via own bindgen later | Doc 05 |
| glTF | Bevy's loader (A), `gltf` 1.4.1 (B, wgpu) or Godot `GLTFDocument` (B, Godot) | |
| Misc | `zstd` 0.14, `xxhash-rust` 0.8 (xxh3), `tracy-client` 0.19 | |
| Build | Cargo workspace; `cargo nextest`; ld-prime on macOS, rust-lld on Windows/Linux; `opt-level=1` ours / `3` deps; per-worktree `target/` seeded from a warm clone; sccache for C/C++ and dependency rlibs | Section 2 |

**My pick for unified, if Rust wins:** Host A (Bevy, pinned and trimmed), because it is the only Rust host that
covers the target look without writing a renderer. Host B (wgpu) is the build-speed choice but violates "rendering
is never written from scratch" for shadows, SSAO, probes and post. Godot via gdext is the look-per-effort choice but
re-creates a bridge (two object models, Godot owns the process). Scores below use Bevy unless noted.

## 2. Build speed

This is Rust's weakest area, and the numbers don't flatter it.

### Data points found

| Source | Setup | Clean | Incremental |
|---|---|---|---|
| [bevy_editor_prototypes#210](https://github.com/bevyengine/bevy_editor_prototypes/pull/210) (2025) | Bevy editor prototype, i7-11800H laptop, Windows | **2m16s** default; **1m45s** with lld + Cranelift + `-Zthreads=0` (nightly); **9m28s** with `dynamic_linking` (Windows forces `opt-level=3`) | ~14.5 s default; ~10.5 s lld; **~5 s** best |
| [vladbat00](https://vladbat00.github.io/blog/001-organising-bevy-projects) (Dec 2025) | Real Bevy 0.17 game, M1 Pro, workspace split twice, no dylib | not given | **7–25 s**; the split saved ~5 s |
| [bevy-website#1085](https://www.github.com/bevyengine/bevy-website/issues/1085) | Small Bevy projects | ~2 min, dylib no faster | **18 s → 2 s** with `dynamic_linking` |
| [egui#4481](https://www.goodfirstissue.org/emilk/egui/issues/4481) (2024) | `eframe` alone, M3 MacBook Pro | **~10 s**, +10 s for wgpu instead of glow | — |
| [tom-tang blog](https://tom-tang-3-ai-site.pages.dev/blog/why-cargo-ate-45gb-overnight/) (2026) | 5-crate server workspace, 3 agent worktrees, M-series | 57–76 s; one proc-macro feature (`ts-rs`) added **33%** | — |
| [Rust survey 2025](https://blog.rust-lang.org/2025/09/10/rust-compiler-performance-survey-2025-results) | 3700 respondents | — | slow incremental rebuilds are *the* top complaint; 55% wait >10 s |

I found **no published Bevy clean-build number on an M4 Pro**. Every number above is from slower or different
hardware.

### Estimates for unified on an M4 Pro (14 cores) **[estimate]**

| | Host A: Bevy (trimmed) + Rapier + egui + Kira + steamworks | Host B: wgpu + winit + egui + Rapier + Kira + steamworks | Host B: Godot via gdext |
|---|---|---|---|
| Clean debug build, fresh worktree, no cache | **90–180 s** | **45–80 s** | **60–120 s** (the `godot` crate generates and compiles bindings for the whole class DB [unverified size]; Godot itself is a prebuilt binary) |
| One-line change in `sim`, run its tests | **1–4 s** (sim never links a host) | same | same |
| One-line change in `sim`, relink runnable client | **2–6 s** with `dynamic_linking`; **8–25 s** without | **1.5–4 s** (smaller binary, ld-prime) | **2–5 s** (rebuild cdylib; Godot reloads extensions in the editor, not in an exported game) |
| One-line change in view code | same as above; subsecond hot-patch (`subsecond` 0.7.10) for UI in the bin crate | same | same |

Reasoning: the Windows laptop's 2m16s is an 8-core Tiger Lake; an M4 Pro is roughly 1.5–2× faster on parallel
rustc work, giving ~70–90 s for bare Bevy. Rapier/parry/nalgebra, egui, Kira/cpal, steamworks and our crates add
30–90 s more. The lean stack's figure scales eframe's ~20 s by adding Rapier and friends.

The rubric's 5 means **under 30 s clean**. **No realistic Rust game stack gets there without a cache.**

### How C/C++ dependencies build

Each `-sys` crate compiles its C/C++ in `build.rs` with the `cc` or `cmake` crate into that worktree's `target/`.
Rapier, egui, Kira and quinn have no C, but Box3D (`boxddd-sys`, vendored C via `cc`),
zstd, GameNetworkingSockets (protobuf + OpenSSL) and Steam Audio do. `bindgen` needs libclang at build time unless
the crate ships pregenerated bindings; most good `-sys` crates now do (`eos-sys`, `boxddd-sys`). Two costs follow:
C++ adds tens of seconds per clean worktree **[estimate]**, and **every C dependency must get
`-ffp-contract=off` through `CFLAGS` or a patched build script**, because Clang contracts to FMA by default on ARM64
(doc 01). Compare Zig, where `build.zig` compiles C with `zig cc` into one global cache shared by every checkout.

### Linker

- macOS: the system linker (ld-prime) is already faster than lld, per [Bevy's setup guide](https://bevy.org/learn/quick-start/getting-started/setup/).
  `split-debuginfo=unpacked` (macOS default) keeps the link cheap.
- Linux: rust-lld is the default since 1.90. Windows: rust-lld via config.
- `wild` 0.11 is fast on Linux; incremental linking with Wild is on the 2026 roadmap, not shipped
  ([Fast Builds roadmap](https://goals.rust-lang.org/2026/roadmap-fast-builds.html)).

### The worktree problem, in detail

Each worktree gets its own `target/`, so N agents mean N cold builds, N × 2–15 GB of disk, and N rust-analyzer
instances that each `cargo check` into their own target dir as well. One developer running three agent worktrees
reported a **45 GB** `target/`, with `hashbrown` compiled 7 times, 379 incremental cache dirs, a test binary at
880% CPU, thermal throttling overnight, and **0% sccache hit rate for Rust**
([blog](https://tom-tang-3-ai-site.pages.dev/blog/why-cargo-ate-45gb-overnight/)). That is exactly the developer's worry.

| Option | Status (Nov 2026) | Verdict |
|---|---|---|
| **Shared `CARGO_TARGET_DIR` / `build-dir`** | `build-dir` stable since 1.91. But Cargo locks the whole build dir, so parallel agents **serialize**. Fine-grained locking is nightly only ([build-dir goal](https://goals.rust-lang.org/2025h2/cargo-build-dir-layout.html)). Also, build scripts pin to the first worktree's paths ([nub#614](https://github.com/nubjs/nub/pull/614)) | Good for disk, bad for parallelism |
| **sccache 0.19** | Can't cache crates that invoke the linker: **bin, dylib (so `bevy_dylib`), cdylib, and proc-macro crates**. Incremental crates (all workspace members in dev) are not cached. Keys include the working directory, so worktrees miss unless `SCCACHE_BASEDIRS` is set, and it's only read at server start ([Rust.md](https://github.com/mozilla/sccache/blob/master/docs/Rust.md), [NVIDIA OpenShell#2379](https://github.com/NVIDIA/OpenShell/pull/2379), [bug 2059623](https://bugzilla.mozilla.org/show_bug.cgi?id=2059623)) | Caches registry rlibs and C/C++ objects. Still runs every proc-macro build and every link per worktree |
| **APFS clone of a warm `target/`** (`cp -c -R`) | Instant, near-zero disk. Cargo's fingerprints for registry deps are path-independent; workspace members rebuild. **Whether mtimes survive the clone without invalidating fingerprints is unverified**, and checking out a worktree gives sources a newer mtime than the cloned outputs, so workspace crates rebuild (that's wanted). Community tools hit exactly this mtime trap ([zccache, farhand-workspace, cargo-turbo sources](https://docs.rs/crate/cargo-turbo/latest)) | **Most promising; top benchmark item.** No Windows equivalent outside Dev Drive |
| **cargo-turbo 0.4** (Aug 2026) | A wrapper with target snapshots and a shared store of third-party units. Published over two days, early ([docs.rs](https://docs.rs/crate/cargo-turbo/latest)) | Watch |
| **Cargo cross-workspace cache** | 2026 goal, nightly only, and the first version **excludes build scripts and proc macros** ([goal](https://goals.rust-lang.org/2026/cargo-cross-workspace-cache.html)) | Not before 2027 for a game tree, which is full of both |
| **Relink Don't Rebuild** | Lands on nightly "with limitations" in 2026; stabilization is a 2027 goal ([roadmap](https://goals.rust-lang.org/2026/roadmap-fast-builds.html), [rust#155871](https://github.com/rust-lang/rust/pull/155871)) | Would help incremental a lot, later |
| **Parallel front end** | Still nightly; the 2026 goal is to *start* stabilizing ([goal](https://goals.rust-lang.org/2026/parallel-front-end.html)) | 20–30% claimed, later |

**Proc-macro cost.** Every derive (`serde`, `bytemuck`, `thiserror`, `bevy_reflect`, `encase`, our registry) means a
proc-macro crate, which sccache never caches, plus `syn` (cached). Proc macros also re-run during incremental
builds of every crate that uses them. One `ts-rs` feature alone added 33% to a clean build (above). Bevy's tree
carries dozens of derive crates **[unverified count]**.

**Realistic best practice.** Per-worktree `target/`, seeded by an APFS clone of a warm main build. sccache with
`SCCACHE_BASEDIRS` for C/C++ and dependency rlibs. `cargo-hakari` to stop feature-variant duplication. A build
queue (one `flock`) so four agents don't thrash 14 cores. `CARGO_INCREMENTAL=0` for one-shot test runs. This is all
plausible and **none of it is proven** for Bevy on a Mac. Zig and Odin don't need any of it.

## 3. C/C++ interop and bindings

The mechanics are fine: `extern "C"`, `#[repr(C)]`, `bindgen` (generates Rust from headers), `cbindgen` (the
reverse), `cc`/`cmake` in `build.rs`, and `cxx`/`autocxx` for C++. The friction is elsewhere:

1. **Two layers per library.** A raw `-sys` crate is all `unsafe`, `*mut`, `CStr` and
   `Option<unsafe extern "C" fn>`. A safe wrapper is where the real work lives: lifetimes, `Send`/`Sync`,
   callbacks that capture state, RAII for `*_Release`. Odin and Zig call the C API directly with almost no ceremony.
2. **Community crates lag and have one maintainer.** You depend on someone else's wrapper's opinions and version,
   or you vendor it. `[patch]` makes vendoring easy, but then you own it.
3. **Agents have to learn the wrapper,** not the vendor's C docs, and wrappers are thin in training data.
4. **Build complexity**: libclang for bindgen, CMake for C++, and redistributable DLLs placed next to the binary.

| Library | Rust route (version, date) | Effort |
|---|---|---|
| **Box3D** (C) | `boxddd` 0.4.0 (2026-08, vendored C via `cc`, pregenerated bindings, "experimental"); `box3d` 0.3.1 (another author); `box3d-rust` pure port claims bit-exact | Low to write raw; young wrappers track an alpha engine |
| **Rapier** | Native | None |
| **libgodot / GDExtension** | GDExtension: `godot` 0.5.5 (2026-08), mature, generated from Godot's class DB, MPL-2.0; v0.5 broke the API in early 2026. **LibGodot (Rust hosts Godot): not supported**, gdext [#1488](https://github.com/godot-rust/gdext/issues/1488) open, "help wanted"; third-party `libgodot` 0.1.0 (2026-10-23, 13 downloads) | GDExtension low; LibGodot high (write it) |
| **Bevy** | Native | None |
| **sokol** | Official auto-generated `floooh/sokol-rust`, **git dependency only** (crates.io `sokol` is from 2019), examples partly ported | Low–medium |
| **SDL3 (GPU)** | `sdl3` 0.22.0 (2026-11-02) with GPU examples; `sdl3-sys` generated | Low |
| **wgpu-native** | Not needed: `wgpu` 30.0.1 is the Rust original | None |
| **raylib** | `raylib` 6.0.0 (2026-06) | Low |
| **bgfx** | `bgfx-rs` 0.20 (2024-03), stale | Medium (regenerate) |
| **Filament / The Forge** | No maintained Rust bindings found; C++ APIs need `cxx` or a C shim | High |
| **Dear ImGui** | `dear-imgui-rs` 0.22.0 (2026-10-31, docking, wgpu backend); `imgui-rs` stale (2024) | Low |
| **Clay** | `clay-layout` 0.4.0 (2025-06), lags Clay; bindgen of one header is trivial | Low |
| **egui** | Native | None |
| **RmlUi** | No Rust crate found | High (C++) |
| **NoesisGUI** | `noesis_runtime` 0.14 (2026-10) + `noesis_bevy`, third-party, "mostly written by AI agents" | Medium; paid SDK |
| **PanGui** | No public API known **[unverified]** | — |
| **miniaudio** | Rust crates stale (2020); use `cpal`/Kira, or bindgen it | Low–medium |
| **FMOD** | `libfmod` generated but stuck at FMOD 2.02.22 (2024-10); **`fmod-oxide` 0.2.2** (2026-07, hand-written); `fmod-core-sys` 1.0.2 supports 2.03; `bevy_fmod` 0.10. Dynamic linking only (licence) | Medium |
| **Kira** | Native, 0.12.6 (2026-10-28) | None |
| **SoLoud** | `soloud` 1.1.1 (2025-05) | Low |
| **Steam Audio** | `audionimbus` 0.16.2 (2026-11-03), active, auto-downloads SDK | Low |
| **Steamworks** | `steamworks` 0.13.1 (2026-05, SDK 1.64), `steamworks-sys` 0.13.0 (bindgen); one main maintainer; networking sockets bound (doc 05). `bevy-steamworks` 0.17 still on Bevy 0.19 | Low–medium; callback pumping and threading untested (doc 05) |
| **EOS C SDK** | `eos-sys`/`eos-rs` 0.1.1 (2026-04, **340 downloads**), pregenerated raw bindings, SDK not bundled | High: callback-heavy async API; plan to write our own safe layer for P2P only |
| **GameNetworkingSockets** | `game-networking-sockets` 0.3.0 (2026-09); build needs protobuf, OpenSSL, abseil, vcpkg on Windows | Medium (the C++ build is the cost) |
| **ENet** | `enet` 0.3 (2022), stale; pure-Rust alternatives exist | Low (own UDP or quinn instead) |
| **QUIC** | `quinn` 0.11.12, pure Rust, datagrams | None |
| **cgltf / gltf** | `gltf` 1.4.1 (2024, slow-moving but complete) | None |
| **zstd / xxHash / Tracy** | `zstd` 0.14.3 (wraps C via `cc`), `xxhash-rust` 0.8.19 (pure Rust), `tracy-client` 0.19 (pin with the Tracy GUI version) | None |

**Verdict.** For *this* list Rust is better off than the brief feared: most libraries have a current crate, and the
three biggest (physics, renderer, QUIC) are native. The real friction is concentrated in **EOS** (write it),
**LibGodot** (write it), **FMOD** (pick among three half-maintained crates), and **young Box3D wrappers**. In
Odin or Zig each of those is "import the header and call it", and a Steam/EOS-style callback API is *less* code
without Rust's ownership rules. In Rust it's a raw `-sys` layer plus a wrapper that holds `unsafe` invariants.

## 4. Determinism and memory model

- **Floats.** Rust never contracts `a*b+c` to FMA or reassociates without explicit `mul_add`/opt-in, and has no
  fast-math flag. IEEE `+ - * / sqrt` are bit-identical across our targets. The trap is `f32::sin` and friends: the
  docs say precision "varies by platform, Rust version" ([std](https://doc.rust-lang.org/std/primitive.f32.html#method.sin)).
  Use the `libm` crate and ban std transcendentals and `mul_add` with clippy `disallowed-methods`. NaN payloads are
  nondeterministic (RFC 3514): treat NaN as a bug. **C dependencies are the hole**: they need `-ffp-contract=off`.
- **Pointer-free block.** This is where Rust shines. `#[derive(Pod, Zeroable)]` from `bytemuck` refuses, **at compile
  time**, any type containing a reference, `Box`, `Vec`, `String` or **padding bytes**. That last one matters: in
  C/Odin/Zig, uninitialized padding silently poisons a checksum of the block unless every write path zeroes it. A
  snapshot is `bytemuck::bytes_of(&state).to_vec()`; a checksum is `xxh3(bytes)`. Zero-init is `Zeroable::zeroed()`.
- **Allocators.** Global allocator by default; custom allocators are still unstable (`allocator_api`), so a sim
  arena means fixed-capacity tables we write rather than `Vec<T, A>`. With a Pod block there is no allocation in the
  sim anyway.
- **Borrow-checker friction.** Systems that mutate several tables of one `&mut State` need split borrows, index-based
  access or a small "query" helper. It's solvable (doc 02), but it's where agents spend compile cycles.
- **Physics.** Rapier's snapshot is `serde` (bincode), not a memcpy, so it lives beside the block through a
  `SnapshotPart` trait. Its cost is unmeasured.
- **Agent bugs.** Safe Rust removes use-after-free, double free, data races, and uninitialized reads, and debug builds
  trap integer overflow and out-of-bounds indexing. Remaining risks: `unsafe` at FFI seams (Steam/EOS callbacks,
  `Pod` casts), logic bugs, `HashMap` iteration order (clippy ban), and panics.

## 5. Metaprogramming and reflection

The registry needs: field names, offsets and types per component (inspector, desync diff), stable IDs and a schema
hash (snapshots, protocol), serialization (replays, tuning write-back to RON/TOML), and editable sliders.

- **Options:** our own `#[derive(Component)]` proc macro emitting a `const` field table; `bevy_reflect` 0.20 (works
  standalone, but heavy and tied to Bevy's cadence); `facet` 0.46 (general reflection via derive); `serde` for
  text formats; or a `macro_rules!` component declaration macro, which needs no `syn` and costs almost nothing to
  compile.
- **Strengths:** derives are idiomatic, agents write them fluently, and `const` evaluation can compute layout hashes at
  compile time. `bytemuck` + `offset_of!` (stable) gives exact offsets for a byte-level desync diff.
- **Weaknesses:** no built-in reflection or comptime. Every derive is a proc macro that is compiled per worktree,
  never cached by sccache, and re-expanded on incremental builds. Proc-macro errors are poor, and agents debugging a
  `syn`-based macro is expensive. Zig's `comptime` and Odin's built-in RTTI (`type_info_of`) give the same registry
  with no extra crate and no build cost. **My pick:** `macro_rules!` for component declaration plus `serde` derive
  only where text I/O needs it.

## 6. Ecosystem fit per subsystem

| Subsystem | What exists | What we'd write |
|---|---|---|
| Physics | Rapier native; Box3D via young bindings | The `SnapshotPart` seam, sorting query results |
| Rendering | Bevy (strong, churny); wgpu (excellent, low-level); Godot via gdext; SDL3 GPU, sokol, raylib | Toon material, probe baker (doc 03) on Bevy; *everything* on wgpu |
| Game UI | `bevy_ui` + BSN + `bevy_flair`; Noesis (third-party, paid); Blitz (watch) | Juice kit; on wgpu, a UI layer |
| Dev UI | **egui** (best-in-class immediate-mode tools, `egui_plot`, docking) | Inspector over our registry |
| Audio | Kira, Firewheel/seedling, `audionimbus`; FMOD via crates | Rollback-aware sound events |
| Netcode | `quinn`, `steamworks`, GNS crate; GGRS and lightyear for reference (not our model) | Relay, protocol, netsim, EOS bindings |
| Profiling | `tracy-client`, `tracing` + `tracing-tracy`, `puffin` | — |
| Testing | `cargo test`, `nextest`, `proptest`, `insta` snapshots, doc-tests | Replay harness |
| Hot reload | `subsecond` / Bevy hot-patching (tip crate only), cdylib reload, shader/asset watch | Restart + replay (doc 04) |

## 7. Language stability, maturity, long-term support

- **Language:** 1.0 in 2015; a strong backwards-compatibility promise; editions (2015/2018/2021/2024) opt in to
  breaking syntax per crate and interoperate. Six-week releases rarely break code. **Language score: 5.**
- **Governance:** the Rust Foundation (Microsoft, Google, AWS, Huawei, Meta members) plus project teams; huge
  contributor base; bus factor is not a concern.
- **Bevy:** pre-1.0; 0.17 (Sep 2025), 0.18 (Jan 2026), 0.19 (Jun 2026), 0.20 (Oct 2026), each with a migration
  guide, and the 0.20 guide was still partly a placeholder ([migration guide](https://bevy.org/learn/migration-guides/0-19-to-0-20/)).
  Ecosystem lag: `bevy_seedling` 0.8 and `bevy-steamworks` 0.17 are still on 0.19. Bevy Foundation, paid
  maintainers, 200+ contributors per release (doc 03). No 1.0 date.
- **Other churn:** egui breaks yearly-ish (0.37 now); wgpu is on major 30; gdext broke at 0.5.
- **Shipped games:** few. Tiny Glade (2024, bevy_ecs plus a custom Vulkan renderer, 600k+ copies in a month
  [unverified, secondary](https://news.hada.io/topic?id=17872)) is the flagship. I found no list of 2025–26
  commercial 3D games on Bevy's renderer. Embark used Rust heavily in research **[unverified]**.

## 8. Tooling and developer experience

- **LSP:** rust-analyzer is excellent, but heavy: in each worktree it runs its own `cargo check` and proc-macro
  server, and sharing the target dir with cargo means waiting on the build lock. With five worktrees open, that's
  five of them.
- **Debugger:** LLDB on macOS (CodeLLDB in VS Code) works but shows generics and enums poorly; RustRover's debugger is
  better. Windows: MSVC debugger/WinDbg with PDBs is good.
- **Tests:** `cargo test` built in, `nextest` (a process per test), `insta`, `proptest`. Excellent.
- **Packages:** Cargo + crates.io: the best package manager among the candidates, with lockfiles, features and
  `[patch]` for vendoring.
- **Errors:** best-in-class compiler diagnostics with fix suggestions that agents apply well.
- **AI fluency:** the large corpus helps. But a 2026 benchmark found Rust has "the highest proportion of
  non-compilation outcomes" of the languages it measured ([PROBE, arXiv 2607.13820](https://arxiv.org/pdf/2607.13820)), and
  ownership/borrowing violations are over 40% of generated-code compile errors
  ([Strand report](https://huggingface.co/blog/Fortytwo-Network/strand-rust-coder-tech-report)). The upside is that
  these errors surface at compile time rather than as runtime bugs. The downside is that every round trip costs a
  compile, which is Rust's weak spot. Bevy adds stale-API problems: agents write 0.12–0.15-era Bevy (doc 03).

## 9. Platforms

- `aarch64-apple-darwin`, `x86_64-pc-windows-msvc` and `x86_64-unknown-linux-gnu` are all Tier 1. The Deck is Linux
  x86-64. wgpu maps to Metal, DX12/Vulkan and Vulkan.
- Cross-compiling pure Rust is easy (`cargo-zigbuild`, `cargo-xwin`), but `-sys` crates with C++ and CMake
  (GNS) make cross builds painful, so CI builds natively per OS.
- Consoles: Rust runs on them under NDA toolchains (studios have done it) **[unverified details]**. Bevy and wgpu
  have no official console backends. Godot has third-party console ports, which favours the gdext variant.

## 10. Feasibility for unified

**Easy in Rust:**
- The Pod state block, enforced by the compiler (no pointers, no padding).
- Safe agent-written gameplay and no memory corruption hunts.
- Native physics (Rapier).
- egui dev tools.
- quinn, Kira, Steam.
- One language from sim to renderer (Bevy), and the best package manager and test tooling.
- Much of docs 01–08 is already designed around it.

**Hard in Rust:**
- **Build cost per worktree.** Clean builds are minutes, not seconds, and every mitigation (APFS clone, sccache base
  dirs, cargo-turbo) is unproven or partial. The upstream fixes (cross-workspace cache, RDR, parallel front end)
  land in 2027 at the earliest. With agents working in parallel, that is a tax on every task.
- **Bevy churn.** About three upgrade passes a year, plus lagging crates and stale agent knowledge.
- **The C seams that aren't pre-bound:** EOS, LibGodot, FMOD 2.03. These need a safe-wrapper discipline that Odin
  and Zig don't ask for.
- **Proc-macro-based reflection** costs build time; comptime or RTTI languages get it free.

**Work we own that others get free:**
- Vs Zig: a global C build cache and trivial C imports.
- Vs Odin: built-in RTTI, and `vendor:` packages (raylib, SDL3, Box2D, miniaudio, cgltf) without wrapper crates.
- Vs C++: direct Godot and Filament.

**Work others own that Rust gets free:**
- Rapier, Bevy, egui, Kira, quinn, wgpu.
- Compile-time memory safety and Pod enforcement.
- Cargo.

**Biggest risks:**
1. Worktree cold builds stay at 1.5–3 minutes even with mitigations, and N agents saturate the CPU. Mitigation:
   seed by APFS clone, queue builds, keep agents in the sim crate where builds are seconds.
2. The Bevy upgrade treadmill.
3. Borrow-checker and compile round-trips slow agents more than Rust's safety saves them. That's unmeasured, and the
   benchmark should time agent tasks end to end, not just compiles.

**Fallback if builds are the deal-breaker:** keep Rust for `sim`/`net` (small, fast, safe) and pair it with the
lean wgpu host or Godot. This shrinks the clean build to roughly a minute, at the price of writing more rendering.

## 11. Scorecard

Scores are for Bevy (host A) unless a row notes that host B is better.

| Criterion | Score | Justification |
|---|---|---|
| Clean build | **2** | Bevy stack ~90–180 s on an M4 Pro **[estimate]**; lean wgpu ~45–80 s (would be 2–3); nothing gets near 30 s without a warm cache |
| Incremental build | **3** | Sim edit + tests 1–4 s; client relink 2–6 s only with `dynamic_linking` (7–25 s without, per a real M1 Pro project) |
| Worktree parallelism | **2** | Per-worktree `target/` duplicates GBs and minutes; shared dirs serialize on Cargo's lock; sccache skips proc-macros, dylibs, bins and incremental crates; the fixes are nightly or 2027 |
| C/C++ interop | **3** | Current crates exist for most of the list, but each is a `-sys` + wrapper pair with one maintainer; EOS and LibGodot are ours to write; C deps need FP flags through `build.rs` |
| Determinism control | **4** | No implicit FMA or fast-math, `libm` crate, clippy bans; traps are std transcendentals and C dependencies |
| Arena / snapshot fit | **4** | `bytemuck::Pod` enforces no pointers or padding at compile time; borrow-checker friction on multi-table writes; Rapier snapshot is serde, not memcpy |
| Safety vs agent bugs | **5** | Safe Rust rules out UAF, races and uninitialized memory; debug overflow and bounds traps; `unsafe` confined to FFI seams |
| Reflection / metaprogramming | **3** | Derive macros work and agents know them, but there's no built-in RTTI or comptime, and proc macros cost uncached build time |
| Rendering host options | **4** | Bevy is a real renderer (no GI baker), wgpu, Godot via mature gdext; no LibGodot, Filament or Forge bindings; Bevy churn |
| Physics options | **4** | Rapier native; Box3D via young bindings |
| Netcode / transports | **4** | quinn native, `steamworks` current, GNS crate; EOS bindings effectively absent |
| UI options | **4** | egui is the best dev-UI option anywhere; game UI on bevy_ui is workable but churny; no RmlUi; Noesis third-party |
| Language stability | **5** | 1.0 since 2015 with editions and a compatibility promise (Bevy itself would score 2) |
| Maturity / long-term support | **4** | Huge community and foundation funding; few shipped Rust games; Bevy pre-1.0 |
| Tooling / DX | **4** | Cargo, rust-analyzer, nextest and diagnostics are excellent; LLDB is middling on macOS; rust-analyzer per worktree is heavy |
| AI agent fluency | **4** | Large corpus and strong diagnostics, but the highest non-compiling rate in a 2026 benchmark, and stale Bevy APIs |
| Platforms | **4** | Tier 1 on all three targets; consoles possible but DIY (Godot variant better there) |
