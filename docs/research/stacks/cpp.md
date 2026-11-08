# Stack: C++ (orthodox, C-style C++20; C where it fits)

Researched 2026-11-07. **(unverified)** marks claims not confirmed from a primary source; **(estimate)** marks
numbers derived by reasoning, not measured. Facts reused from docs 01–08 link back to them.

The case in one paragraph: almost every library `unified` wants is already C or C++ (Jolt, Box3D, Godot, Dear ImGui,
RmlUi, NoesisGUI, Steamworks, EOS, GameNetworkingSockets, Tracy, miniaudio). In C++ none of them needs a binding,
a wrapper or a lagging community crate, and one compiler and one set of float flags cover the sim *and* the physics.
What you pay is the weakest compile-time safety of the five stacks, a build and package story you assemble yourself,
and slower builds unless the code is written in a disciplined "orthodox C++" style.

## 1. Best realistic setup

- **Language/toolchain**: C++20, written in an orthodox style. That means plain structs and functions, no
  exceptions or RTTI in the sim, few templates, no STL containers in sim state, and `<vector>`/`<string>` only in
  tools and view code. Use **one pinned upstream LLVM/clang on every platform** (for example LLVM 21 or 22): clang
  on macOS and Linux, clang-cl on Windows. One compiler family and one version means one codegen and one set of
  flags. MSVC stays a CI cross-check, as in Box3D's CI ([build.yml](https://github.com/erincatto/box3d/blob/main/.github/workflows/build.yml)).
  Pure C17 for sim modules that agents might otherwise over-engineer is an option, but C++ gives `static_assert`,
  `constexpr`, templates for typed queries and namespaces at little cost.
- **Sim state store**: the Quantum model from doc 02, in C++. One arena block holds sparse-set component tables,
  generational handles, globals and inline fixed-capacity collections. Snapshot = `memcpy`, checksum = XXH3 over
  the block. Systems are plain functions over typed queries (`for (auto [e, pos, vel] : q.each<Pos, Vel>(f))`).
- **Physics**: **Jolt 5.6** used directly in C++ (`CROSS_PLATFORM_DETERMINISTIC`, `CharacterVirtual` for
  wall-crawling) or **Box3D** (C17), raced in the physics spike exactly as in doc 01. In C++, Jolt is no longer
  "the fallback behind a C wrapper": it is native, and its `StateRecorder`/`CreateBodyWithID` lifecycle work
  (doc 01) is written against its real API. Rapier is reachable only through its C bindings, so it drops out.
- **Host/renderer**: **Godot 4.7 (4.8 when stable) with the game as a GDExtension written against `godot-cpp`**,
  Godot's official C++ binding ([docs](https://docs.godotengine.org/en/4.7/tutorials/scripting/cpp/about_godot_cpp.html)).
  It runs on a stock prebuilt engine binary: no engine compile. The sim and net live in a plain static library with
  no Godot includes. The view is a thin GDExtension layer that maps sim handles to Godot nodes or `RenderingServer`
  RIDs (Godot's own physics stays unused). **Variant B** (if Godot owning the main loop hurts): **LibGodot** (shipped in 4.6). Our
  executable owns `main`, creates the one-per-process `GodotInstance` through `libgodot_create_godot_instance` and
  calls `iteration()` itself ([class docs](https://docs.godotengine.org/en/4.7/classes/class_godotinstance.html)).
  **Variant C** (a code-first renderer library): Wicked Engine (MIT, Metal 4 on macOS since 0.72.0 in Jan 2026,
  [devlog](https://turanszkij.itch.io/wicked-engine/devlog)), with a bus factor of one.
- **Game UI**: Godot `Control` nodes plus our own reactive layer, or **RmlUi 6.2** (HTML/CSS-like with data
  binding; in [vcpkg](https://vcpkg.io/en/package/rmlui.html)). **NoesisGUI** (native C++ SDK, €195 indie, doc 06)
  if we want XAML-grade animation. **PanGui** gets re-evaluated when its C++ transpile is public (doc 06).
- **Dev UI**: **Dear ImGui 1.92.x** ([v1.92.9](https://github.com/ocornut/imgui/releases/tag/v1.92.9)), native,
  via [imgui-godot](https://github.com/pkdawson/imgui-godot) or our own small Godot renderer backend. Docking,
  ImPlot and ImGuizmo give the inspector, timeline scrub and netsim panel.
- **Audio**: Godot's `AudioServer` first. miniaudio or SoLoud if we go hostless, Steam Audio (C API) for spatial
  audio. FMOD only if it earns its licence.
- **Networking/transports**: our relay and rollback core (doc 05) in C++, with a `Transport` interface:
  in-process loopback with a netsim; UDP (plain sockets, or GameNetworkingSockets over direct IP for the
  self-hosted relay); **Steamworks `ISteamNetworkingSockets` over SDR**, used through the native C++ headers; and
  later the EOS C SDK.
- **glTF loading**: **cgltf** (single-header C) in the sim-side level loader (colliders, entity kinds, extras), and
  Godot's `GLTFDocument` at runtime for view meshes, so there is no editor import step.
- **Build system**: **CMake 4.x + Ninja**, `CMAKE_UNITY_BUILD` for our modules, a PCH for view TUs that include
  `godot-cpp`, ccache with `base_dir`, and third-party libraries prebuilt once per toolchain into a shared prefix
  outside the worktrees (vcpkg manifest mode with binary caching, or our own `deps/` script). Linkers: ld-prime
  (Xcode default) on macOS, lld-link on Windows, mold or lld on Linux.

## 2. Build speed

No measurements exist for this exact layout. Everything below is an **estimate** for an M4 Pro, reasoned from
library sizes and the published mechanisms. The build-speed spike must measure it.

**Third-party code is built once, not per worktree.** C++'s strongest build property for agent worktrees is that a
dependency is a binary artifact (`.a`/`.lib` plus headers) whose path is independent of the worktree. Build Jolt,
Box3D, godot-cpp, ImGui, GameNetworkingSockets, zstd and the rest once per (toolchain, flags, version) hash into
`~/.cache/unified/deps/<hash>/`, or let vcpkg's binary cache do it. Every worktree then links against that prefix.
Cargo's per-`target/` dependency builds (doc 04) have no equivalent cost here.

| Item (one-time per toolchain unless noted) | Estimate | Reasoning |
|---|---|---|
| Godot engine | **0 s** (official prebuilt binary, GDExtension path) | `godot-cpp` doesn't require compiling the engine ([docs](https://docs.godotengine.org/en/4.7/tutorials/scripting/cpp/about_godot_cpp.html)) |
| LibGodot shared library (variant B) | 10–25 min, once per Godot version | about 1.5M+ lines of C++ via SCons **(estimate)**; no official prebuilt libgodot found **(unverified)** |
| godot-cpp | 2–5 min | binds the whole class DB **(estimate)** |
| Jolt | 1–2 min; Box3D under 15 s | ~250 TUs vs a small C17 codebase **(estimate)** |
| GameNetworkingSockets + protobuf/crypto | several minutes | doc 05 calls this build "real work on three OSes" |

**Our code.** Assume 40–60k lines after the slice (engine plus game), compiled as ~10–20 unity TUs.
- **Clean, fully cold** (no ccache, deps already prebuilt): 20–45 s **(estimate)**. View TUs that include
  `godot-cpp` headers dominate. godot-cpp's headers are large, so a PCH matters.
- **Fresh worktree**: deps come from the shared prefix (0 s). Our TUs get ccache hits because `base_dir` rewrites
  absolute paths to relative ones in the hash ([ccache manual](https://ccache.dev/manual/latest.html), v4.14.2).
  Then a link of about 1 s. Expect **5–15 s** when a sibling worktree has built the same commit recently, and the
  cold number when not. Caveats: ccache's PCH support needs `sloppiness=pch_defines,time_macros`, and standard
  C++20 modules are not cached at all (same manual).
- **Incremental, one-line sim change**: recompile one unity TU of the sim (~3–6k lines, light headers) in about
  1–2 s, plus a relink of the game library: under 1 s with ld-prime, which Chromium measured as much faster than
  lld for local arm64 links ([Chromium linker doc](https://chromium.googlesource.com/chromium/src.git/+/main/docs/apple_platform_linkers.md)).
  **About 2–3 s** **(estimate)**. A view change touching a godot-cpp-heavy TU costs 3–6 s. A header change in a
  core sim type rebuilds every TU that includes it: 10–30 s.
- **Unity-build trade-off**: fewer TUs make clean builds fast but make incremental builds coarser. Group by module,
  keep unity batches to ~5k lines, and exclude hot gameplay files from batching while they're being edited (CMake
  `SKIP_UNITY_BUILD_INCLUSION`).
- **Modules don't help yet.** `import std` landed in CMake 4.3 for specific toolchains and only with Ninja
  ([cmake-cxxmodules](https://fuchsia.googlesource.com/third_party/github.com/Kitware/CMake/+/2d262efd296dfd1802631978d9b9ab23fdf135a4/Help/manual/cmake-cxxmodules.7.rst)).
  Clang tooling still needs hand-holding, and ccache doesn't cache them. Plan on header hygiene, PCH and unity
  builds.
- **Build discipline is a real, ongoing cost.** C++ build time is mostly decided by include graphs. Agents add
  `#include <algorithm>` or `<functional>` to a core header without noticing. Mitigations: a CI check on include
  depth/time (`-ftime-trace` + ClangBuildAnalyzer), a "no STL in sim headers" lint, and forward declarations.

## 3. C/C++ interop and bindings

| Library | How we'd use it from C++ | Effort |
|---|---|---|
| Box3D (C) | Direct `#include`; compile with our flags | None |
| Jolt (C++) | Direct, native API; no JoltC needed | None (lifecycle glue is ours anyway) |
| Rapier (Rust) | Its in-repo C bindings + a Rust toolchain in the build | Medium; two compilers back in play |
| libgodot / GDExtension | `godot-cpp` (official, generated from `extension_api.json`), or the GDExtension C API directly; LibGodot's C entry point for embedding | Low (official, first-class) |
| Bevy | Not reachable | — |
| sokol, SDL3 GPU, raylib, bgfx | Native C/C++ headers | None |
| wgpu-native | `webgpu.h` C header | Low |
| Filament, The Forge | Native C++ (The Forge: C-style API) | Low to bind, high to build a renderer on |
| Dear ImGui | Native; cimgui unnecessary | None |
| Clay | Single C header | None |
| egui | Not reachable | — |
| RmlUi | Native; we write the render/input backend (or a Godot backend) | Medium |
| NoesisGUI | Native C++ SDK; RenderDevice for our renderer, or a texture via Godot | Medium |
| PanGui | Only a C++ transpile is announced; not public (doc 06) | Unknown |
| miniaudio, SoLoud, FMOD, Steam Audio | Native C/C++ APIs | None |
| Kira | Not reachable | — |
| Steamworks | Native C++ headers (the flat API is for other languages) | None |
| EOS C SDK | Native C | Low |
| GameNetworkingSockets | Native C++; builds need protobuf + OpenSSL/libsodium; symbols may clash next to `steam_api` **(unverified, doc 05)** | Medium (build only) |
| ENet | Native C | None |
| QUIC | msquic (C API), quiche (C API over Rust), ngtcp2 (C) | Low–medium |
| cgltf, zstd, xxHash, Tracy | Native | None |

The only libraries out of reach are the Rust-only ones: Bevy, egui, Kira and Rapier's native API. Everything else
is a CMake `add_subdirectory`/vcpkg line. Upstream fixes land on day one, with no binding to wait for. Doc 03's
"Godot is a bridge" objection also weakens. From C++ there is no FFI layer and no second object model in a second
language, only Godot's object model next to our sim.

## 4. Determinism and memory model

**Float control.** C++ gives full per-TU control, and the defaults are wrong, so the build must set them:
- **FMA contraction**: clang contracts by default (`-ffp-contract=on`) since v14, and that bites on ARM64. GCC
  defaults to `fast`. MSVC stopped contracting under `/fp:precise` only in VS2022 (doc 01). Set
  **`-ffp-contract=off`** (clang-cl: `/clang:-ffp-contract=off`) as Box3D's CMake does, and never use
  `-ffast-math` or `/fp:fast`. Because we compile Jolt and Box3D ourselves with the same toolchain file, one
  setting covers sim and physics uniformly. A Rust stack mixes rustc's semantics with clang's for C deps.
- **libm**: ban `std::sin`/`cos`/`atan2`/`exp`/`pow` in sim code (a clang-tidy check plus a header that `#error`s
  on `<cmath>` in sim TUs). Use Jolt's `Sin`/`Cos`/`ATan2` or Box3D-style hand-written approximations in one math
  module.
- **Proven in production**: Jolt verifies `CROSS_PLATFORM_DETERMINISTIC` on 14 configurations, and Box3D checks one
  set of goldens across macOS ARM, Windows x64 (MSVC *and* clang-cl) and Linux at -O0 and -O2 (doc 01). Both are
  C/C++ codebases built with exactly the flags above, which makes this the strongest existence proof of any stack.
- **C++-specific traps**: `std::sort` and `std::hash` differ per STL, so use our own stable sort and fixed hashes.
  Uninitialized locals and members hold garbage that can differ per run: use `-ftrivial-auto-var-init=zero` plus
  default member initializers. **Padding bytes** poison a checksum over the block. `memset` the arena at creation,
  build with `-Wpadded` on sim types, or hash per field through the registry. **UB is nondeterminism**: signed
  overflow, strict-aliasing violations or out-of-bounds reads can be optimized differently by two compilers or two
  optimization levels, producing a desync no float flag explains. Thread-local FP environment (FTZ/DAZ set by
  middleware): assert it at sim-thread start (doc 01).

**Arena fit.** This is C++'s home ground. A `struct World { Header h; Table<Pos> pos; ... }` inside one aligned
block, `static_assert(std::is_trivially_copyable_v<T> && std::is_standard_layout_v<T>)` on every component, handles
as `u32 index + u32 generation`, and `memcpy` snapshots are idiomatic. Game devs have written this for 25 years
(Quantum's own frame layout is the same idea). Allocators are explicit: a linear frame allocator for per-tick
scratch, and the persistent block. Nothing allocates behind your back unless you include the STL. **What the
language doesn't do**: it won't stop a raw pointer or a `std::vector` member from entering a component. A trivially
copyable type can still hold a `T*`. The registry (section 5) closes this by iterating each component's fields at
compile time and `static_assert`ing that none is a pointer, reference or non-registered type.

**Safety vs agent bugs.** The weak spot, and the honest headline. Use-after-free (a reference into a table kept
across an insert), iterator invalidation, out-of-bounds on fixed arrays, uninitialized fields, signed-overflow UB,
ODR violations and data races all compile cleanly. A 2026 study found AI-generated C++ "roughly twice as likely as
human code to trigger a confirmed runtime violation", with static analysis blind to the difference
([Mahmud et al., arXiv 2607.00107](https://arxiv.org/abs/2607.00107)). Mitigations, all cheap, none at compile time:
- An **ASan + UBSan** build of the headless test runner on every agent run (clang on all three OSes; MSVC has ASan
  only). TSan on macOS/Linux for the relay thread.
- **libc++ hardening "fast" mode** (`_LIBCPP_HARDENING_MODE_FAST`), which traps bounds errors in constant time
  ([libc++ docs](https://libcxx.llvm.org/Hardening.html)), plus our own bounds-checked `Span`/`FixedArray` in sim
  code.
- `-Wall -Wextra -Werror`, clang-tidy (bugprone, cppcoreguidelines subsets), `-Wunsafe-buffer-usage` in sim TUs.
- The design helps more than the language: handles instead of pointers turn UAF into a failed generation check, and
  **sync-test** catches most UB-driven divergence within frames of introducing it.

## 5. Metaprogramming and reflection

The registry has to drive the inspector, desync diff, serialization/protocol schemas and tuning write-back.

- **C++26 static reflection is real but unusable for us by late 2026.** WG21 shipped C++26 in March 2026 with
  P2996. **GCC 16.1** (30 Apr 2026) has it experimentally under `-std=c++26 -freflection`
  ([announcement](https://gcc.gnu.org/pipermail/gcc-announce/2026/000190.html), [isocpp](https://isocpp.org/blog/2026/04/gcc-16.1)).
  **Upstream clang does not**: only Bloomberg's fork, which calls itself "highly experimental"
  ([clang-p2996](https://github.com/bloomberg/clang-p2996)). Upstream parsing patches were in review in late 2025
  ([PR #164692](https://lists.llvm.org/pipermail/cfe-commits/Week-of-Mon-20251020/766710.html)), with no merge
  confirmed **(unverified)**. **MSVC** has no public support or ETA (secondary sources). GCC isn't our macOS or
  Windows compiler, so plan for reflection around **2027–28**, and design the registry so it can switch to it.
- **What works today, cheapest first**:
  1. **Aggregate reflection** à la **Boost.PFR**: `boost::pfr::names_as_array<T>()` and per-field access work on
     plain aggregates without macros ([PFR reference](https://www.boost.org/doc/libs/1_91_0/doc/html/reference_section_of_pfr.html)).
     PFR 1.91 already has a `BOOST_PFR_USE_CPP26_REFLECTION` switch, which is the migration path. Add magic_enum for
     enum names. Cost: template instantiation per type, a few hundred ms of compile per TU that instantiates the
     registry **(estimate)**. Keep it in one `registry.cpp`.
  2. **X-macros / a field-list macro** (`UNI_COMPONENT(Health, F(f32, hp) F(f32, max, Range(0,100)))`): zero
     template cost, and attributes (ranges, "tunable", "replicated") ride along. Ugly but explicit and very
     agent-legible.
  3. **Codegen** from a schema or a libclang scan: the most powerful, but it brings back the `.qtn`-style step
     CONTEXT.md wants gone.
- **Recommendation**: (1) for field names and types, (2)'s attribute macro only where metadata is needed, and the
  pointer-ban `static_assert` from section 4 driven by the same field iteration. Workable, and less elegant than
  Rust derives or Zig comptime.

## 6. Ecosystem fit per subsystem

- **Physics**: the best of any stack. Jolt native (AAA-proven, best character controller, deterministic
  cross-platform mode), Box3D native (strongest cross-arch CI; Catto said on 2026-07-25 that rollback snapshots
  "almost" work, [discussion](https://github.com/erincatto/box3d/discussions/99)). Box2D 3.2 already exposes
  `b2World_GetSnapshot`/`RestoreFromSnapshot` ([docs](https://box2d.org/documentation/group__snapshot.html)), the
  likely shape of Box3D's API. A small fork patch to Box3D is a C edit in our own tree. Note: Godot 4.6+ bundles
  Jolt as its default 3D physics. We'd run *our own* Jolt in the sim. Two copies in one process need hidden
  visibility (`-fvisibility=hidden`) to avoid symbol clashes on macOS/Linux **(unverified risk)**.
- **Rendering host**: the widest choice. Godot natively (official C++ bindings, prebuilt binaries, the OctoEscape
  look with least effort per doc 03), LibGodot embedding, Wicked Engine, Filament, Ogre-Next 3.0 (Metal/Vulkan/D3D11,
  [Phoronix](https://www.phoronix.com/news/OGRE-Next-3.0)), The Forge, plus bgfx, sokol and SDL3 GPU as lower
  layers. Only Bevy is missing, and Bevy is the strongest *code-first* option in doc 03. Godot's import cache
  (`.godot/` per worktree) and editor-only LightmapGI bake remain (doc 03).
- **Game UI**: RmlUi, NoesisGUI and Godot Controls are native. PanGui's C++ path is the most promising future
  option (doc 06).
- **Dev UI**: Dear ImGui is the gold standard and is native here. egui isn't needed.
- **Audio**: Godot audio, miniaudio, SoLoud, Steam Audio, FMOD, all native.
- **Netcode/transports**: Steamworks (native C++), EOS C SDK, GameNetworkingSockets, ENet, msquic: all native. The
  relay/rollback core is ours in every stack.
- **Profiling**: Tracy (native C++), Superluminal (Windows), Instruments (macOS).
- **Testing**: doctest or Catch2 with CTest, plus a headless test exe that links only `sim` + `net`. Replays as
  regression tests.
- **Hot reload**: **Live++ is Windows and consoles only** (Windows, Xbox, PlayStation; no macOS or Linux,
  [liveplusplus.tech](https://liveplusplus.tech/)). jet-live targets x86-64 Linux/macOS and was last pushed in 2022
  ([listing](https://awesome.ecosyste.ms/projects/github.com%2Fddovod%2Fjet-live)), so it doesn't fit Apple Silicon.
  The realistic macOS answer is **DLL/dylib reload**: gameplay systems in a reloadable library. The host owns the
  state block, so reload keeps state. This is the same shape as the Odin hot-reload template, and it works on all
  three OSes. Godot also reloads GDExtensions marked `reloadable` (4.3+ per the English docs,
  [.gdextension file](https://docs.godotengine.org/en/stable/engine_details/engine_api/gdextension/gdextension_file.html)).
  Configs, shaders (Godot) and RmlUi documents reload by file watch. Sim reload stays "rebuild, restart, replay"
  as in doc 04.

## 7. Language stability, maturity, long-term support

- **Stability**: an ISO standard with near-total backward compatibility. C++26 is published, C++20 is now GCC's
  default dialect ([GCC 16.1](https://linuxiac.com/gcc-16-1-released-as-first-gcc-16-series-release-with-c20-default/)).
  Code written in C++20 today compiles in 2036. Compiler upgrades occasionally break code at the margins (stricter
  diagnostics, `-Werror` fallout), and every upgrade can change float codegen, so pin the version (true of every
  stack).
- **Governance and funding**: WG21, plus three funded compiler vendors (LLVM with Apple/Google, GCC, Microsoft). No
  bus-factor risk at the language level.
- **Libraries**: Godot (foundation, the largest open-source engine), Jolt (one main author, used by Guerrilla and
  Godot), Box3D (one author, alpha), Dear ImGui (one main author, funded, ubiquitous). Library bus factors are the
  same for every stack. C++ just reaches them without a binding maintainer in between.
- **Shipped games**: essentially all of them, every AAA engine included.

## 8. Tooling and developer experience

- **LSP**: clangd is excellent with `compile_commands.json` (CMake emits it). Unity builds and PCH need care so
  clangd still indexes per file.
- **Debuggers**: Windows is best in class (Visual Studio, RAD Debugger, RemedyBG). macOS has LLDB (Xcode, VS Code
  CodeLLDB, CLion), which is solid but behind Visual Studio for data visualization. Linux has gdb/LLDB.
- **Tests**: doctest/Catch2/GoogleTest + CTest. Fine, but test discovery and filtering are less integrated than
  `cargo test`.
- **Package management: fragmented.** vcpkg (manifest mode + binary caching, the best fit for prebuilt shared deps),
  Conan 2, CPM.cmake and FetchContent all coexist. None is the default, and each has CMake integration quirks.
  Expect to vendor small single-header libraries and pin larger ones through vcpkg.
- **Build system**: CMake is powerful, but its configuration language is old, and agents write plausible CMake that
  subtly misplaces flags (for example `-ffp-contract=off` set on one target but not on a dependency). Mitigation: one
  toolchain file that forces global flags, and a CI check that greps the compile commands.
- **Error messages**: template errors are still long; concepts help. Orthodox C++ avoids most of this by avoiding
  heavy templates.
- **AI agent fluency**: the largest training corpus of any systems language, and Godot C++, Jolt, ImGui, Steamworks
  and Tracy all appear heavily in it. API churn is low (Godot 4.x and godot-cpp are stable; ImGui 1.92's font
  redesign is the biggest recent break). The problem is dialect spread (C++98 to C++23 idioms mixed) and footguns
  that compile: agents write code that builds and passes tests while carrying UB (section 4's 2× figure). An
  `AGENTS.md` style guide ("no STL in sim, no raw pointers in components, use `Span`, no `<cmath>` in sim") plus
  sanitizer runs is mandatory, not optional.

## 9. Platforms

- **macOS ARM**: first class (clang, Metal through Godot/Wicked/Filament). ld-prime is fast. No Live++.
- **Windows x64**: first class, and C++'s strongest platform (clang-cl or MSVC, PDBs, Visual Studio, Live++ if
  ever wanted).
- **Linux / Steam Deck**: first class (clang/GCC, mold), Steam Runtime SDK containers for Deck builds.
- **Cross-compilation**: clang can target all three, but in practice the macOS SDK and Windows SDK licensing push
  you to native CI runners (GitHub macOS ARM, Windows, Linux), which cross-platform checksum CI needs anyway.
- **Consoles**: the best path of any stack. Console SDKs are C/C++, Godot has console ports through vendors,
  Jolt/Box3D/ImGui all run there, and Live++ supports Xbox and PlayStation. This doesn't matter now, but it costs
  nothing to keep open.

## 10. Feasibility for unified

**What C++ makes easy**
- Every library is native and current on release day: physics, renderer host, UI, audio, Steam, EOS, Tracy. No
  binding layer, no `-sys` crate lag, no "bindings are immature" footnotes (EOS and GNS in doc 05 become non-issues).
- **Godot becomes a first-class host**, not a bridge to a foreign language. If the render spike shows Godot reaching
  the OctoEscape look with less work (doc 03's own verdict), C++ is the language that uses Godot best.
- The pointer-free block, memcpy snapshots and handle tables are idiomatic C/C++. Quantum-style frame code
  translates almost line for line.
- One compiler and one flag set for sim plus physics, with Box3D/Jolt as working proof of cross-arch determinism
  in exactly this toolchain.
- Worktrees: prebuilt deps in a shared prefix plus ccache `base_dir` is a well-trodden setup with no global build
  lock.

**What C++ makes hard**
- **Agent bugs that compile.** Memory and UB errors surface at runtime, sometimes as desyncs. We'd own a sanitizer CI
  lane, a hardened container library, lint rules and a strict style guide. A borrow checker or bounds-checked
  default would give much of this for free.
- **Build engineering is ours.** The CMake toolchain file, the deps cache, PCH/unity tuning and include hygiene. Rust
  gets Cargo, and Odin/Zig get a single-command build. Fast C++ builds are achievable but must be defended
  continuously against include creep.
- **Reflection is macro/template work** until clang ships P2996 (likely 2027+).
- **Hot reload on macOS** is DLL reload only. Live++ doesn't exist there.

**Work we'd own vs other stacks**: we'd write the registry macros and the safety tooling that Rust derives and the
borrow checker give for free. We would *not* write or maintain bindings for Jolt, Godot, ImGui, Steamworks, EOS or
GNS, which the Rust/Odin/Zig/C# stacks must wrap or depend on community wrappers for. We'd also lose Bevy, egui,
Kira and Rapier.

**Biggest risks**
1. Agent-introduced UB and memory bugs costing debugging sessions, mitigated by handles, sync-test and sanitizers,
   but not eliminated.
2. Build times drifting from ~2 s to ~20 s incrementals as agents grow headers. This is a process risk, not a
   technical limit.
3. Host choice: Godot's main-loop ownership, `.godot/` import cache and editor-only GI bake (doc 03), or LibGodot's
   youth (one instance per process, embedding still maturing,
   [migeran/libgodot](https://github.com/migeran/libgodot)).
4. The Jolt-inside-Godot symbol clash, and Godot's own Jolt being tempting to use (it isn't rollback-safe for us).

**Spike additions for this stack**: (a) a build-speed spike with CMake + Ninja + unity + ccache `base_dir` across 4
worktrees on the M4 Pro (pass: fresh worktree ≤ 30 s with a warm sibling, sim one-line change ≤ 3 s); (b) an ASan +
UBSan headless run of the determinism spike on macOS and Linux; (c) a minimal GDExtension that draws 300 Jolt
bodies from a pure-C++ sim block, with sync-test on.

## 11. Scorecard

| Criterion | Score | Justification |
|---|---|---|
| Clean build | 3 | With deps prebuilt in a shared prefix and ccache, a fresh worktree is ~5–15 s warm or 20–45 s cold (estimate). The first-ever deps build takes minutes (LibGodot 10–25 min), and caches are fragile to flag changes |
| Incremental build | 4 | A unity-batched, light-header sim TU plus an ld-prime relink is about 2–3 s (estimate), but it degrades fast if headers bloat |
| Worktree parallelism | 4 | Binary deps independent of worktree paths, ccache `base_dir` sharing and no global lock. Godot's `.godot/` cache and per-worktree object dirs still duplicate some work |
| C/C++ interop | 5 | Every listed library except the Rust-only ones is native; zero bindings to maintain |
| Determinism control | 4 | Full per-TU float control, with one toolchain for sim and physics proven by Jolt/Box3D CI. But the defaults contract FMA, and STL sort/hash, padding, uninitialized memory and UB are extra traps |
| Arena / snapshot fit | 4 | POD blocks, `memcpy` and handles are idiomatic. The language doesn't forbid pointers in components, so registry `static_assert`s must |
| Safety vs agent bugs | 2 | UAF, overflow UB and bounds errors compile cleanly. Sanitizers, hardening and sync-test catch them only at runtime (AI C++ ~2× runtime violations) |
| Reflection / metaprogramming | 3 | PFR aggregate reflection and X-macros work today. C++26 reflection exists only in GCC 16 and a clang fork, so not on our macOS/Windows compilers before ~2027 |
| Rendering host options | 5 | Godot natively (official C++ binding, LibGodot), Wicked, Filament, Ogre-Next, The Forge, bgfx/sokol; only Bevy is out |
| Physics options | 5 | Jolt and Box3D native, with the best character controller and the strongest cross-arch CI; fork patches are trivial |
| Netcode / transports | 5 | Steamworks, EOS C SDK, GameNetworkingSockets, ENet and msquic all native |
| UI options | 5 | Dear ImGui, RmlUi, NoesisGUI, Godot Controls and Clay all native; PanGui's C++ path is coming. Only egui is missing |
| Language stability | 5 | ISO standard, backward compatible, C++20 now a compiler default |
| Maturity / long-term support | 5 | Every compiler vendor funded, the largest community, nearly every shipped game |
| Tooling / DX | 3 | clangd and Windows debuggers are excellent and LLDB is good. Package management is fragmented, CMake is error-prone and template errors are rough |
| AI agent fluency | 4 | The largest corpus, and the target libraries are well represented with low churn. Mixed dialects and compiling footguns mean output needs sanitizer-backed review |
| Platforms | 5 | macOS ARM, Windows and Linux/Deck first class; consoles the most open of any stack |
