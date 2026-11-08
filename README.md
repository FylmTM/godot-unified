# unified

`unified` is a hobby research project for a purpose-built game engine: an ECS-style deterministic simulation with
Photon-Quantum-style predict/rollback netcode built in. It's code-first and agent-first, for co-op games that need
Mac ARM ↔ Windows x64 crossplay. The current phase (phase 2) builds the same headless core (fixed-tick sim, Box3D
physics with a save/restore fork, snapshots, checksums, sync-test, replays, an input relay with prediction, rollback
and late join) in **C++, Odin and Rust**, then picks the language. Read [`docs/PLAN.md`](docs/PLAN.md) for the phases
and decisions, [`docs/CONTEXT.md`](docs/CONTEXT.md) for the background, and [`spec/`](spec/) for what the core must do.

## Layout

```
spec/CORE.md, spec/GAME.md     the phase 2 spec: core + netcode + CLI + tests, and the headless test game
docs/                          plan, context, research write-ups
bench/                         earlier benchmarks (specs and RESULTS.md files only; sources stay local)
third_party/box3d.patch        Box3D save/restore fork, applied by tools/box3d.py
tools/box3d.py                 fetch + patch + build Box3D for the host (shared by all languages)
tools/check.py                 language-neutral test harness (T1-T9) driving impl/<lang>/out/<mode>/unified
tools/ci.py                    CI helpers (job detection, Odin setup, summary table)
impl/cpp, impl/odin, impl/rust implementations; each has build.py dev|release and a README with its report
testdata/<lang>/               committed macOS ARM64 reference logs, traces and snapshots (T7/T8)
.github/workflows/ci.yml       Linux x64 + Windows x64 × cpp/odin/rust
```

## Build and test locally (macOS)

You need Python 3.9+, git, CMake, Ninja and Xcode's clang, plus the toolchain for whichever language you're working
on. For C++, clang is enough. For Odin, `odin` `dev-2026-11` on PATH. For Rust, rustup; `impl/rust/rust-toolchain.toml`
pins 1.98.

```
python3 tools/box3d.py                  # once (later runs are a no-op): Box3D -> third_party/box3d/build/macos-arm64
python3 tools/box3d.py --arch x86_64    # optional: macos-x64 Box3D, for Rosetta determinism checks

python3 impl/cpp/build.py release       # -> impl/cpp/out/release/unified    (likewise odin, rust; or `dev`)
python3 tools/check.py cpp              # build + T1-T9; summary in impl/cpp/out/check.json
python3 tools/check.py odin --only T1,T2
python3 tools/check.py rust --regen     # deliberately rewrite testdata/rust/ (macOS ARM64 only)
```

CI runs the same `tools/box3d.py` and `tools/check.py <lang>` on Linux x64 and Windows x64 (clang-cl) for each
language that has a `build.py`, and prints a comparison table in the run summary. For details see
[`tools/README.md`](tools/README.md) and [`testdata/README.md`](testdata/README.md).
