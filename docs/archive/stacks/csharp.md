# Stack: C# / .NET

Research date: 2026-11-07. Desk research only: nothing was installed or built. **[unverified]** marks claims from
memory or from one secondary source. **[estimate]** marks my own extrapolation, which a spike has to confirm. This doc
argues for C#'s best realistic setup and is just as direct about its problems.

**One-paragraph pitch.** C# is the language in which the design `unified` wants already exists and ships: Photon
Quantum is a C# simulation over an unmanaged frame heap of blittable structs, with code generation and memcpy-style
frame copies ([Quantum `Heap` API](https://doc-api.photonengine.com/en/quantum/current/struct_quantum_1_1_allocator_1_1_heap.html)).
OctoEscape's ~25k lines of Quantum simulation code are C# today, and they already build and test headless under plain
.NET outside Unity (`OctoEscape/docs/QUANTUM.md`, "Headless simulation"). The price is a float-determinism story that
rests on maintainer statements and CI rather than on a language spec, and a native renderer (Godot) reached across a
managed/native seam.

## 1. Best realistic setup

| Layer | Pick | Notes |
|---|---|---|
| Language / toolchain | **.NET 10 LTS** (Nov 2025, supported to Nov 2028, [SD Times](https://sdtimes.com/msft/microsoft-announces-release-of-net-10-lts/)), C# 14, SDK pinned in `global.json` | .NET 11 (STS) is due this month **[unverified date]**. Stay on the LTS and move up deliberately. |
| Runtime | CoreCLR JIT for dev and tests; **self-contained** publish for players (pins the exact runtime, so every peer runs the same JIT); NativeAOT as a later option for shipping | See §4 on the JIT-vs-AOT determinism trap |
| Sim state store | Own Quantum-shaped store: one `NativeMemory.AllocZeroed` block, component tables of `where T : unmanaged` structs, generational handles, `[InlineArray]` fixed-capacity collections, a source generator for the type registry | ~2–4k lines, as estimated in doc 02 |
| Math | Own `float`-based `Vec3`/`Quat`/`Mat` types (scalar, no `Vector<T>`), trig from **CoreMathSharp** (managed CORE-MATH port, correctly rounded, [NuGet](https://www.nuget.org/packages/AndanteSoft.CoreMathSharp)) or our own polynomials | `System.Numerics` and `Math.Sin` banned in the sim |
| Physics | **Jolt** through **JoltPhysicsSharp** (2.22, Jul 2026, net9/net10, [nubrowse](https://nubrowse.com/packages/JoltPhysicsSharp)), with our own native build of `joltc` using `CROSS_PLATFORM_DETERMINISTIC`. Race **Box3D** through the [Box3D](https://www.nuget.org/packages/Box3D) NuGet (tracks upstream, dated builds to 2026-07-30) | BepuPhysics2 is pure C# but only same-machine deterministic (§6) |
| Host / renderer | **Godot 4.7 .NET** (official GodotSharp). Godot owns the process; sim and net are plain .NET class libraries that never reference GodotSharp. N clients = N sims + N `SubViewport`s | Fallbacks: **Stride 4.4** (all-C#), or Godot hosted from C# through LibGodot (the `2dog` project), if that matures |
| Game UI | Godot `Control` nodes built from C# code; **PanGui** (C#-first) if it goes public; NoesisGUI as the paid fallback | |
| Dev UI | **Dear ImGui** through [imgui-godot](https://github.com/pkdawson/imgui-godot) (C# + ImGui.NET), or **Hexa.NET.ImGui** (Dear ImGui 1.92.9b, docking, Jul 2026, [NuGet](https://www.nuget.org/profiles/HexaEngine)) on a custom backend | Inspector built on our type registry (doc 08) |
| Audio | Godot's audio server; rollback-aware sound events from the sim; FMOD's official C# wrapper only if clearly worth it | |
| Networking | Own relay/predict/rollback (doc 05). Transports: loopback + netsim, `System.Net.Sockets` UDP, Steam SDR through **Steamworks.NET** (`Steamworks.NET.AnyCPU` 2026.165.3, SDK 1.65, Oct 2026, [NuGet](https://www.nuget.org/packages/Steamworks.NET.AnyCPU/)), later **EOS** through Epic's official C# SDK | |
| glTF | **SharpGLTF** (pure C#) for headless loading and custom-property extras in the sim and tests; Godot's `GLTFDocument` for runtime loading in the view (no import step, [Godot docs](https://docs.godotengine.org/en/stable/tutorials/io/runtime_file_loading_and_saving.html)) | |
| Agent API | Control server on a Unix domain socket (supported on all three OSes) + the official MCP C# SDK (`ModelContextProtocol` NuGet) **[unverified version]** | |
| Build | `dotnet` SDK / MSBuild, `.slnx`, `Directory.Build.props`, Central Package Management, Roslyn analyzers (`BannedApiAnalyzers`) as errors in the sim project; native libs built once by a CMake script and packaged as a local NuGet feed | |

Projects: `Unified.Sim` (store, math, physics seam), `Unified.Net`, `Unified.Session` (agent API), `Octo.Sim`
(gameplay), `Octo.View.Godot`, `Tests.*`. Only the last two view projects reference Godot. Headless tests run with
`dotnet test` on Sim + Net + Octo.Sim, which is how OctoEscape's `Tools/test-sim.sh` already works.

## 2. Build speed

I found no published Apple Silicon numbers for warm `dotnet build` on a game-sized solution, so the numbers below are
**[estimate]**s with their reasoning. OctoEscape's `Tests/Simulation` is a ready-made benchmark: timing
`Tools/test-sim.sh` on the M4 Pro would replace these estimates in five minutes.

- **What gets compiled.** Only our C#. Godot ships as a prebuilt .NET editor and export templates, so no C++ engine
  build. Native libraries (`joltc`, Box3D, Tracy) are built once per version by a CMake script and published to a local
  NuGet feed or a `~/.cache` folder keyed by version and flags. After that, every worktree uses them as prebuilt
  binaries. This is where C# avoids most of the C/C++ build pain that the Rust, Zig and Odin stacks pay per worktree.
- **Clean build of a fresh worktree** [estimate]: `dotnet restore` against a warm global package cache
  (`~/.nuget/packages`, shared by all worktrees, extract-once) takes a few seconds. Roslyn compiles roughly 100k lines
  (engine + sim + view + tests) in about 15–30 s on a fast laptop. If Godot hosts, add a first `godot --headless
  --import` for the worktree's `.godot/` cache. With code-first assets and runtime glTF loading that cache stays small,
  but each worktree still pays it (doc 03). Estimated total: **20–45 s**.
- **Incremental, one-line sim change** [estimate]: Roslyn recompiles only `Octo.Sim` (about 25k lines) in ~1–2 s
  through the warm compiler server (VBCSCompiler, shared across worktrees). Because reference assemblies are on by
  default since .NET 5, downstream projects skip `CoreCompile` when the public API didn't change
  ([dotnet/msbuild #6560](https://github.com/dotnet/msbuild/pull/6560)). MSBuild's fixed per-project cost (evaluation,
  ResolveAssemblyReferences, reported at 100–500 ms per project, [secondary](https://dev.to/florinvica/9-things-that-silently-kill-your-net-build-time-and-how-to-fix-each-one-3kb4))
  adds about 1 s. Estimate: **2–4 s** to a runnable build, plus 1–2 s of test-host startup for `dotnet test`. No link
  step exists: the JIT "links" at load time.
- **Hot reload** (.NET Hot Reload / `dotnet watch`, Rider): method-body edits apply in under a second into the
  running process. Rude edits (signature or layout changes) restart the app
  ([dotnet watch docs](https://learn.microsoft.com/en-ca/dotnet/core/tools/dotnet-watch)). Sim state lives in the
  unmanaged block, not in managed objects, so a sim-system hot reload keeps state for free (dev only; peers diverge).
  Whether Hot Reload works inside a Godot-hosted runtime is **[unverified]**. Godot's editor reloads C# assemblies on
  rebuild instead.
- **NativeAOT** is release-only. Uno Platform measured a desktop publish going from 19 s to 234 s with AOT
  ([Uno](https://platform.uno/blog/native-aot-in-uno-platform-faster-startup-five-platforms/)). Microsoft's GDK
  guidance is explicit: develop on CoreCLR, ship NativeAOT, run AOT in CI
  ([GDK docs, Sep 2026](https://learn.microsoft.com/en-us/gaming/gdk/docs/gdk-dev/pc-dev/tutorials/get-started-with-custom-engine/native-aot-for-gaming)).
- **Worktrees.** `obj/` and `bin/` are per worktree and small (MBs, not GBs). The NuGet cache, the compiler server and
  MSBuild worker nodes are per user and shared. Nothing like a 10 GB `target/` gets duplicated, and nothing needs
  sccache. Contention risks are minor: NuGet's extract lock on first use, and MSBuild node reuse. Set
  `MSBUILDDISABLENODEREUSE=1` if agents ever see "file in use".
- **Caveat:** Debug builds run unoptimized JIT code, and rollback re-simulation in Debug may be several times slower.
  Run sim tests in `Release` with full PDBs, and keep `Debug` for stepping.

## 3. C/C++ interop and bindings

Mechanics: `[LibraryImport]` (a source-generated P/Invoke, AOT-safe), blittable structs, function pointers and
`[UnmanagedCallersOnly]` for callbacks. ClangSharp generates bindings from headers. The cost is never the call (a
blittable P/Invoke is a few ns). The cost is **shipping a native binary per RID** (win-x64, osx-arm64, linux-x64) and
keeping it in sync with the binding. C++-only libraries need a C shim, as in every non-C++ stack.

| Library | How from C# | Effort / state |
|---|---|---|
| **Box3D** (C) | [Happypig375/Box3D](https://github.com/Happypig375/Box3D) NuGet (raw, tracks the C API, dated builds) or [Box3D.NET](https://www.nuget.org/packages/Box3D.NET/) (idiomatic, alloc-free) | Low. Alpha upstream, community bindings. Its snapshot API isn't public (doc 01) |
| **Jolt** (C++) | JoltPhysicsSharp over `joltc`, same author (Amer Koleci), active | Low to use. **Must rebuild natives** with `CROSS_PLATFORM_DETERMINISTIC` and `-ffp-contract=off` **[unverified whether the NuGet natives set it]** |
| **Rapier** (Rust) | Official C API in `bindings/c` ([rapier.rs](https://rapier.rs/docs/user_guides/c/getting_started_c)) + ClangSharp | Medium: no C# binding exists, and Cargo joins our native build |
| libgodot / GDExtension | **GodotSharp is official** (Godot hosts .NET). LibGodot from C#: `2dog` ([NuGet](https://www.nuget.org/packages/2dog.gdextension/), Jul 2026, MIT, ~300 downloads) | Official route: none. LibGodot route: experimental |
| Bevy | Unreachable (Rust only) | — |
| sokol | [sokol-cs](https://www.Github.com/bottlenoselabs/sokol-cs) (C2CS-generated), Sokol.NET | Low, but it's an abstraction layer, not a renderer |
| SDL3 (GPU) | flibitijibibo/SDL3-CS (FNA's), ppy.SDL3-CS (osu!), [edwardgushchin/SDL3-CS](https://github.com/edwardgushchin/SDL3-CS) | Low, well maintained |
| wgpu-native | Silk.NET.WebGPU (2.x), Evergine bindings **[unverified state]** | Medium |
| raylib | Raylib-cs (AOT-clean per Microsoft's GDK page) | Low |
| bgfx | Official C# bindings generated in bgfx's repo **[unverified freshness]** | Low |
| Filament / The Forge | No maintained C# bindings **[unverified]**; would need a C shim | High |
| Dear ImGui | Hexa.NET.ImGui (generated, docking), ImGui.NET (slower updates) | Low |
| Clay | [Clay.Csharp](https://www.nuget.org/packages/Clay.Csharp) 0.1.1 | Low, young |
| egui | Unreachable (Rust only) | — |
| RmlUi | RmlUi.Net community binding **[unverified, low activity]** | Medium |
| NoesisGUI | **Native C# SDK** (Noesis.GUI 4.0, net9, [NuGet](https://www.nuget.org/packages/Noesis.GUI/4.0.0)). Indie tier €195/project under €100K revenue ([licensing](https://www.noesisengine.com/licensing.php)) | Low, paid |
| PanGui | C#-first, private alpha (doc 06) | Best fit of any stack, if it ships |
| miniaudio | SoundFlow or small generated bindings **[unverified]** | Low–medium |
| FMOD | **Official C# wrapper** ships with the FMOD Engine API | Low (licence cost) |
| Kira | Unreachable (Rust only) | — |
| SoLoud | Official generated C# glue **[unverified]** | Low |
| Steam Audio | C API + the C# P/Invoke layer from its Unity plugin **[unverified]** | Medium |
| Steamworks | Steamworks.NET.AnyCPU (net8+, SDK 1.65), Facepunch.Steamworks | Low, active |
| EOS | **Epic's official C# SDK** (Developer Portal download, [Epic](https://onlineservices.epicgames.com/news/setting-up-a-c-solution-for-eos-in-visual-studio-2019)) | Low. Natives aren't redistributable through NuGet |
| GameNetworkingSockets | Through Steamworks.NET (`SteamNetworkingSockets`); standalone ValveSockets-CSharp is stale **[unverified]** | Low via Steam |
| ENet | ENet-CSharp (stale **[unverified]**); **LiteNetLib** (pure C#, active) is the better UDP choice | Low |
| QUIC | Built-in `System.Net.Quic` (msquic): bundled on Windows, `libmsquic` package on Linux, **partial on macOS via Homebrew** ([MS docs](https://learn.microsoft.com/en-us/DOTNET/fundamentals/networking/quic/quic-overview)) | Low on Win/Linux, medium on macOS (ship our own libmsquic) |
| cgltf / glTF | SharpGLTF (pure C#), so cgltf isn't needed | Low |
| zstd | ZstdSharp.Port (pure C#) or ZstdNet | Low |
| xxHash | **Official** `System.IO.Hashing` (`XxHash3`, `XxHash128`) | Trivial |
| Tracy | Tracy-CSharp 0.11 / Tracy-NET 0.13 (net10) ([NuGet](https://www.nuget.org/packages/tracy-net)) | Low. Zone overhead higher than native **[unverified magnitude]** |

## 4. Determinism and memory model

**Floats: good in practice, weak on paper.**

- **No implicit FMA contraction.** RyuJIT emits separate `fmul` + `fadd` for `a*b+c`, also on ARM64. A request to
  fuse was closed by Tanner Gooding (.NET team), who called it "not a safe/legal optimization to do by default", and
  there's no `fp:fast` mode ([dotnet/runtime #64591](https://github.com/dotnet/runtime/issues/64591), 2022). The
  runtime's own C++ was then switched to `-ffp-contract=off` ([#64604](https://github.com/dotnet/runtime/issues/64604)).
  An earlier prototype that would have fused was never merged ([coreclr #25856](https://github.com/dotnet/coreclr/pull/25856)).
  To our knowledge RyuJIT doesn't auto-vectorize loops, which removes another source of reordering **[unverified for
  .NET 10]**. NativeAOT uses the same RyuJIT backend.
- **But no spec guarantee.** ECMA-335 still lets floats be held at higher internal precision. x64 (SSE) and ARM64
  don't do this in practice, but no document promises cross-architecture bit equality, and no compiler flag enforces
  it. This is a maintainer stance plus CI, not a contract. Rust has RFC 3514, and C has `-ffp-contract=off`.
- **Traps to ban** (with `Microsoft.CodeAnalysis.BannedApiAnalyzers`, errors in the sim project, the C# equivalent of
  clippy `disallowed_methods`):
  - `Math.Sin` and the other transcendentals call the platform CRT, and the docs say results "may differ between
    different operating systems or architectures" (quoted in [dotnet/runtime #8528](https://github.com/dotnet/runtime/issues/8528)).
    The JIT also constant-folds Math intrinsics with the *host* CRT when not compiling ReadyToRun
    ([PR #47321](https://github.com/dotnet/runtime/pull/47321)).
  - `float.Lerp` and `Matrix4x4` rotation helpers call `MultiplyAddEstimate`, which may or may not fuse depending on
    hardware ([source.dot.net](https://source.dot.net/System.Private.CoreLib/R/e66d114169b96b67.html)).
  - `ReciprocalEstimate` / `ReciprocalSqrtEstimate`, and `Vector<T>`, whose width is decided by the CPU under the JIT
    (8 lanes with AVX2, 4 with NEON) and fixed at compile time under NativeAOT.
  - `string.GetHashCode` / `HashCode` (randomized per process), iteration over `Dictionary`/`HashSet`, `Random`.
- **Float→int casts** are now saturating and deterministic on x86/x64 since .NET 9
  ([breaking change](https://learn.microsoft.com/en-us/dotnet/core/compatibility/jit/9.0/fp-to-integer)). The page
  says ARM64 "already" saturated, so the platforms converge.
- **Transcendentals**: CoreMathSharp is correctly rounded and fully managed, so it's identical everywhere by
  construction (its own claim, unaudited). Or port Box3D/Jolt-style polynomial approximations.
- **JIT vs AOT, and runtime versions.** JIT codegen depends on the CPU and runtime version at run time. Self-contained
  publishing pins the runtime per build, and the version handshake (doc 01) covers the rest. If we ever ship NativeAOT
  while dev builds use the JIT, banning width-dependent APIs keeps both paths equal. CI must compare checksums across
  JIT-mac, JIT-win, and AOT builds.
- **Native libs** follow the C/C++ rules: `-ffp-contract=off` for Box3D (its CMake already does) and Jolt's
  cross-platform-deterministic build. Assert MXCSR/FPCR after foreign calls (doc 01).
- **Known results:** I found **no published cross-architecture float lockstep result for CoreCLR**. Most C# lockstep
  games use fixed point (Quantum's `FP`, FixedMath.Net). That's the biggest open question for this stack, and the
  determinism spike answers it.

**Memory model: the best fit of any managed language, and arguably a natural fit.**

- `NativeMemory.AllocZeroed` / `AlignedAlloc` give one GC-invisible block. `where T : unmanaged` makes it a
  **compile error** to put a `class`, `string`, array or `List<T>` in a component, so no managed references can leak
  into sim state. `[InlineArray(N)]` (C# 12) gives fixed inline buffers. Snapshot = `Buffer.MemoryCopy` / `Span.CopyTo`.
  Checksum = `XxHash3` over the span. Quantum ships exactly this model.
- **Gaps the compiler doesn't cover:** `unmanaged` still allows raw pointers (`T*`) and implicit padding. Add a small
  Roslyn analyzer (cheap, in-repo) that bans pointer fields in components and requires `sizeof(T)` to equal the sum of
  the fields. Padding bytes would otherwise make checksums depend on stack garbage. Locals are zero-initialized by
  default, which helps but isn't a guarantee for padding.
- **Access style:** the store hands out `ref T` (safe syntax, no `unsafe` in gameplay code) instead of Quantum's raw
  `T*` (OctoEscape's sim has ~290 `unsafe` lines). A `ref` into a table that reallocates during a structural change
  dangles silently: no borrow checker. Mitigations: fixed-capacity tables (allocated once in the block, which a
  snapshot design wants anyway), deferred structural changes (command buffers applied between systems), and a debug
  mode that validates generations on every access.
- **Agent bugs.** Managed code is memory-safe, with bounds-checked arrays and spans, null-reference warnings,
  exceptions carrying stack traces, and no UB from data races on managed objects. The unsafe core is small (the store,
  ~1–2k lines) and is where agents should rarely go. The sim is single-threaded, so races don't arise. The GC never
  touches sim state, so it adds no nondeterminism.

## 5. Metaprogramming and reflection

C# has both halves, and both are cheap.

- **Runtime reflection** (JIT builds) gives the inspector, desync diff, and tuning write-back for free:
  walk fields, read values from a `Span<byte>` at an offset, show them. Dev tools can lean on it without writing any
  code generation.
- **Incremental source generators** produce an AOT-safe type registry at compile time: component IDs, field offsets
  and types, serializers, bit-packed input/protocol schemas, inspector metadata. That replaces Quantum's `.qtn` DSL
  with plain `partial struct`s and attributes. The developer keeps C# as the only source of truth, which fixes one of
  CONTEXT.md's Quantum complaints.
- **Roslyn analyzers** enforce sim rules at compile time (banned APIs, no pointer fields, no padding, no allocations in
  systems). This is a real, underrated advantage: agent mistakes become red squiggles in the IDE and errors in CI.
- **Build cost:** a well-written incremental generator adds milliseconds per build. A badly written one (one that
  re-runs on every keystroke) slows the IDE, so follow the incremental pipeline rules. Far cheaper than proc-macro-heavy
  Rust crates **[estimate]**.
- **NativeAOT** forbids `Reflection.Emit` and assembly scanning (GDK page above). The generated registry is the
  shipping path, and reflection stays a dev-only convenience.

## 6. Ecosystem fit per subsystem

- **Physics.** Jolt (mature, cross-platform determinism mode, a C# binding by the joltc author) is the safe choice.
  Box3D (two bindings) is the challenger, as in doc 01. **BepuPhysics2**, the best pure-C# engine, is out for crossplay:
  determinism is single-machine only, and SIMD width follows the CPU
  ([issue #42](https://github.com/bepu/bepuphysics2/issues/42),
  [docs](https://docsearch.algolia.com/mcp/docs/repo/bepu/bepuphysics2)). Rapier needs our own binding. Doc 01's open
  issues (Jolt's restore lifecycle gap, Box3D's private snapshot) are the same in every language.
- **Rendering host.** Godot .NET is official, mature, and proven: *Slay the Spire 2* (Godot + C#, 4-player co-op,
  Windows/macOS/Linux/Deck) became the biggest Godot release ever in March 2026
  ([GamingOnLinux](https://gamingonlinux.com/2026/03/slay-the-spire-2-is-out-now-in-early-access)). Costs: Godot owns
  the process and loop, there's one instance per process (doc 03), GodotSharp interop allocates (StringName/Variant)
  unless you're careful, the official SDK baseline is still .NET 8 (net10 works per users, without an official
  statement, [proposal #13076](https://github.com/godotengine/godot-proposals/discussions/13076)), and LightmapGI
  bakes only in the editor. **Stride 4.4** (9 Oct 2026; Linux/macOS builds "no longer experimental", Vulkan/D3D12
  reworked, NativeAOT-friendly, [releases](https://github.com/stride3d/stride/releases)) is the all-C#, code-first-able
  alternative with a real PBR renderer, but it has a small community and a Windows-only editor. **s&box** (Source 2 +
  .NET 10, MIT-licensed C# layer since Nov 2025, [Wikipedia](https://en.wikipedia.org/wiki/S%26box)) is a precedent
  for its hotload and Razor UI, not a host: Source 2 is proprietary. MonoGame/FNA are references for consoles, not
  renderers we'd want.
- **Game UI.** Godot Controls (themes, focus, MSDF fonts) built from code. PanGui's C#-first design is the closest
  thing to the developer's wish list, and C# is its home language. Noesis is native C#. A Razor-style component layer
  like s&box's doesn't exist off the shelf for Godot.
- **Dev UI.** Dear ImGui (imgui-godot C# package, Hexa.NET.ImGui). Reflection makes a generic inspector quick.
- **Audio.** Godot's audio server, free. FMOD (official C#) if ever needed.
- **Netcode / transports.** Steam (Steamworks.NET, active), EOS (official C# SDK), UDP (`Socket`, LiteNetLib), QUIC
  (built-in, weak on macOS). Our relay/rollback code is ours in any language.
- **Profiling.** Tracy bindings, `dotnet-trace` / `dotnet-counters`, EventPipe, Rider's profilers.
- **Testing.** `dotnet test` (MSTest/xUnit/NUnit) with parallel runs, already used by OctoEscape. Property testing
  with FsCheck/CsCheck.
- **Hot reload.** The richest of the five stacks: .NET Hot Reload for method bodies, Godot's assembly reload in the
  editor, s&box-style assembly swapping (MIT code to study). Configs and shaders through file watching, as elsewhere.

## 7. Language stability, maturity, long-term support

- **Stability:** C# has been 1.0 since 2002, with yearly releases (C# 14 / .NET 10 in Nov 2025) and very strong
  backward compatibility. Breaking changes are rare and documented per release (the .NET 9 float→int change is a
  typical example: small, and good for us). LTS releases get 3 years.
- **Governance and funding:** Microsoft builds and funds .NET under the .NET Foundation, MIT-licensed, developed in
  the open on GitHub. The bus factor for the language and runtime is as low as it gets.
- **Game-library bus factor is the weak spot:** JoltPhysicsSharp, Hexa.NET.ImGui, the Box3D bindings and Tracy-CSharp
  are each one or two people. Godot's C# module is a small team inside Godot. Its long-planned move to GDExtension has
  been "future" since 2023 ([GameFromScratch](https://gamefromscratch.com/the-future-of-c-in-godot/)).
- **Shipped games:** an enormous set through Unity (Mono/IL2CPP), plus *Slay the Spire 2* (Godot C#), s&box,
  FNA/MonoGame titles (*Celeste*, *Stardew Valley* **[unverified which runtime each ships]**), and Quantum titles.
  Unity itself is migrating to CoreCLR (6.x→7.0 timeline in flux,
  [Ocean View Games](https://oceanviewgames.co.uk/blog/posts/unity-path-to-coreclr)), which grows the modern-.NET game
  community.

## 8. Tooling and developer experience

- **IDE / LSP:** Rider (free for non-commercial use **[unverified current terms]**) is excellent on macOS and Windows:
  debugger, profiler, Godot plugin, hot reload. VS Code with C# Dev Kit or the open-source Roslyn LSP works for agents
  and editors. Visual Studio is Windows-only.
- **Debugger:** managed debugging is first-class everywhere. **Mixed managed+native stepping isn't available on
  macOS** **[unverified for 2026 Rider]**, so debugging inside Jolt/Box3D from a C# frame means attaching lldb
  separately. On Windows, Visual Studio has mixed mode.
- **Errors:** Roslyn diagnostics are clear and fast, and analyzers extend them with our own rules.
- **Packages:** NuGet with Central Package Management and lock files. Natives ride in `runtimes/<rid>/native`.
- **Agents:** C# is among the most heavily represented languages in training data, and the BCL is stable, so agents
  rarely write stale APIs. Two caveats. (1) Agents default to idiomatic *enterprise* C# (classes, LINQ, `List<T>`,
  allocations) and to **Unity-isms** (MonoBehaviour habits, `UnityEngine.Mathf`). The analyzers above catch most of it.
  (2) Godot's C# API is less common in training data than GDScript, and Godot 3→4 API drift confuses agents
  **[unverified magnitude]**. The 25k lines of Quantum-style gameplay in OctoEscape serve as an in-repo style guide that
  no other stack has.
- **Small things that help agents:** `dotnet run app.cs` file-based scripts (.NET 10) for tools, one CLI for build,
  test, format and publish, and portable IL builds (build on any OS, run on any OS).

## 9. Platforms

- **macOS ARM64, Windows x64, Linux x64 (Steam Deck):** all first-class for .NET 10 and for Godot .NET exports.
  Framework-dependent or self-contained JIT builds are **cross-OS from any machine** (IL plus a per-RID runtime pack).
  **NativeAOT can't cross-compile across OSes** (build macOS on macOS, Windows on Windows) **[unverified for .NET 10
  nuances]**, so CI needs one runner per OS, which the checksum CI needs anyway.
- **Consoles (low priority, but the strongest path of the five):** NativeAOT ships on Xbox via the GDK, and FNA ships
  on Xbox and "other consoles" under NDA. MonoGame 3.8.5+ supports Xbox. Godot C# reaches consoles through porting
  partners (Microsoft's GDK NativeAOT page, Aug 2026 table). FNA documents Switch support under NDA
  ([FNA docs](https://fna-xna.github.io/docs/appendix/Appendix-B%3A-FNA-on-Consoles/)), and a NativeAOT game
  (*Alchemic Cutie*) reportedly passed Switch certification **[unverified]**.

## 10. Feasibility for unified

**What C# makes easy**
- **The port.** OctoEscape's sim is ~22k lines of hand-written C# (~25k with QuantumUser): ~1,300 lines touch `FP`,
  ~1,100 `FPVector3`, ~730 `EntityRef`, ~120 `GetPointer`, and only ~90 touch Quantum's 3D physics/KCC (grep counts).
  A clean-room **Quantum-shaped facade** (`Frame`, `EntityRef`, filters, signals, events, and an `FP` that wraps
  `float` with the same operators) lets most gameplay move with mechanical edits instead of a rewrite. No other stack
  can reuse that code. The view's ~33k lines mostly need rewriting for Godot regardless (MonoBehaviour→Node), but its
  pure logic (rig math, camera, procedural animation) moves over as C#.
- **The arena design**, enforced by `unmanaged` and analyzers, with a production precedent (Quantum).
- **Dev tools and the agent API**: reflection, source generators, an MCP SDK, Unix sockets, JSON source gen.
- **Fast inner loop with no native builds per worktree**, plus hot reload where it's cheap.
- **Platform SDKs**: official EOS C#, mature Steamworks.NET, official FMOD C#, and the clearest console path.

**What C# makes hard**
- **Float determinism without a contract**: we own the proof (analyzers + cross-arch CI from day one).
- **Two worlds again**: a managed sim and a native C++ renderer that owns the process. That's thinner than Unity +
  Quantum (no bridge codegen, no baking, sim never references Godot), but still a seam with marshaling and GC on the
  view side. The view has to watch allocations to avoid Gen0 hitches. The sim allocates nothing.
- **Native dependency packaging**: every C library = binding + three native binaries + flags we control. NuGet natives
  usually aren't built with determinism flags, so we maintain a small CMake "natives" pipeline.
- **Godot as host is editor-shaped** (import cache per worktree, editor-only lightmap bake, one instance per
  process). This is the same issue as in doc 03.

**Work we own that other stacks get for free:** the native build pipeline for Jolt/Box3D (the Zig and C++ stacks get
it from their build systems), Rapier bindings (Rust gets it natively), our own scalar math types (Rust has glam's
scalar mode), and determinism analyzers.
**Work other stacks own that C# gets free:** the Quantum-shaped gameplay code, the type registry (reflection), Steam
and EOS SDKs, a console path, hot reload, and fast per-worktree builds.

**Biggest risks**
1. CoreCLR float equality across x64/ARM64 is unproven publicly. Spike 1 must run C# sim + Jolt on mac and Windows
   and compare per-tick hashes. If it fails, a fallback exists (a port of Quantum's `FP`), but physics would stay
   float, so the mix gets awkward.
2. Godot host friction (process ownership, `.godot/` cache, GodotSharp allocations, .NET 8 baseline) could eat the
   build-speed advantage. Stride or LibGodot-from-C# (`2dog`) are the outs.
3. Physics snapshot completeness (Jolt's lifecycle gap, Box3D's private snapshot) is language-neutral, but C# adds a
   binding layer we may have to patch.
4. GC hitches in the view under 4 split-screen views **[unverified magnitude]**.

## 11. Scorecard

| Criterion | Score | Justification |
|---|---|---|
| Clean build | 4 | No C++ engine or per-worktree native builds. Roslyn + warm NuGet cache estimated at 20–45 s, plus Godot's per-worktree import |
| Incremental build | 4 | ~2–4 s estimated (Roslyn + reference assemblies, no link). Hot reload is sub-second for method bodies. MSBuild overhead keeps it above 2 s |
| Worktree parallelism | 4 | Shared NuGet cache and compiler server, tiny `obj/`. The Godot `.godot/` import cache per worktree is the main duplicate |
| C/C++ interop | 4 | LibraryImport/ClangSharp are good, many official/active bindings. Per-RID native packaging and our own flagged builds are ongoing chores |
| Determinism control | 3 | RyuJIT doesn't contract (maintainer stance), but there's no spec or flag. JIT codegen is per-CPU, and BCL traps need banning. Unproven cross-arch publicly |
| Arena / snapshot fit | 4 | `unmanaged` constraint + NativeMemory + Quantum precedent. Pointers/padding need an analyzer, and `ref`s can dangle |
| Safety vs agent bugs | 4 | Managed code is memory-safe with good exceptions and analyzers. The small unsafe store core has no borrow checker |
| Reflection / metaprogramming | 5 | Runtime reflection for dev tools plus incremental source generators and analyzers, all cheap |
| Rendering host options | 4 | Official, proven Godot C# and an all-C# Stride. No Bevy/Filament. LibGodot-from-C# is immature |
| Physics options | 4 | Jolt (active binding) and Box3D (two bindings) reachable. Bepu fails crossplay. Rapier needs a hand binding |
| Netcode / transports | 4 | Steam and EOS (official C#) and UDP are trivial. QUIC on macOS needs our own libmsquic packaging |
| UI options | 4 | Dear ImGui, Godot Controls, native Noesis, PanGui's home language. No Razor-like layer for Godot off the shelf |
| Language stability | 5 | Mature (2002), backward compatible, yearly releases with documented minor breaks, 3-year LTS |
| Maturity / long-term support | 5 | Microsoft-funded, huge community, many shipped games. Game libraries themselves have small maintainer counts |
| Tooling / DX | 4 | Rider/VS Code, debugger and tests are excellent on macOS and Windows. No mixed native/managed debugging on macOS |
| AI agent fluency | 5 | Top-tier training volume, stable APIs. Watch for enterprise and Unity-isms (analyzers catch them) |
| Platforms | 5 | All three desktops first-class, portable IL builds, the best console path of the five via NativeAOT |
