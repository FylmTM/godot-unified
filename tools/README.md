# tools

Python 3.9+, stdlib only; the same commands work on macOS, Linux and Windows. `dev.py` is the entry point; the
others are its parts and also run on their own. Every command rejects arguments it doesn't know; `python
tools/dev.py -h` lists every command, and `-h` on any command or script its options.

| Script | What |
|---|---|
| `dev.py` | The entry point for every command. Prints each step's time and keeps the last ones in `out/timings.json`. |
| `game.py` | Godot project checks behind `dev.py game` (`validate` and `walk` also fail on leaks at exit and GDScript warnings; `tour --frames [--cold]` reports frame times and first-use hitches). |
| `board.py` | The work board (GitHub Project 2) behind `dev.py board`; needs the `gh` CLI with the `project` scope. |
| `box3d.py` | Fetches Box3D at the pinned commit, applies `third_party/box3d.patch`, builds the static library (`src/box3d/SPEC.md`). |
| `imgui.py` | Fetches (pinned) and builds Dear ImGui + its C API for `src/imgui` (`src/imgui/SPEC.md`). |
| `eos.py` | Stages the pruned EOS SDK in `third_party/eos/` (local SDK or the draft release, hash-checked); `defines` shows the credential flags, redacted (`docs/EOS.md`). |
| `release.py` | Playable game builds: extension, version stamp, Godot export, codesign, zip, smoke test (`docs/RELEASE.md`). |
| `ci.py` | CI helpers: Odin download, pinned odinfmt build, the Godot editor, ninja, the Box3D compiler id, the job summary; `cloud-setup` provisions a Claude Code cloud session (`docs/CLOUD.md`). |
| `common.py` | Shared helpers: platform tags, Godot lookup/run/import/extension list, hash-checked downloads, MSVC env, clang-cl. |

Every download that ends up in a toolchain or a shipped build is pinned: Odin (`ci.py`), the Godot editor
(`common.py`) and export templates (`release.py`) and the EOS SDK (`eos.py`) by SHA-256; Box3D, OLS and Dear
ImGui by commit, dear_bindings by SHA-256.

## `box3d.py`

```
python tools/box3d.py                 # host platform -> third_party/box3d/build/<platform>/{include,lib}
python tools/box3d.py --clean         # refetch and rebuild (also after a compiler upgrade)
```

- Fetches `erincatto/box3d` at the pinned commit into `third_party/box3d/src` (gitignored) and applies the fork patch,
  which must apply exactly.
- CMake + Ninja, Release `-O2 -DNDEBUG`, static, samples/tests/benchmarks/validation off. It checks
  `compile_commands.json` to confirm every source got `-ffp-contract=off` (clang-cl: `/clang:-ffp-contract=off`),
  and on Windows the static CRT (`/MT`, what Odin links).
- **`BOX3D_DISABLE_AVX2` is defined**, so x64 runs the same 4-wide solver path as ARM64/NEON instead of picking
  8-wide by CPUID at runtime.
- Platforms: `macos-arm64`, `macos-x64`, `linux-x64`, `linux-arm64`, `windows-x64`. When up to date it returns without starting
  a compiler (the stamp covers the commit, the patch and the recipe, not the compiler: run `--clean` after
  a compiler upgrade; CI's cache key adds `ci.py compiler-id`). `dev.py` calls it in-process before every build.
- Compilers: `clang` on macOS and Linux, `clang-cl` on Windows (PATH, `C:\Program Files\LLVM`, then Visual
  Studio's LLVM; the MSVC environment is loaded via vswhere/vcvarsall when the shell isn't a developer prompt).

## `dev.py check` and `dev.py regen`

The end-to-end suites run in `dev.py test` (`src/headless/SPEC.md`, End-to-end suites). `check` keeps what can't
run in-process:

- The real-UDP, real-clock test: the toy's headless binary (`out/release/toy`) as a relay on a free localhost port
  plus 3 client processes (the last with `--profile bad`), 960 ticks (~15 s). Every client must verify every tick,
  their checksums (every 16th tick) must agree, and nobody may report a desync.
- Until the benchmarks take it over (#62): the survivor's `bench --enemies 1000 --window 8 --ticks 600`, reported
  (target: forward step + 8-tick re-sim ≤ 6 ms), not gated.
- One `PASS`/`FAIL` line per test. `out/check.json` is the summary CI's job summary reads; `out/check/` keeps each
  process's command line, stdout and stderr. Every process runs under a timeout, so a hung binary fails its test.

`regen <game>|toy` builds and runs that suite with `-define:UNIFIED_REGEN=true` and the commit (`+dirty` when the tree
has changes) as `-define:UNIFIED_REGEN_COMMIT`, then lists the reference files that changed (`git status`).
