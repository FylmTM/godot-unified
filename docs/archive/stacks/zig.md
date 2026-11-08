# Stack: Zig

Research date: 2026-11-07. Desk research only: nothing was installed or built. Build times are estimates or quoted
from public sources and must be checked in the toolchain benchmark. "[unverified]" marks claims I could not confirm
from a primary source.

**Summary.** Zig's strengths line up unusually well with the core design idea of `unified`. Comptime reflection can
enforce the pointer-free state block inside the compiler. The build system compiles every C dependency from source
and caches it. Float semantics are strict by default, and the same standard library ships on every platform. Its
weaknesses are just as large, and they are not about the language itself. Zig is pre-1.0 and breaks code in every
release. The fast debug backend and incremental linking work on x86_64 Linux only, not on macOS ARM, which is the
main dev machine. No maintained binding to a full renderer exists. The biggest production user (Bun) has left. AI
agents write stale Zig.

## 1. Best realistic setup

| Layer | Pick | Notes |
|---|---|---|
| Toolchain | **Zig 0.17.1** (2026-11-02), pinned per repo with a `.zigversion`/anyzig-style shim; upgrade deliberately once per release | 0.17.0 shipped 2026-10-01, 0.16.0 on 2026-04-13 ([index.json](https://ziglang.org/download/index.json)). No 1.0 date. |
| Sim state store | Custom store: one `[]align(64) u8` block carved into fixed-capacity tables by a comptime-generated layout; generational handles; a `FixedBufferAllocator` over the block for scratch | Comptime walks every component type and rejects pointers, slices and padding at compile time (§4, §5) |
| Physics | **Jolt via `zphysics`** (zig-gamedev, active, has an `enable_cross_platform_determinism` option), racing **Box3D** (plain C, a trivial build) | zphysics needs two fixes before use: `-ffp-contract=off` and a state save/restore API in its C wrapper (§3, §4) |
| Host / renderer | **Godot 4.6+ via the GDExtension C API**, with Zig bindings we generate ourselves from `extension_api.json` + `gdextension_interface.json`. Either Godot hosts a Zig GDExtension, or Zig hosts Godot through LibGodot | `godot-zig` is stale (last push Dec 2024, Zig 0.13, Godot 4.3). There is no Bevy (Rust only) |
| Game UI | Godot Control nodes (when Godot hosts), or **Clay** (C layout library) drawn by the host | |
| Dev UI | **Dear ImGui via `zgui`** (zig-gamedev, includes ImPlot; min Zig 0.16.0), or Godot's own UI | |
| Audio | **miniaudio via `zaudio`** (min Zig 0.17.0), or Godot's audio when Godot hosts | |
| Net / transports | Our own relay over `std.Io` UDP; Steamworks flat API through bindings generated from `steam_api.json`; EOS C SDK through translate-c; optionally GameNetworkingSockets or msquic | No maintained Steam binding (§3) |
| glTF | `zmesh` (bundles cgltf + meshoptimizer), or Godot's importer when Godot hosts | |
| Profiling | Tracy via `ztracy` (min Zig 0.16.0) | |
| Build | `zig build` only: no CMake. C/C++ deps are fetched as packages and compiled by `zig cc`/`zig c++` with our flags | Upstream Box2D already ships a `build.zig` with `-ffp-contract=off` |

The headless test runner links `sim` + `net` + physics only (no Godot), the same rule as the Rust plan.

## 2. Build speed

**Backend reality on our machines (the decisive fact).**
- **x86_64 Linux:** Zig's self-hosted x86_64 backend has been the Debug default since 0.15. The 0.15.1 notes say it
  is about 5× faster than LLVM ([0.15.1 notes](https://ziglang.org/download/0.15.1/release-notes.html)).
  Incremental compilation with the new ELF linker works "for most projects targeting x86_64-linux"
  ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html)). Measured upstream: one-line rebuilds of
  a Tetris clone in about 30 ms, and of the 36-second compiler build in 230–290 ms
  ([devlog, 30 May 2026](https://ziglang.org/devlog/2026/)).
- **macOS ARM (the dev machine) and Windows:** **LLVM backend only.** The aarch64 backend "crashes when running the
  behavior tests" in 0.16 ([0.16.0 notes](https://ziglang.org/download/0.16.0/release-notes.html)). In 0.17 it is
  still "blocked on linker enhancements". The x86_64 backend is not yet the default on Windows, and a new Mach-O
  linker is only "planned for a future release" ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html)).
  Both items are on the 1.0 roadmap. `-fincremental` works with LLVM since 0.16, but Andrew Kelley writes that it
  "can't do anything to speed up the dreaded LLVM Emit Object". Compile errors arrive in milliseconds; a successful
  build still pays the full LLVM emit for the compilation unit ([devlog, 8 Apr 2026](https://ziglang.org/devlog/2026/)).

**Reference numbers.** Ghostty on x86_64 Linux with Zig 0.15 and LLVM: a full uncached build takes 32 s, and an
incremental build after a one-line change takes 16 s. `libghostty-vt` on the self-hosted backend rebuilds in 975 ms
([Hashimoto, Oct 2025](https://mitchellh.com/writing/zig-builds-getting-faster)). Bun kept a Zig fork with parallel
LLVM codegen for "4× faster debug compiles", and upstream declined it
([The Register](https://www.theregister.com/software/2026/05/05/anthrophics-bun-team-trials-port-from-zig-to-rust/5222094)).
Zig emits one LLVM module per artifact, so the LLVM emit runs as one serial job.

**Estimates for unified on an M4 Pro** (about 40k lines of Zig across engine and slice; Godot prebuilt):

| Scenario | Estimate | Reasoning |
|---|---|---|
| Clean build, cold caches | **60–120 s** | Jolt is about 30–60 s of `zig c++` on 12+ cores [estimate]. ImGui, miniaudio, Box3D and Tracy add about 10–20 s. Zig code through LLVM Debug takes about 5–15 s. Godot is a downloaded binary. |
| Fresh worktree, warm global cache | **15–60 s** | Packages come from `~/.cache/zig/p` (no network). C objects are cached in the *local* `.zig-cache`, so they are rebuilt unless the worktrees share a cache dir (below). |
| One-line sim change, macOS ARM | **2–8 s** | Analysis takes milliseconds; LLVM emit of the sim artifact dominates. Splitting `sim` into its own static library or test binary keeps the emit small. |
| Same, type-check only (`-fno-emit-bin -fincremental --watch`) | **< 0.5 s** | Officially supported mode. Agents get errors without codegen. |
| One-line sim change, x86_64 Linux (CI, a Linux box) | **0.1–1 s** | Self-hosted backend plus the incremental ELF linker, per the devlog numbers above. |

**C/C++ dependencies.** `zig build` compiles C and C++ with the bundled Clang, libc++ and libc headers for every
target. Objects are cached by content hash, and no CMake or system compiler is needed. This is Zig's best build
feature: Jolt, ImGui, Box3D, miniaudio and SDL3 all build from source the same way on all three OSes.
- **Linker:** Zig's own linkers, with LLD as the fallback.
- **Caching across worktrees:** The global cache (`~/.cache/zig`) is shared by design and uses file locks, so
  concurrent builds are safe. Since February 2026, fetched packages are unpacked into a per-project `zig-pkg/`, with
  a recompressed copy kept globally ([devlog, 6 Feb 2026](https://ziglang.org/devlog/2026/)).
- **Sharing C objects:** Pointing every worktree's `ZIG_LOCAL_CACHE_DIR` at one shared directory should share the
  compiled C objects. Whether cache keys include the per-worktree `zig-pkg` absolute path is **unverified**. If they
  do, the fallback is to prebuild C deps once per toolchain version into a shared package.

## 3. C/C++ interop and bindings

Zig calls C with no glue: extern functions, `extern struct` with the C layout, and C calling conventions are all
native. One recent change matters. **`@cImport` was removed in 0.17.** Headers are now translated by the official
`translate-c` *package* as a build step: you create a `Translator` from `b.dependency("translate_c")` and import
`translator.mod` ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html)). This works fine, but every
binding written before 0.16 needs migrating. C++-only libraries need a C shim. Translate-c can fail on complex
macros, which then need hand-written declarations.

| Library | Route from Zig | State / effort |
|---|---|---|
| **Box3D** (C) | Compile with `zig build`, translate `box3d.h` | Trivial (hours). Upstream **Box2D already ships a `build.zig`** with translate-c and `-ffp-contract=off`. Box3D does not yet (checked 2026-11-07) |
| **Jolt** (C++) | `zphysics`: Jolt built from source plus its own JoltC wrapper | Maintained (last commit 2026-10-24, min Zig 0.15.1). **Its C flags lack `-ffp-contract=off`**, which Jolt's own CMake adds for cross-platform determinism. **Its C API exposes no `SaveState`/`RestoreState`** (grep of `JoltPhysicsC.h`). We would fork it and add both: days of work |
| **Rapier** | Its C bindings (CI-tested in the Rapier repo, per doc 01), linked as a Rust static lib | Medium; brings a Rust toolchain into the build |
| **libgodot / GDExtension** | The C interface is designed for this: `--dump-gdextension-interface` emits a C header and `gdextension_interface.json` ([docs](https://docs.godotengine.org/en/stable/engine_details/engine_api/gdextension/gdextension_interface_json_file.html)). Generate the class bindings from `extension_api.json` with a Zig build step | `godot-zig` (304★) last pushed 2024-12-29 and targets Zig 0.13 + Godot 4.3. We'd write our own generator: **2–4 weeks of agent work** for a usable subset [estimate]. Zig's lazy analysis means unused generated bindings cost no compile time |
| **Bevy** | Unreachable from Zig. The only route is inverting it: a Rust/Bevy host linking a Zig `sim` static lib over the C ABI | Two toolchains (§10) |
| **sokol** | `sokol-zig` by sokol's author, min Zig 0.16 | Excellent, active (pushed 2026-11-06). But it's a graphics API, so we'd write the renderer |
| **SDL3 (GPU)** | `zsdl` (zig-gamedev, active), or SDL built from source with `zig build` | Good; again a renderer to write |
| **wgpu-native** | C header via translate-c; `zgpu` uses Dawn instead (min Zig 0.17) | Fine; renderer to write |
| **raylib** | C, translates cleanly; `raylib-zig` was archived on GitHub (Aug 2025), apparently moved [unverified where] | Easy, but too simple for our look |
| **bgfx** | C99 API (`bgfx/c99/bgfx.h`) via translate-c; community bindings exist [unverified maintenance] | Medium |
| **Filament / The Forge** | C++ only; would need our own C shim over a large API | High; not worth it |
| **Dear ImGui** | `zgui` (cimgui-style wrapper plus ImPlot, min Zig 0.16) | Low; maintained |
| **Clay** | Single C header; `clay-zig-bindings` (239★, pushed Apr 2026) or raw translate-c | Trivial |
| **egui / Kira** | Rust only | Not available |
| **RmlUi / NoesisGUI** | C++ only: needs a C shim. Noesis ships prebuilt MSVC binaries, which clash with Zig's default `windows-gnu` ABI (needs the `-msvc` target + Windows SDK) | Medium / high |
| **PanGui** | No public API found | n/a |
| **miniaudio** | `zaudio` (min Zig 0.17, pushed 2026-11-03) | Low |
| **FMOD / SoLoud / Steam Audio** | All have C APIs (`fmod.h`, `soloud_c.h`, `phonon.h`), so translate-c works; link prebuilt libs | Low (FMOD licence aside) |
| **Steamworks** | Generate from `steam_api.json` (the flat API) in a build step. `menduz/zig-steamworks` exists but targets SDK 1.57 (2023) | 2–4 days to write and own a generator [estimate] |
| **EOS C SDK** | Pure C, translate-c | Low–medium |
| **GameNetworkingSockets** | Flat C API; build from source (C++, needs protobuf or its own crypto choices) [unverified build effort] | Medium |
| **ENet** | C; trivial | Trivial |
| **QUIC** | msquic or ngtcp2/quiche (C APIs); no native Zig QUIC of note | Medium |
| **cgltf / zstd / xxHash** | C, header-only or small; cgltf comes with `zmesh`; zstd is packaged for `zig build` by the community | Trivial |
| **Tracy** | `ztracy` (min Zig 0.16) | Low |

The zig-gamedev libraries are all active (pushes in Oct–Nov 2026). Their **minimum Zig versions disagree**,
though: zphysics 0.15.1, zgui and ztracy 0.16.0, zaudio and zgpu 0.17.0. Pinning one compiler can mean patching a
dependency. This version skew is the day-to-day cost of the pre-1.0 churn.

## 4. Determinism and memory model

**Floats in Zig code.**
- Float mode is `.strict` by default. `@setFloatMode(.optimized)` turns on fast-math per scope
  ([langref](https://ziglang.org/documentation/0.17.1/)), so it is explicit and easy to forbid.
- Zig does not emit LLVM's `contract` flag or `fmuladd` for `a*b+c` in strict mode, so it doesn't contract to FMA.
  `@mulAdd` is the explicit, correctly rounded fused op. [Inferred from the codegen model; confirm by disassembly in
  the benchmark.]
- A real plus: **the same standard library ships on every target**. `std.sort`, the hash maps (fixed seeds, so
  iteration is deterministic given the same insert sequence [unverified detail]) and formatting are identical
  bit-for-bit on macOS, Windows and Linux. In C++, `std::sort` and `std::hash` differ per STL (doc 01).

**Traps found.**
1. **`zig cc` inherits Clang's `-ffp-contract=on`.** Any C/C++ dependency compiled without
   `-ffp-contract=off` may fuse multiply-adds on ARM64 but not on x86_64. A musl patch thread cites exactly this with
   `zig cc` ([openwall](https://openwall.com/lists/musl/2025/08/19/3)). **zphysics has this bug today** (see §3). Fix:
   one shared `c_flags` constant in our `build.zig` that every C dependency must use, plus a CI check.
2. **Transcendentals.** `@sin`, `@cos`, `@exp` and `@log` lower to LLVM intrinsics, and those become library calls.
   Zig's compiler-rt carries its own implementations (ported from musl). When libc is linked (always libSystem on
   macOS), which symbol wins is **unverified**, and LLVM may constant-fold some calls at compile time. Treat them
   like Rust's `f32::sin`: ban them in sim code, and use one `dmath` module with our own polynomials (port Box2D's
   `b2ComputeCosSin`/`b2Atan2`).
3. **`@reduce(.Add)` on float vectors** and SIMD width: keep `@Vector` math element-wise, or use scalar code in the
   sim. Whether the reduction order is specified is **unverified**.
4. **Padding bytes are undefined.** Hashing a struct with padding gives a nondeterministic checksum. Debug fills
   undefined memory with `0xaa`, but that is "not a language semantic" (langref).
   `std.meta.hasUniqueRepresentation(T)` rejects such types at comptime.

**Arena and snapshot fit: Zig's best area.**
- Allocators are explicit parameters, so "the sim may only touch its block" is visible in every function signature.
- `extern struct` gives a defined layout. Snapshot is `@memcpy`, and checksum is `std.hash.XxHash3` over the block.
- Every variable must be initialized, or explicitly marked `undefined`, which a lint can ban in sim code.
- About 30 lines of comptime code can walk `@typeInfo` over every registered component and `@compileError` on any
  `.pointer` field (slices, many-pointers, `*anyopaque`) or any padding. **The compiler then enforces the
  pointer-free rule.** Rust needs `bytemuck` derives, and C++ has no equivalent.
- Custom lints are cheap. `std.zig.Ast` (Zig's own parser) is in the standard library, so a build step can reject
  `@sin` or `@setFloatMode` in `sim/` (half a day of work). Zig has no clippy, so this is something we'd own.

**Safety against agent bugs.**
- Debug and ReleaseSafe panic on integer overflow, out-of-bounds, null optional unwrap, wrong union field, invalid
  enum or int casts, misalignment and `unreachable`. That covers *spatial* safety. Safety can be set per module or
  per scope, so the sim can ship in ReleaseSafe.
- *Temporal* safety is not checked. Use-after-free, double free and dangling slices into a resized `ArrayList` are
  caught only partly, by the `DebugAllocator`/new `SafeAllocator` and by 0.17's `ArrayList.lockPointers()`. Data
  races need TSan.
- Bun's creator listed "use-after-free, double-free, and forgot-to-free-on-error-path" as the bulk of Bun's bug list
  when moving it to Rust ([The Register](https://www.theregister.com/devops/2026/05/14/anthropics-bun-rust-rewrite-merged-at-speed-of-ai/5240381)).
- Handles in one block remove most of that class from the sim. The view/Godot glue keeps it.
- **Lazy analysis is an agent trap:** a function that is never called is never type-checked. Agent-written code
  can compile "green" with errors in dead or generic paths until something calls it. Tests must exercise every path.

## 5. Metaprogramming and reflection

Comptime is Zig's best fit for `unified`'s type registry. One language and no separate macro system:
`@typeInfo(T)` gives field names, types, offsets and defaults, and `inline for` generates code per field.
- **Inspector and tuning write-back:** a comptime-generated `fieldsOf(T)` table (name, offset, type tag, range
  attributes from a `pub const meta = .{...}` declaration on the struct). The write-back serializes to ZON, which
  `std.zon` parses and which reads like a Zig literal.
- **Desync diff:** a comptime walk of two blocks reports the first differing component field by name.
- **Serialization and protocol schemas:** a bit-packed input encoder generated from the input struct, plus a schema
  hash derived at comptime from the field list, so peers reject a mismatched build.
- **Query iterators:** `query(.{ Position, *Velocity })` generates the join at comptime with no runtime reflection.

Cost: comptime runs in the compiler's interpreter. Heavy use slows *analysis*, though incremental compilation caches
it. It does not touch LLVM emit time. No external codegen step, no proc-macro crates, no build-time dependency
graph. Churn risk: 0.16 replaced `@Type` with `@Struct`, `@Enum` and similar
([0.16.0 notes](https://ziglang.org/download/0.16.0/release-notes.html)), and 0.17 restricted `@hasDecl` to public
declarations. Reflection code is exactly what breaks between releases.

## 6. Ecosystem fit per subsystem

- **Physics:** Jolt (zphysics) and Box3D are both a good fit; Jolt needs a fork for flags and snapshots (§3). The
  Zig community has no physics engine of its own.
- **Rendering host:** Godot through our own bindings is the only full-featured renderer path. sokol-zig, SDL3 GPU,
  zgpu (Dawn) and bgfx are solid foundations, but they mean writing a renderer, which `unified` rules out. **Mach**
  is pre-1.0, its GitHub mirror was last pushed in May 2026, and it is not a 3D engine
  ([machengine.org](https://machengine.org/)). Doc 03 also judged it "quiet".
- **Game UI:** Godot Controls (if Godot hosts), or Clay plus our renderer. Nothing like bevy_ui or Razor exists in
  Zig.
- **Dev UI:** zgui (ImGui + ImPlot) is mature and maintained, a strong fit for an entity inspector, timeline and
  netsim panel.
- **Audio:** zaudio (miniaudio), or Godot audio. Rollback-aware sound logic is ours in any stack.
- **Netcode / transports:** `std.Io` covers UDP sockets (rewritten in 0.16, so older examples don't compile). Steam,
  EOS, GNS, ENet and msquic are all C. We'd write the relay, the netsim and the Steam binding generator. The Rust
  stack gets `steamworks-rs`.
- **Profiling:** Tracy via ztracy, first class.
- **Testing:** `test` blocks, `zig build test`, a leak-checking test allocator and an integrated fuzzer (§8).
- **Hot reload:** The usual Zig pattern is reloading a dylib. With all state in one block it is natural, but on
  macOS each reload pays the 2–8 s LLVM build, so it's little better than "rebuild, restart, replay". Zig's planned
  in-place binary patching applies to the self-hosted ELF path only.

## 7. Language stability, maturity, long-term support

**Breaking changes, last 15 months.**
- **0.15 (Aug 2025):** "Writergate". All `std.io` readers and writers were deprecated, and the release notes call the
  changes "extremely breaking" ([0.15.1](https://ziglang.org/download/0.15.1/release-notes.html)).
- **0.16 (Apr 2026):** All I/O takes an `Io` instance. `std.fs` and `std.net` moved, `@Type` was split, and
  `@cImport` was deprecated.
- **0.17 (Oct 2026):** `@cImport` removed. `@bitCast` was redefined, and some casts "may silently change behavior".
  The build system API was renamed (`b.build_root` became `b.root`, plus many `add*Arg2` functions). `void{}`,
  `errdefer |err|` and `**` were removed. `containsAtLeastScalar` changed argument order, so old calls "may still
  compile but behave incorrectly" ([0.17.0](https://ziglang.org/download/0.17.0/release-notes.html)).
- **Master (0.18-dev):** Ambiguous operator precedence now needs parentheses
  ([devlog, 24 Oct](https://ziglang.org/devlog/2026/)).
- Expect one migration of a few days per release, about twice a year. Some breaks are silent.

**1.0.** No date. Kelley wants "uncompromising perfection" first, and 1.0 brings a compatibility promise
([The Register, May 2026](https://www.theregister.com/software/2026/05/28/zig-creator-seeks-uncompromising-perfection-before-blessing-10/5247916)).
The roadmap still includes completing the aarch64 backend, the linkers and Windows support, and moving LLVM to a
process dependency ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html)). A realistic guess is
2027–2028 [estimate].

**Governance and funding.**
- The Zig Software Foundation (501(c)(3)) had 2024 income of $670k and spending of $521k. The report warned of
  declining recurring donations and lengthening issue-close times (11 months)
  ([2025 report](https://ziglang.org/news/2025-financials/)).
- New pledges: Synadia + TigerBeetle $512k (Oct 2025), and Hashimoto another $400k over two years (Jun 2026)
  ([mitchellh.com](https://mitchellh.com/writing/zig-donation-2026)).
- Zig left GitHub for Codeberg in Nov 2025, giving up GitHub Sponsors, its biggest donation channel
  ([heise](https://www.heise.de/en/news/Zig-turns-its-back-on-GitHub-Frustration-over-Actions-and-Microsoft-s-AI-course-11100039.html)).
- Bus factor: the project is strongly centred on Andrew Kelley plus a small paid core team.

**Production users and maturity signals.**
- TigerBeetle and Ghostty are serious Zig production users.
- **Bun, the largest, moved to Rust** (merged 2026-05-14), citing memory-safety bug classes. Its upstream fork was
  rejected ([The Register](https://www.theregister.com/devops/2026/05/14/anthropics-bun-rust-rewrite-merged-at-speed-of-ai/5240381)).
- **I found no notable commercial game shipped in Zig.** Cubyz and various hobby or jam titles exist. zig-gamedev
  (2.9k★) is the closest thing to a games ecosystem.

**AI policy.** Zig's code of conduct bans LLM-written issues, PRs and comments; Kelley calls AI contributions
"invariably garbage" (The Register, above). Users are free to use agents. But agent-written bug reports upstream are
not allowed, and the ecosystem will not optimize for agents.

## 8. Tooling and developer experience

- **LSP:** ZLS is active (pushed 2026-11-05). It lags each release by weeks, and its comptime understanding is
  partial. 0.17 added a Build Server Protocol; making it meet ZLS's needs is roadmap item 1.
- **Debugger:**
  - **macOS:** LLDB works on LLVM-emitted DWARF. Slices and optionals need the repo's Python pretty-printers or the
    third-party `zdb` plugin ([Ziggit](https://ziggit.dev/t/hacking-lldb-for-a-great-zig-debugging-experience/13562)).
  - **Windows:** PDB via LLVM works with VS, RemedyBG and RAD Debugger [unverified quality]. **The 0.17 support table
    marks x86_64-windows stack traces ❌**, so panic backtraces on Windows are weak.
  - **Linux:** The new incremental ELF linker did not yet emit DWARF for Zig code as of May 2026.
- **Tests:** Built in and excellent: `test` blocks next to the code, `std.testing.allocator` fails a test on leaks,
  and 0.17 integrates a fuzzer. Good for headless sim tests and replays.
- **Packages:** `build.zig.zon` with content hashes; `zig fetch --save`; `--fork` to override a dependency tree-wide.
- **Errors:** Clear compile errors. Unused variables and parameters are hard errors: agents adapt, but it adds
  churn.
- **AI agent fluency: the weakest row.**
  - The corpus is small, and most of it predates 0.15.
  - Community reports say models write 0.11–0.14 code, and one guide says "many LLMs have outdated Zig knowledge
    (0.11–0.14), causing compilation errors" ([example](https://akitaonrails.com/en/2025/05/03/teaching-recent-zig-to-your-llm-training-loras-sort-of/)).
  - Writergate, `Io` and the removal of `@cImport` hit the exact APIs agents reach for first: printing, files,
    sockets and C imports.
  - Mitigations: the toolchain ships `lib/std` source for agents to grep; pin the version; keep a
    `docs/ai/zig-0.17.md` cheat sheet; type-check in milliseconds with `-fno-emit-bin`.
  - The compiler catches most stale-API code immediately, so the cost is iterations, not silent bugs. The exception
    is the silent semantic changes listed in §7.

## 9. Platforms

- **Tiers (0.17):** x86_64-linux is Tier 1. aarch64-macos is Tier 2, with every column ✅ including CI.
  x86_64-windows is Tier 2 with stack traces ❌. x86_64-macos is now "obsolescent"
  ([0.17.0 notes](https://ziglang.org/download/0.17.0/release-notes.html)).
- **Steam Deck:** Target `x86_64-linux-gnu.2.31` (a pinned glibc version) to match the Steam Runtime.
- **Cross-compilation:** Best in class. One Mac builds Windows and Linux binaries of all the Zig and C code, with no
  SDKs for those two. Building *for* macOS from Linux needs Apple framework headers.
- **Windows ABI:** The default is `windows-gnu` (MinGW). C ABI DLLs (Steam, FMOD, Godot) are fine. MSVC C++ binaries
  need the `-msvc` target and an installed Windows SDK.
- **Consoles (low priority):** No official support, and NDA toolchains. A theoretical path is Zig's C backend
  (`-ofmt=c`), whose output a console's C compiler can build [unverified maturity]. Godot's console ports come
  through third parties (W4 Games).

## 10. Feasibility for unified

**What Zig makes easy.**
- The state block, enforced by the compiler.
- A type registry with no codegen.
- One build system that compiles every C/C++ dependency for all three OSes with our float flags and caches it.
- The same std on every platform.
- Cross-compiled Windows/Linux CI artifacts from a Mac.
- Fast x86_64 Linux incremental builds for CI and Linux agents.
- Explicit allocators, which suit agent-reviewable code.

**What it makes hard.**
- Every Zig upgrade is a migration.
- macOS ARM iteration is LLVM-bound at 2–8 s, where the target is under 2 s.
- No full renderer ships ready to use.
- Agents need guard rails for API drift.
- Temporal memory bugs in host and glue code go uncaught.

**Work we'd own that other stacks get for free.**
- Godot bindings: 2–4 weeks [estimate]. Rust has gdext; C++ and C# have official ones.
- A Steamworks binding generator (Rust has `steamworks-rs`).
- A zphysics fork with snapshot support and the right flags.
- Lints (Rust has clippy `disallowed-methods`).
- A `dmath` module (every stack needs one).
- Riding the release train.

**What we'd get that others pay for.** Comptime enforcement of the sim invariants (Rust: derives plus discipline;
C++: nothing). No CMake (C++). Trivial C interop for Box3D, EOS, FMOD and Steam Audio (C#: P/Invoke marshalling).

**A hybrid worth naming.** A Zig `sim` + `net` library with a C ABI, hosted by Bevy (Rust) or Godot. It keeps Zig
where it shines (state block, determinism, C physics) and borrows a mature renderer. The cost is two toolchains, two
build systems and a C ABI seam at the view boundary. The seam is already narrow, because the view only reads frames.

**Biggest risks.**
1. **Churn and drift.** Pre-1.0 breaking releases twice a year, some silently, and agents trained on old Zig. The
   cost compounds with codebase size.
2. **macOS ARM build latency.** It depends on the aarch64 backend and Mach-O linker landing. Both are roadmap items
   with no date; the aarch64 backend was paused in 0.16.
3. **Renderer path.** Godot via our own binding is unproven in Zig today, and the Bevy route needs Rust anyway.
4. **Ecosystem fragility.** A small community, Bun's exit, and dependency packages pinned to different compiler
   versions.

## 11. Scorecard

| Criterion | Score | Justification |
|---|---|---|
| Clean build | 3 | Zig plus C deps from source is simple, but cold Jolt + LLVM Debug is estimated at 60–120 s on M4 Pro; Godot is prebuilt |
| Incremental build | 3 | macOS ARM is LLVM-only, an estimated 2–8 s (type-check < 0.5 s); x86_64 Linux reaches 0.1–1 s, but that's not the dev machine |
| Worktree parallelism | 4 | Content-addressed, lock-safe global cache; per-worktree `.zig-cache`/`zig-pkg` duplicate C objects unless shared (unverified) |
| C/C++ interop | 5 | Best in class for C: the build system compiles C/C++, translate-c makes bindings. C++ needs C shims, as everywhere; `@cImport` removal adds a build step |
| Determinism control | 4 | Strict floats, no implicit contraction, same std everywhere; traps: `zig cc` contracts C by default (zphysics bug), libm symbol resolution, padding |
| Arena / snapshot fit | 5 | Explicit allocators, `extern struct`, and comptime checks that reject pointers and padding in sim types |
| Safety vs agent bugs | 3 | Safe modes catch overflow and out-of-bounds; no temporal safety (Bun's main complaint); lazy analysis hides errors in uncalled code |
| Reflection / metaprogramming | 5 | Comptime `@typeInfo` covers inspector, diff, schema and serialization with no codegen; reflection builtins churn |
| Rendering host options | 3 | Godot reachable through its C API, but we write and own the bindings; the rest (sokol, SDL3, bgfx) means writing a renderer |
| Physics options | 4 | Jolt via maintained zphysics (needs a fork for snapshots and flags), Box3D trivial, Rapier via its C API |
| Netcode / transports | 4 | Steam flat API, EOS, GNS, ENet, msquic all C; no maintained Steam binding, a generator to write |
| UI options | 3 | zgui is a strong dev UI; game UI depends on Godot or Clay plus our renderer; RmlUi/Noesis need shims |
| Language stability | 1 | Pre-1.0 with big breaks in 0.15, 0.16 and 0.17 (some silent), and no 1.0 date |
| Maturity / long-term support | 2 | ZSF funded but donor-concentrated and Kelley-centred; TigerBeetle and Ghostty yes; Bun left; no notable shipped games |
| Tooling / DX | 3 | Good test runner and packages; ZLS lags releases; LLDB needs printers; Windows stack traces ❌ |
| AI agent fluency | 2 | Small corpus, mostly stale; churn hits the APIs agents use first; compiler errors and in-tree std source help |
| Platforms | 4 | All three targets supported, superb cross-compilation; Windows and macOS ARM are Tier 2; consoles only via the C backend (theory) |

**Total: 58 / 85.**
