# Stack: Odin

Researched 2026-11-07, desk research only: nothing installed, nothing built. **(unverified)** marks claims I couldn't
confirm from a primary source. **(source-read)** marks claims I checked by reading the Odin compiler or library
source on `master` that day, not by running it. The toolchain benchmark should confirm both kinds.

## 1. Best realistic setup

The sim, net, dev tools and agent API are one Odin codebase. Rendering comes from **Godot**, reached through its C
APIs, because Odin has no 3D engine of its own and the project rule is that rendering is never written from scratch.

| Layer | Pick | Notes |
|---|---|---|
| Language | Odin `dev-2026-11a` (3 Nov 2026), pinned per monthly release ([releases](https://github.com/odin-lang/Odin/releases)) | LLVM backend only. Pre-1.0 (§7). |
| Sim state | Our own store: one block of fixed arrays, `#soa` tables, `distinct u32` generational handles, `[dynamic; N]T` inline lists, `bit_set` flags | All built-in language features (§4) |
| Physics | **Box3D via `vendor:box3d`**, rebuilt from source with `-ffp-contract=off` (§4). Jolt via [joltc-odin](https://github.com/jrdurandt/joltc-odin) as the fallback | Box3D ships in Odin's official vendor collection ([newsletter, Aug 2026](https://odin-lang.org/news/newsletter-2026-spring-summer/)) |
| Host / renderer | **Godot 4.7 as the view.** Variant A: Godot owns the process and loads our Odin DLL through GDExtension ([odin-godot](https://github.com/dresswithpockets/odin-godot)). Variant B: Odin owns `main` and embeds Godot through the LibGodot C API (Godot 4.6+), with hand-written bindings | No engine-grade renderer exists in Odin. SDL3 GPU, sokol, wgpu and raylib are all vendored, but they're APIs to *write* a renderer on |
| Game UI | Godot `Control` nodes driven from Odin, or [Clay](https://github.com/nicbarker/clay) (official Odin bindings) laid out in Odin and drawn through Godot's `RenderingServer` canvas | |
| Dev UI | Dear ImGui through [Capati/odin-imgui](https://github.com/Capati/odin-imgui) (1.92.9b docking, generated with dear_bindings, active Sep 2026), plus a small backend that hands ImGui draw lists to Godot's canvas | The backend is ours to write: ~300–500 lines **(estimate)** |
| Audio | Godot's audio when Godot hosts. `vendor:miniaudio` for headless and tools | |
| Net | Our relay and rollback code. Transports: loopback with a net simulator, `core:net` UDP, Steam SDR via [odin-steamworks](https://github.com/jakubtomsu/odin-steamworks), EOS later through generated bindings | |
| glTF | `vendor:cgltf` on the sim side (colliders, custom properties); Godot's runtime `GLTFDocument` for visuals | |
| Hashing / compression | `core:hash/xxhash` (pure Odin); `vendor:compress/lz4`, or zstd through a ~30-line binding | |
| Build | `odin build` driven by a small `build.odin` program. C/C++ deps are built once per platform by a script, with pinned flags, into static libs in a shared cache outside the worktrees | Odin has no C compiler (§2) |

Odin-only fallback host: SDL3 + SDL_GPU + ImGui + miniaudio, all in vendor. It gives one language, one process and
N windows. The catch is that we'd write the renderer (cascaded shadows, SSAO, toon ramp, probes), which breaks the
project rule. It's still useful for debug views and headless screenshot tests.

## 2. Build speed

Odin compiles a whole program at once: every build is a full build, with one LLVM module per package, generated in
parallel. There is no incremental compilation and nothing to cache, so "clean" and "incremental" cost about the same.

| Measurement | Number | Source |
|---|---|---|
| Hello world (`core:fmt`, 80.7k lines pulled in, 26 packages), Windows | 0.27 s total: type check 66 ms, LLVM 83 ms, MSVC link 101 ms | [jakubtomsu, Jan 2026](https://jakubtomsu.github.io/posts/odin_comp_speed) |
| Same with `-linker:radlink` | linker share drops to ~15% | same |
| "Projects of this kind" (small games) | "generally take about a second" | [forum, Feb 2026](https://forum.odin-lang.org/t/odin-compilation-speed-tips/1547) |
| Synthetic 1.01M lines, 100 packages, M4 Pro, `dev-2026-06` | **1.10 s** default (`-o:minimal`), 1.11 s after touching one file, **1.79 s with `-debug`** | [guillemus bench](https://github.com/guillemus/odin-1-million-lines-of-code-bench). One unreviewed repo (0 stars), synthetic code: **treat as unverified** |
| `-debug` overhead | +20–80% | jakubtomsu |
| Large generated constant arrays (sokol shader bytecode) | adds ~3–5 s | jakubtomsu, forum |
| WSL2 thread thrashing | 2.4 s hello world, fixed with `-thread-count` | [forum, Jul 2026](https://forum.odin-lang.org/t/odin-compilation-speed-tips/1547) (cites issue #7128) |

**Estimates for unified** (30–100k lines of Odin, `-debug`, M4 Pro):

- **Full build**: about 1–3 s. That holds for both a one-line gameplay change and a fresh worktree, because nothing
  is cached. Separate modules are the default at `-o:none`/`-o:minimal` (source-read, `build_settings.cpp`).
- **Hot reload** (karl-zylinski's [template](https://github.com/karl-zylinski/odin-raylib-hot-reload-game-template),
  636★): only the game DLL is rebuilt. State lives in host-owned memory, which is our state block.
- **Godot (variant A)**: rebuilding the GDExtension DLL is the same 1–3 s. Godot reloads extensions in the editor;
  in a running game, restarting plus replaying is simpler.
- **Traps**: heavy parametric polymorphism and big `#load`ed or constant tables slow LLVM. Generated registries should
  be data, not code.

**C/C++ dependencies.** The `foreign import` system links prebuilt `.a`/`.lib`/`.dylib` files. `vendor:` ships
prebuilts for some libraries (raylib on all platforms; Box3D for Windows, macOS and linux-amd64; SDL3 for Windows only,
so macOS and Linux need it from brew, the distro or a source build). Other libraries ship `build.sh`/`build.bat`
scripts that call the system `cc`/`cl`. **We'd own a deps script** that builds Box3D (C, ~30 files, seconds), cimgui
(C++, ~10–20 s), Clay (one header) and, if needed, joltc + Jolt (C++/CMake, a minute or two) **(estimates)**, with
pinned flags, keyed by a content hash, into `~/.cache/unified/deps/<hash>/`. Every worktree links from there, so a new
worktree builds no C. Unlike Zig or Rust's `cc` crate, the toolchain can't compile C itself, but that also means no
C-build cache to warm per worktree.

**Linker.** macOS uses the system ld; Windows uses `-linker:radlink` (fast) or lld; Linux uses mold or lld.
`-lto:thin` exists for release builds.

**Fresh worktree.** `git worktree add`, then `odin build`: seconds, with no `target/` directory to clone and no lock
file. With Godot as host, every worktree also needs Godot's import cache (`.godot/`) unless visuals load at runtime
through `GLTFDocument`. That's a cost of Godot, not of Odin.

## 3. C/C++ interop and bindings

Odin's C interop is first-class: `foreign import`, `#c_vararg`, `"c"` calling convention, C-compatible struct layout
by default, `cstring`, `[^]T` multi-pointers, `#by_ptr`, `@(link_prefix)`. Bindings are generated with
[odin-c-bindgen](https://github.com/karl-zylinski/odin-c-bindgen) (426★, libclang-based), or written by hand. C++
libraries need a C wrapper.

| Library | How from Odin | Maintenance | Effort |
|---|---|---|---|
| **Box3D** | `vendor:box3d`, official; last changes 28 Oct 2026 (source-read, GitHub API) | Core team | None (rebuild flags only, §4) |
| **Jolt** (C++) | joltc → [joltc-odin](https://github.com/jrdurandt/joltc-odin) (17★, generated, Jul 2026) | One person, small | Build joltc yourself; regenerate on bumps; low–medium |
| Rapier (Rust) | Its C bindings (see doc 01), then bindgen | Unverified quality | Medium; adds a Rust toolchain to the build |
| **Godot** (C++) | GDExtension C interface: [odin-godot](https://github.com/dresswithpockets/odin-godot) (168★, pushed Sep 2026, "Work In Progress", targets 4.4 and generates class bindings from `extension_api.json`). LibGodot: no Odin binding found | WIP, one maintainer | **Medium–high**: we'd likely fork and maintain the generator for 4.7+ |
| Bevy | Rust only | — | Not reachable |
| sokol | [sokol-odin](https://github.com/floooh/sokol-odin), official from floooh (289★, pushed 6 Nov 2026), generated with sokol-shdc Odin output | Upstream author | None |
| SDL3 (+ GPU) | `vendor:sdl3` (3.4.2 in Mar 2026; `sdl3_gpu.odin`, image, ttf, mixer, net) | Core team | None |
| wgpu-native | `vendor:wgpu` (v29.0.1.1, native + WASM) | Core team | None |
| raylib | `vendor:raylib` (raylib 6) | Core team | None |
| bgfx | C99 API exists; no maintained Odin binding found **(unverified)** | — | Generate; low–medium |
| Filament / The Forge | Filament is C++ (needs a C shim); The Forge is C, unbound | — | High / medium |
| **Dear ImGui** | Capati/odin-imgui (docking, all vendor backends incl. SDL GPU, Metal, wgpu) or [L-4/odin-imgui](https://gitlab.com/L-4/odin-imgui) (dear_bindings) | Community, active | Low; prebuild with premake/python |
| **Clay** | Official bindings in `clay/bindings/odin` | Upstream | None |
| egui | Rust only | — | Not reachable |
| RmlUi / NoesisGUI | C++ only; both need a C shim | — | High |
| PanGui | No public API yet (C#, transpiling to C++) | — | Unknown |
| **miniaudio** | `vendor:miniaudio` (0.11.24) | Core team | None |
| FMOD | [jakubtomsu/odin-fmod](https://github.com/jakubtomsu/odin-fmod) (FMOD 2.02.15, last push Mar 2024) | Stale | Low to refresh |
| Kira | Rust only | — | Not reachable |
| SoLoud / Steam Audio | C APIs (`soloud_c.h`, `phonon.h`); no Odin bindings found | — | Generate; low |
| **Steamworks** | [odin-steamworks](https://github.com/jakubtomsu/odin-steamworks) (152★, pushed Jun 2026, hand-maintained from the SDK changelog, SDK 1.60, includes ISteamNetworkingSockets) | One maintainer | Low; may lag SDKs |
| EOS C SDK | None found | — | Generate with odin-c-bindgen; medium (big API) |
| GameNetworkingSockets | [Smilex/GameNetworkingSockets-Odin](https://github.com/Smilex/GameNetworkingSockets-Odin) (hand-written, "may contain errors") | Small | Low–medium |
| ENet | `vendor:ENet` | Core team | None |
| QUIC | msquic/quiche have C APIs; no Odin bindings. quinn is Rust only | — | Generate; medium |
| cgltf | `vendor:cgltf` | Core team | None |
| zstd | Not vendored (lz4 and zlib are) | — | ~30 lines by hand |
| xxHash | `core:hash/xxhash` (pure Odin) | Core | None |
| Tracy | [odin-tracy](https://github.com/oskarnp/odin-tracy) (161★, Aug 2026). Also built-in `core:prof/spall` | Community | Low |

Also in vendor: `ggpo` (a rollback library, not needed), `lua`, `microui`, `kb_text_shape`, `fontstash`, `nanovg`,
Vulkan, Metal (`vendor:darwin`), DirectX, OpenEXRCore, curl ([vendor tree](https://github.com/odin-lang/Odin/tree/master/vendor)).

## 4. Determinism and memory model

### Floats

What I found by reading the compiler source (source-read; the benchmark should confirm it by disassembly):

- **No implicit FMA contraction.** The backend sets LLVM fast-math flags only on procedures marked
  `@(fast_math={...})` (`llvm_backend_opt.cpp`), and there's no global fast-math switch. The target machine is built
  through `LLVMCreateTargetMachine` with default options, so FP-op fusion is "Standard": LLVM fuses only explicit
  `fmuladd` or `contract`-flagged ops. A plain `a*b + c` stays two roundings on both ARM64 and x64.
- **Trap 1: the built-in `matrix` type.** Scalar-path matrix×matrix and matrix×vector multiplies call
  `lb_emit_mul_add` (`llvm_backend_expr.cpp` ~L1243, 1267, 1347, 1419). That emits `llvm.fma` on arm64 always, but
  on amd64 only when the `fma` target feature is on. The default x86 microarch is **x86-64-v2, which has no FMA**, so
  there it emits a separate mul and add. **The same Odin `matrix` code gives different bits on a Mac than on Windows.**
  Fixes: ban `matrix` ops in sim code and use our own vector math, or build x64 with `-microarch:x86-64-v3` (FMA on
  both sides, so both use correctly rounded `llvm.fma`). The second drops pre-Haswell CPUs.
- **Trap 2: `core:math` is mixed.** `sin`, `cos`, `pow` and `exp` are declared as `llvm.sin.*` and similar intrinsics
  (`math_basic.odin`). They lower to the platform libm and can be constant-folded at compile time with the build
  host's libm, so they aren't deterministic across platforms. `atan2`, `asin`, `acos` and `sincos` are pure-Odin
  Cephes/Go ports, so they are deterministic given no contraction. `math.fmuladd` maps to `llvm.fmuladd`
  (fused-or-not per target, a trap). `intrinsics.fused_mul_add` maps to `llvm.fma` (always correctly rounded: safe,
  but slow on x64 without FMA).
- **Trap 3: float→int casts.** The backend emits plain `fptosi`/`fptoui`, so out-of-range values and NaN give LLVM
  poison: x64 returns `0x80000000`, ARM64 saturates. (Rust saturates by definition.) Clamp in the math module.
- **Trap 4: vendored C prebuilts.** `vendor/box3d/src/build.sh` compiles with `cc -O2 -std=c17` and no
  `-ffp-contract=off`. Box3D's own CMake adds that flag on purpose, because Clang contracts by default. A prebuilt
  macOS arm64 `libbox3d.a` from vendor may therefore contain FMAs that the MSVC Windows build (`/O2`, which doesn't
  contract under `/fp:precise`) doesn't **(inferred from the scripts; the shipped binaries weren't inspected)**. Fix:
  build every C dep ourselves with pinned flags (§2).
- `#simd[N]f32` vectors have explicit lane width, so SSE and NEON can match if reductions are written by hand.
  Approximate reciprocal instructions aren't emitted unless asked for.

Policy (the same as for every stack): one `sim_math` package (plain ops, our own or Box3D-style `sin`/`cos`/`atan2`,
clamped casts), no `matrix` or `core:math` transcendentals in sim packages, and cross-platform checksum CI. Odin has no
clippy, but `core:odin/parser` ships the compiler's parser as a library, so a ~200-line lint that bans imports and
identifiers per package is easy to write **(estimate)**.

### Memory model: the strongest part of Odin for this design

- **Zero-init by default.** Uninitialized memory exists only through explicit `---`, which `-vet-uninitialized`
  checks. A fresh block is all zeros, and so is its padding, which keeps checksums stable.
- **Allocators are explicit.** `context.allocator` and `context.temp_allocator` are part of the language.
  `core:mem` has arenas, and `core:mem/virtual` reserves address space and commits it on demand, so a fixed-size sim
  block is idiomatic.
- **Built-in pointer-free building blocks:** fixed arrays, enumerated arrays `[Enum]T`, `#soa` struct-of-arrays,
  `bit_set`, `distinct` handle types, and, new in 2026, **fixed-capacity dynamic arrays `[dynamic; N]T`** stored
  inline (source-read, `parser.cpp`). A snapshot is `mem.copy`, and a checksum is `xxhash.XXH3_64(block)`.
- **Enforcement isn't a type rule.** Odin's compile-time type intrinsics (`type_is_pointer`, `type_is_slice`, and
  `type_struct_has_implicit_padding`, which matters for hashing) work on one type at a time, with no compile-time loop
  over fields. A ~60-line startup assertion or test that walks `type_info_of(Sim_State)` recursively and rejects
  pointers, slices, strings, maps, `[dynamic]`, `any` and procs closes the gap. It's still weaker than a
  compile-time `Pod` derive.
- **Box3D's allocator hook** (`b3SetAllocator`) points straight at an Odin arena, which suits the "arena + memcpy"
  physics snapshot idea from doc 01 (still unverified there).

### Safety vs agent bugs

Bounds checks are on by default (`#no_bounds_check` opts out locally). Integer overflow wraps, by definition.
Division-by-zero behaviour is selectable. `-vet` and `-strict-style` catch unused, shadowed and `using` misuse, and
the new `-vet-nil-deref` catches nil that is nil on every path (source-read, `main.cpp`). `-sanitize:address` and
`thread` exist (macOS support **unverified**), and `mem.Tracking_Allocator` reports leaks and bad frees, per test in
`odin test`.

The compiler doesn't catch use-after-free, dangling slices into `temp_allocator` memory, data races, or nil that is
only *sometimes* nil. Implicit zero values also hide "forgot to initialise" bugs. The handle-based sim block turns most
use-after-free into stale-handle bugs that generation checks catch, and a single-threaded sim removes races. The
remaining risk sits in the view, net and tools code, where agents write pointer-y code.

## 5. Metaprogramming and reflection

The registry needs field names, types, offsets, ranges and tags for: the inspector, the desync diff (walk two blocks
field by field), serialization, protocol schemas, and tuning write-back.

- **Runtime type info (RTTI) is built in and rich.** `type_info_of(T)` and `core:reflect` give struct field names,
  types, offsets, **struct tags** (`speed: f32 \`tune:"0..20" inspect:"slider"\``), enum names and values, union
  variants, `#soa` and bit_set info. `core:encoding/json` and `cbor` already serialize by reflection. A generic
  inspector, diff and tuning writer over `Type_Info` is a few hundred lines **(estimate)** and needs no codegen.
- **Compile time:** parametric polymorphism (`$T`, `where` clauses), `when`, `#config`, `#load`, `#assert`, and
  the type intrinsics above. There's **no compile-time execution and no macros**, by design (see
  `misc/compile_time_execution_problems.md` in the repo). Anything beyond that means codegen: an Odin program that uses
  `core:odin/parser`, run as a build step.
- **Build cost:** almost none. RTTI is emitted by default (`-disallow-rtti` turns it off), and there are no
  proc-macro or derive expansion costs like Rust's.
- **Weak spots:** RTTI is runtime, so the inspector is data-driven and not type-checked. Network protocol bit-packing
  is either written by hand or generated (reflection-driven packing works but is slower; it's fine for 2–4 players).

## 6. Ecosystem fit per subsystem

- **Physics: good.** Box3D is first-class: officially vendored, plain C, the strongest cross-arch determinism CI
  (doc 01). Its missing rollback API (needs a fork patch) is the same for every language. Jolt is reachable through
  joltc. Nothing native to Odin.
- **Rendering host: the weak point.** Odin has excellent low-level graphics bindings (SDL3 GPU, sokol, wgpu, Vulkan,
  Metal, D3D) and raylib, and no engine. The realistic host is Godot through GDExtension or LibGodot, using
  work-in-progress community bindings that we'd likely take over. That brings back a two-object-model bridge
  (sim handles → Godot RIDs/nodes), thinner than Unity↔Quantum but real. Using `RenderingServer` directly from Odin
  avoids nodes. Godot also limits us to one instance per process (doc 03), so N client views become N viewports.
- **Game UI:** Godot Controls, or Clay plus our own draw path. No egui, Noesis or RmlUi without shims.
- **Dev UI:** Dear ImGui (docking) bindings are current, but the Godot backend is ours. In the Odin-only fallback
  host, ImGui + SDL GPU works out of the box.
- **Audio:** miniaudio and SDL3_mixer are vendored. Godot audio is available in the Godot host. Rollback-aware sound
  logic is ours in every stack.
- **Netcode/transports:** `core:net` (UDP/TCP sockets, cross-platform), ENet in vendor, Steam SDR through
  odin-steamworks (one maintainer, may lag the SDK), GNS community bindings. EOS and QUIC are generated bindings we'd
  own. The relay, rollback and net simulator are ours in every stack.
- **Profiling:** Tracy (odin-tracy) plus built-in Spall support (`core:prof/spall`, `-instrumentation` hooks).
- **Testing:** `odin test` is built in: tests run in parallel threads, with a per-test tracking allocator that reports
  leaks. Headless sim+net tests need no GPU and no Godot.
- **Hot reload:** the DLL pattern is proven in shipped games (CAT & ONION). It's the same shape as our state block.
  With Godot as host, the Odin DLL reloads as a GDExtension (editor) or through our own loader (variant B).

## 7. Language stability, maturity, long-term support

- **Status:** no 1.0 and "no official roadmap". The FAQ says "Odin as a language is pretty much done" while the
  compiler and core library keep evolving ([FAQ](https://odin-lang.org/docs/faq/)). Releases are monthly (`dev-YYYY-MM`).
- **Recent breakage:** about every 1–3 months, mostly in the core library, sometimes in syntax. dev-2026-03 replaced
  `core:os` with a rewritten v2 (the old one stays until about Q3 2026) and changed `core:sys/info`
  ([notes](https://newreleases.io/project/github/odin-lang/Odin/release/dev-2026-03)). dev-2026-11 changed `fmt` width
  padding and overhauled `core:compress` ([releases](https://github.com/odin-lang/Odin/releases)). 2026 also added
  syntax: `[dynamic; N]T`, `for init; x in y`, `#+feature using-stmt`. Churn is moderate and mostly mechanical, much
  lower than Zig's pre-1.0 language and build-system churn, and higher than Rust, C++ or C#.
- **Governance and funding:** a BDFL, Bill Hall ("gingerBill"). He is employed by JangaFX, listed as "Senior
  Programmer & Resident Physicist" ([team page](https://www.jangafx.com/about-us)). JangaFX builds EmberGen,
  LiquiGen, IlluGen and GeoGen in Odin ([odin-lang.org](https://odin-lang.org/)), so the language has one commercial
  sponsor whose products depend on it, plus GitHub Sponsors and Patreon. zlib licence.
- **Bus factor:** low to medium. One designer and a handful of regular core contributors. 12.3k★ on GitHub.
- **Community size:** about 8.7k GitHub repos tagged Odin, against about 40k Zig and 1.47M Rust (GitHub search API,
  2026-11-07).
- **Shipped games:** the official list has 14 Steam entries, 8 of them released (CAT & ONION 2024, Solar Storm,
  Volt Deck, DUMMS!, Terrafactor, Relative Frame, 2Deez, Fish Lab), mostly on raylib or sokol
  ([games](https://odin-lang.org/games)). All are small indie titles. **None is a 3D networked physics game.**
  JangaFX's tools are the large-scale production proof, and they are real-time GPU apps, not games.

## 8. Tooling and developer experience

- **LSP:** [ols](https://github.com/DanielGavin/ols) (1.2k★, pushed 1 Nov 2026) offers completion, go-to,
  references, rename, hover, inlay hints, diagnostics through `odin check`, and odinfmt. It's good but
  community-maintained and tracks `master`.
- **Debugger:** Windows is good: RAD Debugger has Odin support, plus RemedyBG and Visual Studio over PDBs. macOS is
  the weak spot: lldb or CodeLLDB with no official Odin formatters, so slices, maps and strings show as raw structs
  unless you load a community lldb script ([gist](https://gist.github.com/laytan/a94c323a84cef7bcfbdf6d21987fd5a9)).
  Linux uses gdb or lldb.
- **Tests:** `odin test <pkg>` is built in (parallel, leak reports), with no external harness.
- **Package management:** none, by design. Dependencies are vendored folders or git submodules. That's arguably
  agent-friendly (no resolver, no lock file, no registry), but updates are manual.
- **Errors:** clear, Go-like type-checker errors. Whole-program checking means one error can stop the whole build.
  Compiles are fast enough that agents iterate quickly.
- **AI agent fluency: the biggest DX weakness.** The training corpus is small (about 8.7k repos). Agents mix in Go,
  Jai or older Odin idioms, pre-v2 `core:os` calls, and syntax that's no longer allowed. New features (`[dynamic; N]T`)
  are invisible to them. Mitigations: the language is small and regular; the compiler is fast, so the error loop is
  cheap; and we'd keep an `AGENTS.md` cheat-sheet plus the vendored `core:`/`vendor:` source in the repo for agents to
  read. No measured agent-accuracy data exists **(unverified; the benchmark should test it)**.

## 9. Platforms

- **Windows x64, macOS ARM64, Linux x64 (Steam Deck):** all first-class targets of the compiler and vendor libraries.
  Prebuilt vendor libraries vary per library (SDL3 prebuilt for Windows only, for example).
- **Cross-compilation:** `-target:` emits objects for other OS/arch pairs, but linking needs that platform's linker
  and SDK. In practice CI builds natively on each OS, which we want anyway for checksum CI.
- **Godot as host** covers all three platforms.
- **Consoles:** no official support and no public console ports known. The LLVM backend and the freestanding target
  make a port conceivable **(unverified)**. Godot's console route goes through third-party porters.

## 10. Feasibility for unified

**Easy in Odin:**

- **The core design idea.** The pointer-free block, zero-init, arenas, `#soa`, handles, memcpy snapshots, a hashed
  block, and a DLL hot reload that keeps state all map directly onto idiomatic Odin. It's the most natural fit of any
  stack.
- **Iteration speed.** Full rebuilds in about 1–3 s **(estimate)**, no incremental-cache pathologies, nothing to warm
  per worktree, no lock contention. Many agents in many worktrees is the easy case.
- **C libraries.** Box3D, cgltf, miniaudio, ENet and SDL3 come officially vendored. Other C libraries are an
  afternoon with odin-c-bindgen.
- **Reflection** for the inspector, diff, tuning and serialization comes free from RTTI and struct tags, with no
  build-time cost.

**Hard in Odin:**

- **Rendering.** There's no engine-grade renderer in the ecosystem, so Odin realistically means Odin + Godot through
  community GDExtension bindings that we'd have to own. That partly brings back the bridge unified wants to remove,
  and caps us at one Godot instance per process.
- **Agent correctness.** A thin corpus and no borrow checker mean more compile-fix rounds and more runtime bugs in
  non-sim code. Fast builds soften this.
- **Determinism footguns that Rust doesn't have:** `matrix` FMA divergence, libm-backed `core:math`, poison
  float→int casts, and contraction in vendored C prebuilts. All of them can be fixed with a lint and a math package,
  but they have to be known up front.

**Work we'd own that other stacks get for free:** Godot bindings (or a renderer); an ImGui→Godot backend; the
determinism lint (Rust has clippy `disallowed-methods`); EOS, QUIC and SDK-current Steamworks bindings; a C deps
build script. **Work other stacks own that Odin gets free:** the Box3D binding (vendored), fast builds without
`target/` juggling, cheap reflection without proc macros, and no borrow-checker friction in multi-table systems.

**Biggest risks:**

1. The host path. odin-godot is WIP, targets 4.4 and has one maintainer. Taking it over is real, ongoing work.
2. Bus factor and pre-1.0 churn: monthly releases, occasional core-library rewrites.
3. Agent fluency is unmeasured and likely the lowest of the five stacks, alongside Zig.
4. Box3D's rollback API (shared with every stack, but Box3D is Odin's best physics option).

## 11. Scorecard

| Criterion | Score | Justification |
|---|---|---|
| Clean build | 4 | Odin code builds in seconds with no cache. C/C++ deps are a one-time cached script, and Godot's per-worktree import is extra |
| Incremental build | 5 | Every build is a full build of about 1–3 s for our size (estimate; a synthetic 1M-line benchmark reports 1.1–1.8 s on an M4 Pro) |
| Worktree parallelism | 5 | No per-worktree target directory, no locks, nothing to warm. C libs come from one shared cache |
| C/C++ interop | 4 | C is trivial and much of our list is officially vendored. C++ (Jolt, Godot, ImGui) needs C wrappers, and there's no built-in C compiler |
| Determinism control | 3 | No implicit contraction and full control, but real traps: `matrix` FMA on arm64 only, libm `core:math`, poison casts, vendored prebuilts |
| Arena / snapshot fit | 4 | The most idiomatic fit (zero-init, allocators, `#soa`, `[dynamic; N]T`), but pointer-freedom is enforced by an RTTI test, not the compiler |
| Safety vs agent bugs | 3 | Bounds checks, defined overflow, zero-init, vet and tracking allocator, but no protection from use-after-free, races or nil |
| Reflection / metaprogramming | 4 | Rich RTTI with struct tags covers the registry cheaply. No compile-time execution or macros, so anything more needs codegen |
| Rendering host options | 2 | No engine. Godot only through WIP community GDExtension bindings or a hand-bound LibGodot. The rest are APIs to write a renderer on |
| Physics options | 4 | Box3D officially vendored, Jolt via joltc-odin, Rapier via C. Same snapshot gaps as C |
| Netcode / transports | 3 | UDP in core, ENet vendored, Steam via a hand-maintained one-person binding. EOS and QUIC must be generated |
| UI options | 3 | Current ImGui docking and Clay bindings. Game UI means Godot Controls or Clay plus our own draw path. No egui, Noesis or RmlUi |
| Language stability | 3 | The language is "pretty much done", but there's no 1.0, no roadmap, and core-library breaks every few months |
| Maturity / long-term support | 2 | BDFL and small core team, one commercial sponsor (JangaFX), about 8 small shipped Steam games, none networked 3D |
| Tooling / DX | 3 | Good LSP and built-in tests, fine on Windows (RAD Debugger). macOS debugging lacks formatters. No package manager |
| AI agent fluency | 2 | Small corpus (~8.7k repos), and agents mix in Go, Jai and stale Odin APIs. Mitigated by a small language and fast compile loops |
| Platforms | 4 | Windows, macOS ARM and Linux/Deck all first-class. Cross-compiling is limited. No console path known |
