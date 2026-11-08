# Stack evaluation template

Every stack doc (`rust.md`, `odin.md`, `zig.md`, `cpp.md`, `csharp.md`) uses exactly these sections and this rubric,
so the stacks can be compared side by side. Write as an advocate who is also honest: give each stack its *best*
realistic setup, then list its real problems. The developer's lack of experience in a language is **not** a
criterion; they will learn. How fluently AI agents write the language *is* a criterion (agents do most of the work),
but it is one row among many.

Requirements come from `docs/CONTEXT.md`. Earlier research (`docs/research/01–08`) assumed Rust; reuse its facts
where they apply, but don't inherit its conclusions.

## Sections (use these headings verbatim)

1. **Best realistic setup**: language/toolchain version; sim state store; physics; host/renderer; game UI; dev UI;
   audio; networking/transports; glTF loading; build system. Name the concrete libraries and bindings.
2. **Build speed**: clean build, incremental build after a one-line gameplay change, and a fresh git worktree. Give
   numbers with sources (or "estimate" and the reasoning). Cover how C/C++ dependencies are built (the build system
   compiling C libs, caching), linker, and caching across worktrees.
3. **C/C++ interop and bindings**: per library in the list below, how you'd use it from this language (an official
   binding, a community binding with its maintenance state, generated, hand-written), and the effort. Note C++-only
   libraries (Godot, Dear ImGui) and how they're reached (a C wrapper, the GDExtension C API).
4. **Determinism and memory model**: float control (FMA contraction, fast-math, libm), how naturally an arena with
   one pointer-free block and memcpy snapshots fits, allocators, zero-init, preventing pointers/heap data in sim
   state, and how the language's safety (or lack of it) affects agent-written bugs (use-after-free, races, UB).
5. **Metaprogramming and reflection**: what a type registry needs (inspector, desync diff, serialization, protocol
   schemas, tuning write-back): derive macros / comptime / RTTI / codegen, and their cost to build times.
6. **Ecosystem fit per subsystem**: physics, rendering host, game UI, dev UI, audio, netcode/transports (Steam
   SDR, EOS, UDP/QUIC, GameNetworkingSockets), profiling (Tracy), testing, hot reload. What exists, what we'd write.
7. **Language stability, maturity, long-term support**: release/1.0 status, breaking-change history and the rate of
   recent breakage, governance and funding, bus factor, size of the community, shipped commercial games.
8. **Tooling and developer experience**: LSP, debugger on macOS and Windows, test runner, package management,
   error messages, AI agent fluency (training data volume, API churn that confuses agents).
9. **Platforms**: macOS ARM, Windows x64, Linux / Steam Deck; cross-compilation; consoles path (low priority).
10. **Feasibility for unified**: what this stack makes easy, what it makes hard, the work we'd own that other stacks
    get for free (and vice versa), and the biggest risks.
11. **Scorecard**: the table below, with one line of justification per score.

## Libraries to cover in section 3

Physics: Box3D (C). Host/renderer: libgodot / GDExtension C API, Bevy (Rust only), sokol, SDL3 (GPU API), wgpu-native,
raylib, bgfx, Filament, The Forge. UI: Dear ImGui (cimgui), Clay, egui (Rust only), RmlUi, NoesisGUI, PanGui (if any API
is public). Audio: miniaudio, FMOD, Kira (Rust only), SoLoud, Steam Audio. Net: Steamworks (flat C API), EOS C SDK,
GameNetworkingSockets, ENet, a QUIC library (msquic / quiche / quinn). Misc: cgltf / gltf, zstd, xxHash, Tracy.

## Scorecard rubric (1–5; 5 = best for unified)

| Criterion | What 5 means |
|---|---|
| Clean build | A fresh worktree builds the full game in under ~30 s on an M4 Pro |
| Incremental build | A one-line sim change rebuilds and relinks in under ~2 s |
| Worktree parallelism | Many agents in many worktrees without heavy duplicated builds or lock contention |
| C/C++ interop | Using the C libraries listed is trivial and low-maintenance |
| Determinism control | Float and memory behaviour fully controllable, with few traps |
| Arena / snapshot fit | One pointer-free memcpy block is natural, and the language helps enforce it |
| Safety vs agent bugs | The compiler and runtime catch agent mistakes before they cost a debugging session |
| Reflection / metaprogramming | A type registry is easy and cheap to build |
| Rendering host options | Strong renderers are reachable without writing one |
| Physics options | Strong deterministic physics with snapshots is reachable |
| Netcode / transports | Steam, EOS, UDP and QUIC are reachable with low effort |
| UI options | Good dev UI and game UI are reachable |
| Language stability | No breaking changes expected; 1.0 or beyond |
| Maturity / long-term support | Large community, funding, shipped games, low bus factor |
| Tooling / DX | Debugger, LSP, tests and errors are good on macOS and Windows |
| AI agent fluency | Agents write correct idiomatic code with little correction |
| Platforms | macOS ARM, Windows, Linux / Deck are first class; consoles possible |
