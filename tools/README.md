# tools

Python 3.9+ scripts, stdlib only; the same commands work on macOS, Linux and Windows.

## `box3d.py`: Box3D for every language

```
python tools/box3d.py                 # host platform -> third_party/box3d/build/<platform>/{include,lib}
python tools/box3d.py --json          # same, then one JSON line: include_dir, lib, link_libs, ...
python tools/box3d.py --arch x86_64   # macOS only: macos-x64 build, for Rosetta checks
python tools/box3d.py --clean         # refetch and rebuild
```

- Fetches `erincatto/box3d` at the pinned commit `3362633…` into `third_party/box3d/src` (gitignored) and applies
  `third_party/box3d.patch` (the save/restore fork; it must apply exactly).
- Builds a static library with CMake + Ninja: Release, `-O2 -DNDEBUG`, samples/tests/benchmarks off, validation off.
  It then checks `compile_commands.json` to confirm every source got Box3D's own `-ffp-contract=off` (clang-cl:
  `/clang:-ffp-contract=off`).
- **`BOX3D_DISABLE_AVX2` is defined.** Otherwise Box3D picks its 8-wide AVX2 solver path at runtime by CPUID on x64
  CI machines. ARM64 (NEON) and phase 1's Rosetta check use the 4-wide path, and that's the path the committed
  macOS references are built with.
- Platforms are `macos-arm64`, `macos-x64`, `linux-x64` and `windows-x64`. A repeat run is a no-op in about 0.1 s.
  Stamps cover the commit, patch, flags and compiler version.
- Compilers come from one family everywhere: `clang` on macOS and Linux, and `clang-cl` on Windows. On Windows,
  clang-cl is looked up on PATH, then in `C:\Program Files\LLVM`, then in VS's bundled LLVM. If the shell isn't a
  developer prompt, the MSVC environment is loaded via vswhere/vcvarsall. The CRT is `/MD`, which matches Rust and
  Odin. `--cc/--cxx` override the compiler.
- Link line: `lib/libbox3d.a` (or `lib/box3d.lib`), plus `-lm -lpthread` on Linux. `box3d.json` lists these.

## `check.py`: the §4 tests

```
python tools/check.py <lang>                     # build (release) + T1-T9
python tools/check.py rust --only T1,T7          # subset
python tools/check.py odin --build-mode dev      # dev build; timeouts x4
python tools/check.py cpp --no-build             # reuse the existing binary
python tools/check.py cpp --regen                # macOS ARM64 only: rewrite testdata/cpp/, then test
```

- Runs `python impl/<lang>/build.py <mode>` with cwd `impl/<lang>`. On Windows the MSVC environment is loaded, and
  the env has `UNIFIED_REPO` and `UNIFIED_PLATFORM` set. Then it tests `impl/<lang>/out/<mode>/unified[.exe]`.
- Prints one `PASS`/`FAIL` line per test with its time, then a final JSON line. Exits 0 when everything passed, 1 on
  a failure, and 2 when the language has no `build.py`.
- Writes `impl/<lang>/out/check.json` (the summary) and `impl/<lang>/out/check/` (each command's line, stdout/stderr,
  traces, logs, and `T9/bench.json`).
- Every command runs under a timeout, so a hung binary gets killed and fails its test. Sessions get
  `ticks/60·4 + 90` s; the rest get 300–900 s. `--timeout-scale` multiplies all of them.
- T3 runs its six sessions in parallel (`--jobs`, default half the CPUs). T4 reuses T3's 4-client `bad` log. T5 picks
  a free localhost UDP port and starts the relay, waits 0.5 s, then starts the 3 clients; client 2 uses `--profile bad`.
- Fixed seeds: tests use 42 and the references use 7. JSON field names and tick numbering are listed under
  "Conventions" in `spec/CORE.md` §3.

## `ci.py`: GitHub Actions helpers

`detect <lang>` decides whether a matrix job runs: it checks for `impl/<lang>/build.py`. `ensure-ninja` installs ninja
if it's missing. `odin <tag> <dest>` fetches the pinned Odin release. `summary <dir>` prints the markdown table for
the job summary.

## Contract for `impl/<lang>/build.py`

- `python impl/<lang>/build.py dev|release` → `impl/<lang>/out/<mode>/unified[.exe]`, exit 0 on success.
- It must work from any cwd and must not need bash.
- Get Box3D by running `python tools/box3d.py --json` (cheap when already built) and reading `include_dir`, `lib` and
  `link_libs` from the last stdout line.
- Box3D is always the `-O2` build, in both dev and release. Your own code must keep FP contraction off.
- Keep build products under `impl/<lang>/out/` (Rust: the cargo target dir `impl/rust/target` is what CI caches).
