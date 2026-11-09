# tools

Python 3.9+, stdlib only; the same commands work on macOS, Linux and Windows. `dev.py` is the entry point; the
others are its parts and also run on their own. Every command rejects arguments it doesn't know; `python
tools/dev.py -h` lists every command, and `-h` on any command or script its options.

| Script | What |
|---|---|
| `dev.py` | The entry point for every command. Prints each step's time and keeps the last ones in `out/timings.json`. |
| `game.py` | Godot project checks behind `dev.py game` (`validate` and `walk` also fail on leaks at exit and GDScript warnings; `tour --frames [--cold]` reports frame times and first-use hitches). |
| `board.py` | The work board (GitHub Project 2) behind `dev.py board`; needs the `gh` CLI with the `project` scope. |
| `check.py` | T1-T9 of `src/headless/SPEC.md` against `out/<mode>/survivor`, and F1-F5 against `out/<mode>/friendslop` (`out/<mode>-x64/` with `--arch x86_64`; it does not build). |
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
python tools/box3d.py --arch x86_64   # macOS only: macos-x64 build, for Rosetta checks
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

## `check.py`

`dev.py check` builds both games' headless binaries (release), then runs this; `python tools/check.py` alone tests
existing binaries (`-h` for the options: a subset, another build mode, the Rosetta build, `--regen`).

- One `PASS`/`FAIL` line per test with its time, then a JSON line. Exit 0 when everything passed, 1 on a failure,
  2 on a usage error or a missing binary. `out/check.json` is the summary (its `platform` is the binary's own,
  read with `lipo` on macOS); `out/check/` keeps every command's line, stdout/stderr, traces, logs and
  `T9/bench.json`.
- F1-F5 (friendslop, the physics co-op game): sync-test 3600 ticks; two identical runs; a 4-client `bad` session
  whose relay log replays to the clients' checksums; a late join (a snapshot with joints); the replay of
  `games/friendslop/simulation/tests/testdata/` (macOS ARM64 reference, so Rosetta and CI prove movers, joints and
  platforms bit-exact).
- Every command runs under a timeout (sessions: `ticks/64·4 + 90` s; the rest 300–900 s), so a hung binary fails
  its test.
- T3 and T6 run their sessions on the virtual clock (`session --clock virtual`: one thread steps the relay, the
  clients and the network simulator through test time), so they take seconds and can't flake on timing; T3's six
  sessions run in parallel (`--jobs`, default 6). T4 reuses T3's 4-client `bad` log. T5 is the one wall-clock
  test: a UDP relay on a free localhost port plus 3 client processes (client 2 with `--profile bad`), 960 ticks,
  started first so it overlaps the others (`--serial` to disable); T9 runs after it.
- Seeds: tests use 42, the references 7. JSON field names and tick numbering: `src/headless/SPEC.md` (CLI,
  "Conventions").
