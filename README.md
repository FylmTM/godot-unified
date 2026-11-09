# unified

A purpose-built core for **cooperative games with deterministic rollback netcode**, written in **Odin**, with
Godot as the host. Fixed-tick deterministic sim, Box3D physics with a save/restore fork, snapshots, checksums,
sync-test, replays, and an input relay with prediction, rollback and late join. Rules for
working on it: [`AGENTS.md`](AGENTS.md). Plan, decisions and current work:
[`docs/WORK.md`](docs/WORK.md). Why and what for: [`docs/CONTEXT.md`](docs/CONTEXT.md). What the core must do:
[`spec/`](spec/).

## Layout

```
src/                 the `unified` collection (-collection:unified=src); one package per directory, specs in spec/
  wire/              little-endian Writer/Reader for every binary format (leaf)
  sim/               the deterministic harness, generic over a game: tables + handles, RNG, plain-data check,
                     snapshot ring, checksum, events, input log, portable snapshot
  physics/           Box3D as the sim's Extra state: Body_Ref, save/restore/hash/image
  box3d/             Box3D bindings: pinned commit + our save/restore fork API (leaf)
  dmath/             deterministic f32 helpers (leaf)
  netcode/           links (loopback, UDP, netsim), channel, relay, client, host; step API + hooks
  eos/               Epic Online Services: login, lobbies by code, P2P as a netcode link
  headless/          a game's headless binary: the CLI modes of spec/headless.md (CLI), generic over the game
  view/              host-agnostic view logic: triple buffer, pose tracks + smoothing, spawn-key sets, events
  gdext/             Godot bindings: generator (gen/), committed API dump (api/), bindings.txt, runtime, classes
  imgui/             vendored odin-imgui (pinned, local fixes); tools/imgui.py builds Dear ImGui
  devui/             the dev UI: ImGui -> Godot backend, overlay, RTTI inspector, F3 note
  godot_host/        UnifiedSession / SimView / SimBulkView, the session driver, view sync
games/survivor/      the test game, laid out like a game repo (Godot project root)
  simulation/        Odin (.gdignore): survivor/ = the game's sim package, headless/ = its headless binary,
                     extension/ = its GDExtension (godot_host + glue); game/ = everything Godot
tests/               `odin test` packages, one per module, black-box via the collection; tests.odin runs all
  lint/              determinism lint: bans core:math, matrix, f64 in game code, ... per package
  toy/               a tiny game for the library's own tests
  godot/             the binding tests' Godot project and test extension (dev.py godot-test)
testdata/            macOS ARM64 reference input log, trace and snapshot for T7/T8
third_party/         box3d.patch (the fork); Box3D, Dear ImGui and the EOS SDK are fetched under it (git-ignored)
tools/               dev.py (the entry point) and its parts: tools/README.md
docs/                WORK.md (plan), CONTEXT.md (why), RELEASE.md, EOS.md, research/, archive/
ols.json, odinfmt.json   editor (OLS) and formatter configuration
```

The import graph is in [`AGENTS.md`](AGENTS.md#layout-and-commands). Every package imports another through the
collection (`unified:<pkg>`), the same way games and tests do.

## Toolchain

- **Odin** `dev-2026-11` on PATH (macOS: `brew install odin`; CI downloads the release).
- **Python 3.9+** for `tools/` (stdlib only).
- **Box3D build:** git, CMake, Ninja and clang (macOS/Linux) or clang-cl (Windows; found on PATH, in
  `C:\Program Files\LLVM` or Visual Studio). Only needed the first time; `tools/box3d.py` caches the result.
- **odinfmt** (the formatter, part of OLS), pinned to OLS `85d88870`. Install it with
  `python tools/ci.py odinfmt ~/.local/share/unified-odinfmt` and put that directory on PATH (or set `ODINFMT`).
- **Editor:** VS Code with the OLS extension picks up `ols.json` (the `unified` collection, the strict checker
  flags, format on save with `odinfmt.json`).

## Commands

Everything goes through `tools/dev.py`; each command prints its time. The full list, with timings, is in
[`AGENTS.md`](AGENTS.md#layout-and-commands); `python tools/dev.py -h` prints it too.

Godot: the standard (non-.NET) 4.7.2 build, found via `$GODOT`, `godot` on PATH, `.toolchains/godot/`, or
`~/tools/godot` / `/Applications` on macOS (`python tools/ci.py godot` downloads the official one there). Dear ImGui
is fetched and built by `tools/imgui.py` on first use (clang++ / clang-cl, ~2.5 s).

| Mode | Flags | Use | Build (M4 Pro) |
|---|---|---|---:|
| `dev` | `-o:speed -use-separate-modules -debug` | everyday: optimized, debuggable | 1.0 s |
| `release` | `-o:speed` (one LLVM module) | fastest binary; what `check` and CI test | 3.5 s |
| `debug` | `-o:none -debug` | stepping in a debugger | 0.6 s |

All modes add `-vet -strict-style -vet-tabs -warnings-as-errors`; bounds checks stay on. The plain Odin commands
work too (the bindings import Box3D's static library by relative path): `odin build
games/survivor/simulation/headless -collection:unified=src`, `odin test tests -all-packages -collection:unified=src`.

Rosetta determinism check on Apple Silicon (an x86_64 build in `out/release-x64/` against the macos-x64 Box3D):
`python tools/dev.py check --arch x86_64 --only T1,T7,T8`.

Regenerate the T7/T8 references only on purpose, on macOS ARM64: `python tools/dev.py check --regen` (see
[`testdata/README.md`](testdata/README.md)).

## CI

`.github/workflows/ci.yml`: `lint` (format check, vet), `test` on Linux x64 and Windows x64 (`odin test`, then
T1-T9 with the T9 bench and step timings in the job summary) and `godot` on Linux x64 (`dev.py godot-checks`):
together what `dev.py all` runs. `release.yml` makes playable game builds for `<game>-v*` tags only
(`docs/RELEASE.md`); `eos-crossplay.yml` is the manual internet crossplay check (`spec/eos.md`); `eos-sdk.yml`
fetches the EOS SDK for the others (the only job with a write token, running no repository code). Actions, runner
images and downloads are pinned; Odin, odinfmt, Box3D, Dear ImGui, Godot and the EOS SDK are cached.
