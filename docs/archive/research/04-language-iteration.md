# 04: Language, build speed, hot reload, scripting

Research date: 2026-11-07. Claims marked **[unverified]** come from memory or one secondary source; **[estimate]** is
my own extrapolation to be confirmed by the spike at the end.

## TL;DR and recommendation

**Use Rust for everything: engine, simulation and gameplay. No scripting language and no WASM layer for now.**
Optimize for *build latency per worktree*, not for in-process hot reload. Get state-preserving iteration from the
determinism we are building anyway.

1. **One language, all Rust.** Rust gives the best mix of determinism control (no implicit FMA contraction or
   fast-math; IEEE basic ops are bit-identical on x86-64, aarch64 and wasm32; transcendentals can be routed through
   the pure-Rust `libm` crate), game ecosystem (wgpu, Bevy, Rapier with `enhanced-determinism`, egui, Steamworks
   bindings), AI fluency, and C interop. The developer already knows it. C# is the only real alternative (see the
   table), and it loses on native rendering and physics integration and on cross-arch float guarantees.
2. **A small `sim` crate with almost no dependencies.** Gameplay is plain functions over typed queries in a crate
   that depends on the ECS/state block, math (`glam` with scalar math, or a fixed type), physics and `libm`. It never
   depends on rendering, windowing, audio or UI. Its tests link fast. Most agent work happens there.
3. **Fast builds per worktree** (the real bottleneck): `dynamic_linking` (or our own equivalent dylib) for the
   heavy client crates in dev, the default fast linkers (ld-prime on macOS, rust-lld on Linux, which has been the
   default since 1.90; rust-lld on Windows), `opt-level=1` for our code and `3` for deps, `cargo nextest`, and
   **seeding each new worktree's `target/` with an APFS copy-on-write clone of a warm one** (to verify). Treat
   Cranelift, the parallel front end and shared build dirs as nightly experiments, not as foundations.
4. **Hot reload, tiered:**
   - Configs: file-watch, then reload. Values that affect the sim go through the input/command stream so all
     peers and replays see them.
   - Shaders: file-watch, then rebuild the pipeline.
   - UI and dev tools (view side, not deterministic): Bevy/Dioxus **subsecond** hot-patching on the client binary,
     or a markup/reactive UI reloaded as data.
   - Sim code: **"rebuild, restart, replay"**. Re-run the input log or the last snapshot to the current tick in a new
     process. Because the sim is deterministic and headless, that is fast and survives any change, including
     component layout changes. An optional `cdylib` reload of the sim works later, since the host owns the
     pointer-free state block.
5. **Keep the WASM door open, but don't walk through it.** Keep the sim's boundary C-like (`tick(&mut State,
   &Inputs)`, stable component IDs rather than `TypeId`) so the same Rust sim crate could later build to `wasm32`
   for modding or sandboxing. Compiling Rust to WASM doesn't make builds faster. It adds a second toolchain, a
   boundary for every query, and a 1.1–3× runtime cost.

Why not "Rust engine + scripting language": every candidate either breaks determinism and snapshots (Lua heaps,
GC'd VMs), is immature (Roc, Mun, jank, Piccolo), or is slow (Rhai). And agents are less fluent in all of them than
in Rust. The scripting layer's usual selling point, iteration without recompiling, matters less here because agents
work in parallel worktrees and gain little from hot reload (CONTEXT.md).

## Language comparison

| | Determinism control | Compile speed (cold / incr.) | AI fluency and churn | Game ecosystem | C interop | Mac ARM / Win / Linux | Consoles | Verdict |
|---|---|---|---|---|---|---|---|---|
| **Rust** | Strong: no implicit FMA or fast-math; must avoid std transcendentals (platform libm) and arch SIMD intrinsics; Rapier has a cross-platform determinism feature | Slow cold (minutes for Bevy-size trees), incremental 1–30 s depending on layout (below) | High; language stable (editions); **Bevy API churns every ~3–4 months**, so agents write stale Bevy code | Best of the "new" languages: wgpu, Bevy, Rapier/Avian, egui, steamworks-rs, GGRS | Good (bindgen, cbindgen, `extern "C"`) | Tier-1 everywhere (x86_64-apple-darwin dropped to Tier 2 in 1.90, which doesn't matter) | Possible but DIY, NDA toolchains [unverified] | **Pick** |
| **C++** | Strong with flags (`-ffp-contract=off`, MSVC `/fp:precise`); UB is easy to hit | Slowest; Live++ helps on Windows only | Very high corpus; build systems (CMake) are agent-hostile | Deepest: Jolt, PhysX, Box2D v3, everything | Native | Yes | Best path | Not worth the build and safety cost for a hobby engine |
| **C#** (.NET 10) | Basic ops OK; no official cross-arch float guarantee [unverified]; commercial C# deterministic engines use fixed-point | Fast incremental; `dotnet watch` hot reload; s&box hotloads in milliseconds | Very high; stable | MonoGame, Stride, Godot C#, Silk.NET, BepuPhysics2; native rendering and physics via P/Invoke | P/Invoke OK | Yes | NativeAOT; Unity/Godot precedent | Credible runner-up. GC, two worlds again (managed sim + native renderer), weaker rendering stack |
| **Odin** | Good (simple, explicit; LLVM) [unverified details] | Fast whole-program, no incremental; seconds for small games [unverified] | Low corpus; modest churn | `vendor:` raylib, SDL, box2d etc.; DLL hot reload template | Excellent | Yes | DIY | Great for solo C-style; weaker for agents and large ecosystems |
| **Zig** | Good (explicit) | Fast; incremental with its own backends, x86-64 first; `--watch -fincremental` bugs ([#25873](https://github.com/ziglang/zig/issues/25873)) | **Poor: breaking changes every release** (0.16, Apr 2026, made all I/O take an `Io` instance and moved `std.fs`, see [writeup](https://www.youngju.dev/transcribe/2026-07-16-zig-016-io-interface.en)) | Small; C libs via `@cImport` | Best-in-class | Yes | DIY | No: agents can't keep up with the churn |
| **Jai** | Good | Very fast | ~0 corpus | — | Good | — | — | Closed beta as of Feb 2026 ([Wikipedia](https://en.wikipedia.org/wiki/Jai_(programming_language))). Not an option |
| **Nim** | Via C backend flags | Fast (C codegen) | Low; Nim 3/"Nimony" rewrite pending [unverified] | Small | Excellent | Yes | Via C | No |
| **Beef** | OK | Fast, built-in hot swap | ~0 | Tiny; IDE is Windows-centric [unverified] | Good | Weak on Mac [unverified] | — | No |
| **Swift** | OK | Slow-ish type checker [unverified] | Medium; Apple-centric | Tiny outside Apple | Good (C, and C++ interop) | Win/Linux work but second-class | — | No |
| **Mojo** | ? | ? | Low; aimed at AI/GPU kernels | None | Python/C | Mac/Linux | — | No |

## Build speed (Rust)

### What the numbers look like

- Real Bevy project on an M1 Pro (Dec 2025): incremental rebuilds of **7–25 s** after two rounds of splitting
  into workspace crates; the split saved about 5 s overall, and clean builds didn't improve
  ([vladbat00](https://vladbat00.github.io/blog/001-organising-bevy-projects)). This is the realistic baseline for
  a "binary depends on everything" layout *without* dynamic linking.
- Dynamic linking anecdotes: 18 s → ~2 s and 14 s → 0.8 s on small projects. No solid benchmarks exist
  ([bevy-website#1085](https://www.github.com/bevyengine/bevy-website/issues/1085)). Bevy calls it "the most
  impactful compile-time decrease" ([Bevy setup](https://bevy.org/learn/quick-start/getting-started/setup/)).
- Rust's 2025 survey: slow incremental rebuilds after small edits are *the* top complaint; 55% wait more than 10 s
  ([blog](https://blog.rust-lang.org/2025/09/10/rust-compiler-performance-survey-2025-results)).
- **[estimate]** On an M3/M4 Pro: cold debug build of a Bevy 0.19 + Rapier + egui tree takes 1.5–4 min. Editing a
  function in a leaf `sim` crate with no render deps and running its tests takes 1–4 s. Relinking the client with
  `dynamic_linking` takes 2–6 s. The spike measures these.

### Levers, by value

| Lever | Status (Nov 2026) | Notes |
|---|---|---|
| Workspace layout: tiny `sim` leaf, heavy crates upstream and stable | Free | The biggest win for agents. Sim tests never link wgpu or Bevy |
| `bevy/dynamic_linking` (or our own `engine_dylib`) | Stable, dev only | Don't ship it |
| Linkers | macOS: **ld-prime** (Xcode default) is already faster than lld, per Bevy docs. Linux: **rust-lld default since 1.90** ([blog](https://blog.rust-lang.org/2025/09/01/rust-lld-on-1.90.0-stable)), mold optional. Windows: rust-lld via config | **wild** 0.11 (Oct 2026) is fast on Linux; its macOS port is "not yet enabled by default" ([Phoronix](https://phoronix.com/news/Wild-0.11-Released)) |
| `opt-level=1` for our code, `3` for deps | Stable | Sim must run fast in debug, because tests replay thousands of ticks |
| Cranelift backend | Nightly `rustc-codegen-cranelift-preview`. Faster codegen, but only **5–12% on Zed incremental**, ~10–15% average on rustc-perf ([2026 goal](https://goals.rust-lang.org/2026/improve-cg_clif-performance.html)). Bevy docs: "macOS builds can crash", unwinding unsupported on macOS ([repo](https://github.com/rust-lang/rustc_codegen_cranelift)) | Optional experiment, not a foundation |
| Parallel front end (`-Zthreads`) | Nightly; stabilization planned in the 2026 goal; claims 20–30% ([goal](https://goals.rust-lang.org/2026/parallel-front-end.html)) | Experiment |
| `-Zshare-generics` | Nightly | Small win |
| `cargo nextest` | Stable | Runs each test in its own process (good isolation for sim tests); keep few integration-test binaries to cut link time |

### Git worktrees: the cold-build problem

Each worktree gets its own `target/`, so every new agent worktree starts with a cold build of all dependencies,
and the disk cost multiplies (Bevy debug `target/` dirs are commonly 5–15 GB **[unverified]**). Options:

1. **APFS clone of a warm `target/`** (`cp -c -R main/target wt/target`): instant and nearly free on disk until
   files diverge. Registry deps have path-stable fingerprints, so they should be reused; workspace crates rebuild
   because their paths differ. **[unverified; top spike item]**. Windows has no equivalent (ReFS block cloning
   exists only on Dev Drive), but agents mostly run on the Mac.
2. **sccache** with `SCCACHE_BASEDIRS`: strips the worktree path from cache keys. Without it, all Rust compiles
   missed across worktrees in NVIDIA's test ([OpenShell PR](https://github.com/NVIDIA/OpenShell/pull/2379),
   [sccache config](https://docs.rs/crate/sccache/0.15.0/source/docs/Configuration.md)). sccache doesn't cache
   incremental crates **[unverified]**, which is fine since only deps need caching. Costs: hashing overhead and
   linking still per worktree.
3. **Shared `CARGO_TARGET_DIR`/`build-dir`**: `build-dir` became stable in 1.91, but the Cargo team doesn't
   endorse sharing one across workspaces; Cargo locks the whole build directory, so parallel agents serialize.
   Per-unit locking exists behind nightly `-Zfine-grain-locking`
   ([cargo#16155](https://github.com/rust-lang/cargo/pull/16155)). A cross-workspace cache is a 2026 goal, nightly
   only, without build scripts or proc macros, and "will likely not" stabilize this year
   ([goal](https://goals.rust-lang.org/2026/cargo-cross-workspace-cache.html)).
4. **Third-party:** a drop-in Cargo fork claims a per-repo shared build dir across worktrees with fine-grained
   locking ([huacnlee/cargo](https://huacnlee.github.io/cargo/)) **[unverified]**. Indexable's **Blaze** claims a
   Bevy single-function rebuild in 352 ms vs 32 s with Cargo on Linux ARM, a vendor claim from Oct 2026
   ([RuntimeWire](https://runtimewire.com/article/indexable-blaze-rust-builds)). Both are worth watching, not
   depending on.

## Hot reload

| Option | Fit for us | Notes |
|---|---|---|
| **Restart + replay** (ours, built on determinism) | **Sim code: primary** | Any code change, layout changes included. Cost is rebuild plus replay time. Snapshots carry a schema hash, so a matching layout reloads the snapshot directly and a changed layout replays the inputs. If the logic changed, the replay diverges, and seeing the new outcome is the point. Agents get it for free via the agent API |
| **Dioxus subsecond / Bevy `hotpatching`** | **UI, tools, view: yes.** Sim: no | Built into Bevy since 0.17 (`dx serve --hot-patch --features bevy/hotpatching`) ([0.17 notes](https://bevy.org/news/bevy-0-17/)); Bevy 0.19 still ships `HotPatchPlugin` ([source](https://docs.rs/crate/bevy_app/0.19.0/source/src/hotpatch.rs)). Limits: **patches only the tip (binary) crate**, so workspace crates are ignored until "full workspace support" lands (planned, [subsecond docs](https://docs.rs/subsecond/)); no struct layout changes; changed system params aren't reloaded (a community crate allows signature changes, [bevy_hotpatching_experiments](https://docs.rs/crate/bevy_hotpatching_experiments/latest)); sensitive to linker setup. Tip-only conflicts with the small-sim-crate layout, so use it for client-side UI code that lives in the binary |
| **cdylib reload** (hot-lib-reloader or hand-rolled) | Sim: optional later | Generics can't be exported; `TypeId` changes across reloads, which breaks TypeId-keyed ECSs; globals need re-init ([docs](https://docs.rs/crate/hot-lib-reloader/latest)). Our design avoids these: the host owns the state block and component IDs are stable and explicit |
| **Odin/C DLL template** ([karl-zylinski](https://github.com/karl-zylinski/odin-raylib-hot-reload-game-template)) | Pattern reference | Host owns game memory and the DLL exports update and a memory pointer. This is the same shape as our state block |
| **DragonRuby** | Pattern reference | `args.state` lives outside the reloaded logic; re-evaluating source files keeps state. Confirms "state in host, logic swappable" |
| **C# hot reload / s&box hotload** | N/A (not C#) | s&box hotloads code in milliseconds, claiming no need for a scripting language [docs not detailed] |
| **Live++ (C++)** | No | Windows + Xbox/PlayStation only; no macOS or Linux ([liveplusplus.tech](https://liveplusplus.tech/)) |

Configs, shaders, UI: watch files, reload. **Sim-affecting config changes must enter the sim as timestamped
commands** (so they replay and stay in sync across peers), and the config set's hash goes into the checksum.

## Scripting and gameplay-layer options

| Option | Deterministic? | Snapshot / rollback | Hot reload | Perf vs native | AI fluency | Maturity |
|---|---|---|---|---|---|---|
| **WASM (wasmtime)** | Yes with config: NaN canonicalization, deterministic relaxed SIMD, pre-sized memories, fuel instead of epochs ([docs](https://docs.wasmtime.dev/examples-deterministic-wasm-execution.html)) | Linear memory is a flat block that can be memcpy'd; or keep the guest stateless over the host state block | Yes: instantiate the new module | ~1.1–3× slower depending on workload ([old bench](https://00f.net/2019/10/22/updated-webassembly-benchmark/), [TPDE](https://arxiv.org/pdf/2505.22610)) plus boundary calls | Rust→wasm: high | Wasmtime mature; game prior art thin |
| wasm3 | Interpreter (deterministic-ish) | Same | Yes | ~10× slower [unverified] | — | Minimal maintenance since Dec 2023 ([repo](https://github.com/wasm3/wasm3)) |
| **Lua 5.4** | No by default: string-hash seed randomized, `pairs` order follows the hash, platform libm [unverified details] | No (pointer-rich GC heap) | Yes | Interpreter ~10–50× [unverified] | High | Mature |
| **LuaJIT** | Fragile: arm64 used FMA in `%` until FMA was made opt-in ([#918](https://github.com/LuaJIT/LuaJIT/issues/918)) | No | Yes | Fast | High | Slow-moving |
| **Luau** | Not a goal: Roblox clients and servers disagree by 1 ulp ([devforum](https://devforum.roblox.com/t/vector2-number-is-sometimes-off-by-1-bit/2869595)); Roblox is server-authoritative, not lockstep | No | Yes | Good, has native codegen | Medium-high | Mature, MIT |
| **Piccolo** (Rust Lua VM) | Pure Rust, could be made so | State in a `gc-arena`; stackless and fuel-driven, so pausing is easy, but **no snapshot/serialization found** ([repo](https://github.com/kyren/piccolo)) | Yes | Slow interpreter | Low | Experimental |
| **Roc** | Pure functions; `Dec` fixed-point type | **Best conceptual fit**: platform/host owns state and effects, the app is pure | Rewrite cites hot code loading | Native (LLVM) | Very low; syntax churned in 2025 | Zig rewrite reached parity Jul 2026; 0.1.0 targeted late 2026; incremental x86-64 only ([Tildes](https://tildes.net/~comp/1v5c/how_our_rust_to_zig_rewrite_is_going), [Ziggit](https://ziggit.dev/t/roc-how-our-rust-to-zig-rewrite-is-going/16743)) |
| **Mun** | Likely | Hot-reloadable structs | Core feature | Native | ~0 | Stalled: Open Collective archived ([releases](https://github.com/mun-lang/mun/releases)) |
| **Rhai** | Yes if the hash seed is fixed (`set_hashing_seed`/`RHAI_HASHING_SEED`, [src](https://docs.rs/crate/rhai/latest/source/src/config/hashing.rs)); can drop floats | Only if scripts are stateless | Yes | Slow (tree-walking) | Low-medium | Mature |
| Koto, Rune | Probably (Rust-embedded) | Stateless only | Yes | Interpreters | Low | Small communities [unverified] |
| Wren | ? | No | Yes | OK | Low | Largely dormant [unverified] |
| Squirrel | libm floats | No (refcount + GC) | Yes | OK | Low | Mature (Valve titles) |
| Janet | libm floats | `marshal` can serialize closures and fibers, so snapshots are possible by serialization, not memcpy [unverified] | Yes | OK | Low | Stable, niche |
| jank | — | No | REPL | LLVM JIT | ~0 | Alpha [unverified] |
| Gleam | — | — | — | — | Low | Targets BEAM/JS only; not embeddable. No |

### WASM in more detail

- **Determinism** is the best-specified of any VM: only NaN bit patterns, relaxed SIMD and resource exhaustion
  vary, and Wasmtime has a switch for each. Wasmtime ≥20 also canonicalizes `f32.demote_f64`
  ([Zulip](https://bytecodealliance.github.io/zulip-archive/stream/206238-general/topic/Determinism.20of.20Wasm.20SIMD.20in.20Wasmtime.html)).
  NaN canonicalization costs float throughput, and physics would run on the host anyway.
- **Snapshotting**: prior art copies the whole linear memory every frame. Emberware snapshots WASM memory under
  GGRS, with GPU resources as handles outside it [docs page now 404; unverified]. In our design the guest wouldn't
  own state: it would read and write the host's state block through imports or shared memory, so snapshots stay host
  memcpys.
- **Calling host physics** means an import per query or raycast. Fine at 1000 entities, but every typed query
  crosses a boundary that needs bindings. That is the "plain functions over typed queries, minimal magic" style
  turned into an ABI design problem.
- **Ambient** (Rust + WASM + WebGPU multiplayer engine) paused "indefinitely" when the team pivoted to AI game
  tooling (Braindump). Guests were Rust-only, and client-side WASM was unfinished for a long time
  ([repo](https://github.com/AmbientRun/Ambient)). The lesson: a WASM gameplay layer is a large platform investment
  that only pays off when *third parties* write code (UGC, mods), which isn't our case.
- **Where it would pay**: sandboxed mods, untrusted UGC, or a "same sim, different host" story. Our C-like sim
  boundary keeps that possible.

### Determinism rules for Rust (whatever the layer)

IEEE `+ - * / sqrt` are bit-identical across our targets; Rust never contracts to FMA or reassociates without
explicit opt-in; `sin/exp/ln/powf` come from the platform libm and differ in the last ulp between macOS, glibc and
MSVC ([phyz-math notes](https://docs.rs/phyz-math/latest/phyz_math/fp/index.html)). So: use the `libm` crate,
ban std transcendentals and `mul_add` in `sim` with clippy `disallowed-methods`, use scalar math in `glam` (no
arch SIMD paths with approximate rsqrt), turn on Rapier's cross-platform determinism, iterate no `HashMap` in the
sim (use ordered or indexed containers), and run the cross-platform checksum CI from day one.

## Risks and unknowns

1. **Per-worktree cold builds** may still be minutes even with a clone or sccache. If the APFS-clone trick fails
   (fingerprints invalidated by mtimes or paths), we fall back to sccache plus nightly fine-grained locking. The
   biggest practical risk to agent throughput.
2. **Bevy API churn vs AI fluency**: agents write code against older Bevy releases. Mitigate by keeping Bevy out
   of `sim` (it may be out of the engine entirely, depending on the engine-choice research), pinning versions,
   and keeping local API notes or skills for agents.
3. **Subsecond maturity**: tip-crate only, macOS/linker sensitivity, experimental flag. Fine for UI; don't
   design around it.
4. **Replay speed** sets the "restart + replay" loop time: with physics at 1000 bodies, headless sim speed might be
   only 20–100× realtime **[estimate]**, so long sessions need periodic snapshots (keyframes) for reload.
5. **Cross-arch float determinism** with Rapier and glam on aarch64 vs x86-64 is claimed but must be proven by CI
   (another research topic, but it constrains the language rules above).
6. **Cranelift and parallel front end** may stabilize in 2027 and change the build-speed picture. Revisit then.
7. Unverified ecosystem details for Odin, Beef, Wren, Koto, jank and C# float semantics. None changes the
   recommendation.

## Spike proposal (2–3 days, on the developer's Mac, M-series)

**Setup:** workspace with `engine` (heavy deps: Bevy 0.19 *or* wgpu + winit + egui, per the engine research, plus
Rapier), `sim` (state block, ECS-lite, Rapier, `libm`; no render deps), `game` (gameplay systems, depends on
`sim`), `client` (bin). About 1000 entities of stand-in gameplay. Stable toolchain first, nightly variants second.

| # | Measurement | Pass | Acceptable | Fail → action |
|---|---|---|---|---|
| S1 | Edit a function body in `game`, then `cargo nextest run -p game` (warm) | < 3 s | < 8 s | Restructure crates or try Cranelift and `-Zthreads` |
| S2 | Same edit, then a relinked runnable `client` with `dynamic_linking` | < 5 s | < 10 s | Try our own engine dylib, or Cranelift for our crates |
| S3 | New worktree → first green `game` test: (a) plain cold, (b) APFS clone of `target/`, (c) sccache + `SCCACHE_BASEDIRS` | (b) or (c) < 60 s | < 120 s | Evaluate nightly `-Zfine-grain-locking` shared build-dir and the Cargo fork |
| S4 | 4 worktrees building or testing at once | No lock waits; < 1.5× the single-build time | < 2× | Per-worktree dirs plus clone |
| S5 | Extra disk per worktree after a day of edits (with clone) | < 2 GB | < 5 GB | Periodic `cargo sweep` |
| S6 | Restart + replay: 10 000 ticks (≈2.8 min of play) of 1000 bodies, headless | < 2 s | < 5 s | Add periodic keyframe snapshots |
| S7 | Subsecond on `client` egui/UI code: 50 consecutive edits | No crash, < 2 s per patch | Occasional restart | Use UI-as-data reload instead |
| S8 (optional) | `sim` built native (Mac ARM, Win x64) and `wasm32` in wasmtime with NaN canonicalization: checksum after 10 000 ticks; wasm slowdown | Identical checksums; wasm < 2× | < 3× | Note the boundary costs; WASM stays off the table for gameplay |

Decision rule: if S1–S4 pass, adopt the recommended layout and toolchain config as the project template. If
S3/S4 fail badly, worktree build infrastructure becomes a first-class engineering task before gameplay work.
