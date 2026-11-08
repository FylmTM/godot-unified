# Benchmark A on x86-64, by emulation (2026-11-08, Apple M4 Pro, macOS 26.7.1)

The question: do x86-64 builds of the five Benchmark A implementations produce the same 3600-tick trace as ARM64?
No Windows or x86 hardware was used. Everything ran on the M4 Pro under Rosetta 2 (macOS x86_64) or Rosetta for
Linux (an OrbStack amd64 machine). Reproduce with `bench/x86/run.sh` (about 5 minutes with warm caches).

## Result

**Yes, under emulation: all 36 x86-64 traces are byte-identical to the ARM64 reference** (final hash
`d106cbf36b441bbd`, every one of the 3600 per-tick hashes equal). There was no divergence, so there is no first
divergent tick. The reference is `bench/a/cpp/out/release/bench-a --trace`, which matches all 11 bench/a ARM64 builds.

| Language (builds) | macOS ARM64 native | macOS x86_64, Rosetta 2 (SSE4.2) | macOS x86_64, Rosetta 2 + AVX2 | Linux x86_64, OrbStack (SSE4.2) |
|---|---|---|---|---|
| Rust (dev, release) | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes |
| Odin (dev, release) | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes |
| Zig (dev, release) | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes¹ |
| C++ (dev, release) | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes |
| C# JIT (dev, release) | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes² | d106cbf36b441bbd, yes² | d106cbf36b441bbd, yes³ |
| C# NativeAOT | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes | d106cbf36b441bbd, yes |

"yes" means the whole trace file matches the reference, so there is no first divergent tick. Each cell covers
every build listed in its row. The ARM64 column has 11 traces. Each x86-64 column has 12: the 11 builds plus one
extra C# JIT variant (see ² and ³). The per-trace list is in `traces/summary.txt`.

1. Linux Zig binaries were cross-compiled on the macOS host (`-Dtarget=x86_64-linux-gnu`, the same Zig 0.17.1) and
   run in the Linux machine. Inside the machine, `zig build` can't run (see Deviations).
2. JIT builds ran with the developer's x64 .NET runtime 8.0.33 (`~/.dotnet-x64`). Two launch paths were used: the
   osx-x64 apphost with `DOTNET_ROOT`, and `arch -x86_64 ~/.dotnet-x64/dotnet bench-a.dll` (the extra
   `csharp-release-muxer` trace).
3. Linux C# also ran with the JIT forced down to SSE2-only codegen (`DOTNET_EnableSSE3=0 DOTNET_EnableAVX=0`, trace
   `csharp-release-jit-sse2`). It also matches.

The AVX2 column exercises different code. These are checked facts, not assumptions:
- **Box3D's solver width.** Box3D picks its contact-solver width at runtime from CPUID (`b3IsAVX2Available`), and
  `tools/box3d_simd.c` reports which one it picked. With SSE4.2 it runs the 4-wide SSE2 solver (`wide4.c`). With
  AVX2 it runs the 8-wide AVX2 solver (`wide8.c`). So **the 4-wide and 8-wide x86 solver paths, and ARM64's NEON
  path, all give identical physics.**
- **The .NET JIT's encodings.** RyuJIT's listing of `Swarm.Run` (via `DOTNET_JitDisasm`) says `Emitting
  BLENDED_CODE for generic X64` (legacy SSE encodings: `mulss`/`addss`) without AVX. With AVX it says `... for X64
  with AVX`, and the same method is emitted with VEX encodings (`vmulss`/`vaddss`). Neither listing has an FMA
  instruction.
- **No FMA in the native binaries.** No release binary (Box3D included) contains `vfmadd*`.

Under emulation, x86-64 is slower than native ARM64. Release C++ runs at about 380 µs/tick on Rosetta, against
306 µs native. These runs are not benchmarks.

## CPU features exposed under emulation

All three are read from CPUID/XGETBV by `tools/cpuid.c`, which is what Box3D and the .NET JIT see:

| | brand | SSE4.2/POPCNT | AVX | AVX2 | FMA | F16C/BMI1/BMI2 | AVX-512 | Box3D width |
|---|---|---|---|---|---|---|---|---|
| Rosetta 2, macOS (default) | GenuineIntel "VirtualApple @ 2.50GHz" | yes | no | no | no | no | no | 4 |
| Rosetta 2, macOS, `ROSETTA_ADVERTISE_AVX=1` | same | yes | yes | yes | yes | yes | no | 8 |
| Rosetta for Linux (OrbStack) | same | yes | no | no | **yes** (advertised without AVX, so unusable) | yes | no | 4 |

`ROSETTA_ADVERTISE_AVX=1` is an undocumented Rosetta 2 setting (macOS 15+). It only works on macOS: the Linux
Rosetta ignores it. macOS `sysctl machdep.cpu.features` under `arch -x86_64` shows the default set. Linux
`/proc/cpuinfo` flags agree with CPUID (`fma f16c bmi1 bmi2`, no `avx`). Inside the OrbStack machine, `uname -m`
reports `x86_64`, and every Linux binary is an `ELF 64-bit LSB ... x86-64` (`file`). The machine's kernel is
OrbStack's ARM64 kernel, with x86-64 user space translated by Rosetta through binfmt_misc.

## Toolchains

| | macOS host (x86_64 cross builds) | Linux machine (`unified-x64`, Ubuntu 24.04 amd64) |
|---|---|---|
| Rust | 1.98.1, target `x86_64-apple-darwin` (added by the developer) | 1.98.1 (rustup, minimal profile) |
| Odin | dev-2026-11 (Homebrew), `-target:darwin_amd64` | dev-2026-11 linux-amd64 release tarball |
| Zig | 0.17.1, `-Dtarget=x86_64-macos` | the host's 0.17.1, `-Dtarget=x86_64-linux-gnu` (Linux 0.17.1 installed but unusable, see Deviations) |
| C/C++ | Apple clang 21, CMake 4.4.5, Ninja 1.13.2 | Ubuntu clang 18.1.3, CMake 3.28.3, Ninja 1.11.1 |
| .NET | arm64 SDK 8.0.133 builds `-r osx-x64`; runtime: x64 8.0.33 in `~/.dotnet-x64` (developer-installed) | SDK 8.0.133 + runtime 8.0.33 (Ubuntu `dotnet-sdk-8.0`) |
| Box3D | commit 33626332, `deps-macos-x64/box3d` | same commit, `deps-linux-x64/box3d` (clang) |

## How each was built

- **Unmodified sources.** `scripts/mirror.sh` copies `bench/a/{rust,odin,zig,cpp,csharp}` (sources and build
  scripts, no outputs) into `macos-x64/tree/` and `linux-x64/tree/`. It checks every copied file is byte-identical
  to bench/a, then adds two symlinks: `tree/deps` → the target's Box3D and `tree/vendor` → `bench/a/vendor`. Every
  implementation finds Box3D by a path relative to its own directory (`../deps/box3d/...`). So each one links the
  right architecture without editing a source or build file, and all outputs (target/, out/, build/, .zig-cache/,
  obj/) stay in bench/x86. Nothing in bench/a was modified or rebuilt.
- **Box3D.** `scripts/build-box3d.sh` copies the flags from bench/a's build-box3d.sh: Release, `-O2 -DNDEBUG`,
  Box3D's own `-ffp-contract=off`, SIMD on, no validation. It installs into a chosen prefix. macOS adds
  `-DCMAKE_OSX_ARCHITECTURES=x86_64`, and Linux uses `-DCMAKE_C_COMPILER=clang`. Both builds include the
  runtime-dispatched AVX2 file (`wide8.c` via a `target("avx2")` attribute, not `-mavx2`).
- **macOS x86_64** (`scripts/build-macos-x64.sh`):
  - **C++:** the unmodified `build.sh`, with `CMAKE_OSX_ARCHITECTURES=x86_64` set in the environment.
  - **Rust:** `build.sh`'s cargo command plus `--target x86_64-apple-darwin`.
  - **Odin:** `build.sh`'s flags plus `-target:darwin_amd64`.
  - **Zig:** `build.sh`'s `zig build` command plus `-Dtarget=x86_64-macos`.
  - **C#:** `dotnet restore/build/publish -r osx-x64`. The command-line RID overrides the `osx-arm64` that
    `Directory.Build.props` pins. dev/release are framework-dependent JIT builds. aot is NativeAOT, cross-compiled
    by the arm64 SDK (it restored `runtime.osx-x64.Microsoft.DotNet.ILCompiler` 8.0.33).
- **Linux x86_64** (`scripts/provision-linux.sh`, `scripts/build-linux-x64.sh`; run inside the machine):
  - **Rust, Odin, C++:** the unmodified `build.sh` scripts, built natively. Rust ran its `fetch.sh` first. C++ used
    `CC=clang CXX=clang++`.
  - **C#:** `-r linux-x64` for JIT dev/release and NativeAOT.
  - **Zig:** cross-compiled by `scripts/build-zig-linux-x64.sh` on the host.
- **Runs** use `scripts/run-linux-x64.sh` in the machine, and `run.sh` for macOS (`arch -x86_64`, with and
  without `-e ROSETTA_ADVERTISE_AVX=1`). `scripts/compare.sh` compares the traces and reports the first divergent
  line if any.

## Deviations and problems found

- **Zig can't build inside the Linux machine.** `zig build` compiles its build runner ("maker") with Zig's
  self-hosted x86_64 backend and ELF linker. Rosetta for Linux refuses to load that executable: it fails with
  `rosetta error: bss_size overflow` and SIGTRAP. The maker has a RW LOAD segment with FileSiz 0, and `zig build
  -fllvm` doesn't change how the maker is built. The workaround was to cross-compile the Linux Zig binaries on the
  macOS host. The resulting ELF files (dev included) load and run fine under Rosetta for Linux. This affects
  `zig build` under Rosetta only, not the benchmark. It's worth knowing for any x86 Linux CI that runs on Apple
  Silicon via OrbStack or Docker.
- **C# on Linux needed a library rename.** `Box3D.csproj` copies `../../../deps/box3d/lib/libbox3d.0.1.0.dylib`, a
  macOS-only name. In `deps-linux-x64` that name is a symlink to the ELF `libbox3d.so.0.1.0`, so the csproj builds
  unmodified. The build script then copies the library next to each Linux output as `libbox3d.so`, the name .NET
  probes on Linux.
- **Odin, Zig, Rust and C# don't use their bench/a `build.sh` for the macOS cross builds.** Those scripts take no
  target option. Odin, Zig and Rust used the same flags with a target added. C# needs `-r` because the RID is
  pinned in `Directory.Build.props`.
- **The C# osx-x64 ILCompiler restore failed once** ("response ended prematurely"). NuGet retried and succeeded.
- **Each target uses its own codegen setting:**
  - **macOS cross builds** use each toolchain's baseline x86-64 CPU.
  - **Linux Rust and Odin** use the defaults of a native build. Rust's default is x86-64 baseline.
  - **Linux Zig** is cross-compiled, so it uses the baseline too.

  No binary contains FMA instructions. AVX code exists only in Box3D's runtime-dispatched `wide8` path (and
  whatever .NET picks at runtime).

## What emulation does NOT prove

- **Real x86 silicon.** Rosetta translates x86 instructions to ARM64. The match proves the x86 instruction
  streams that these compilers emit compute the same values as ARM64, *as Rosetta executes them*. Rosetta is
  meant to be bit-exact for SSE/AVX arithmetic: IEEE `+ − × ÷ sqrt`, and no approximate `rcpps`/`rsqrtps` in Box3D
  or the sim. But that is still Rosetta's implementation of x86, not Intel's or AMD's hardware.
- **AVX-512.** No emulator here exposes it. On an AVX-512 machine, .NET 8's JIT switches to EVEX encodings and
  512-bit vectors, and NativeAOT/C++ codegen could differ if anyone targeted it. Box3D has no AVX-512 path. The
  scalar f32 maths should stay IEEE-identical, but that is untested.
- **AVX2 is covered only by Rosetta's emulation of it**, not by hardware. AMD and Intel differences, such as
  approximate instructions or denormal handling under non-default MXCSR, aren't covered.
- **Windows.** Untested: MSVC (cl.exe) builds of Box3D and C++ (Box3D builds `wide8.c` with `/arch:AVX2` there,
  and MSVC's `/fp` defaults differ from clang's), the MSVC CRT, the Windows x64 calling convention for by-value
  structs (Box3D's `b3RayResult` and the `b3Vec3` returns in C#/Odin/Zig/Rust bindings), and win-x64 .NET JIT and
  NativeAOT. The macOS x64 and Linux x64 runs use the System V ABI. Windows is still the developer's PC or a
  Windows CI runner.
- **Different compilers on the same platform.** GCC was not tried for Box3D or C++ on Linux. Only clang (Apple 21,
  Ubuntu 18), rustc, Odin's LLVM, Zig's LLVM backend and probably its self-hosted backend (the Debug x86_64
  default; the Linux dev ELF has the self-hosted linker's layout), RyuJIT and NativeAOT were tested.
- **Single-threaded only**, as the spec requires. Multithreaded Box3D determinism isn't covered.

## Files

- `run.sh`: the whole pipeline. It builds macOS x64, then provisions, builds and runs Linux x64, then compares.
  Use `--no-build` to rerun the comparison only.
- `scripts/`:
  - **Builds:** `build-box3d.sh`, `mirror.sh`, `build-macos-x64.sh`, `build-zig-linux-x64.sh`.
  - **Inside the Linux machine:** `provision-linux.sh`, `build-linux-x64.sh`, `run-linux-x64.sh`.
  - **Comparison:** `compare.sh`.
- `tools/cpuid.c` and `tools/box3d_simd.c`: the CPU-feature probe and Box3D's runtime SIMD-width probe.
- `traces/summary.txt`: the per-trace comparison. The full traces are in `traces/<platform>/`, and logs in `logs/`.
  Both are git-ignored, like the build outputs (`macos-x64/`, `linux-x64/`, `deps-*/`).
- The OrbStack machine `unified-x64` (Ubuntu 24.04 amd64) is left running, with its toolchains in `/opt/x86-tools`
  and `~/.cargo`. Delete it with `orb delete unified-x64`.
