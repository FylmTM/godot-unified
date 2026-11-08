# unified

A purpose-built core for **cooperative games with deterministic rollback netcode**, written in **Odin**, with
Godot as the host. Fixed-tick deterministic sim, Box3D physics with a save/restore fork, snapshots, checksums,
sync-test, replays, and an input relay with prediction, rollback and late join. Rules for
working on it: [`AGENTS.md`](AGENTS.md). Plan, decisions and current work:
[`docs/WORK.md`](docs/WORK.md). Why and what for: [`docs/CONTEXT.md`](docs/CONTEXT.md). What the core must do:
[`spec/`](spec/).

## Layout

```
src/                 the `unified` collection (-collection:unified=src); one package per directory
  box3d/             Box3D bindings: pinned commit + our save/restore fork API (leaf)
  pod/               plain-data check for state blocks (RTTI walk: no pointers, no padding) (leaf)
  wire/              little-endian Writer/Reader for every binary format (leaf)
  game/              survivor-lite test game (spec/GAME.md): state block, pools, systems, world
  sim/               harness: ring of snapshots, checksum, portable snapshots, input log, offline modes
  netcode/           links (loopback, UDP, netsim), reliable channel, relay, client, sessions
  cli/               the `unified` CLI of spec/CORE.md §3 (package main)
tests/               `odin test` packages, one per module, black-box via the collection; tests.odin runs all
  lint/              determinism lint: bans core:math, matrix, f64 in game, ... per package
testdata/            macOS ARM64 reference input log, trace and snapshot for T7/T8
third_party/         box3d.patch (the fork); tools/box3d.py fetches + builds Box3D under third_party/box3d/
tools/               dev.py (the entry point), check.py (T1-T9), box3d.py, ci.py
ols.json, odinfmt.json   editor (OLS) and formatter configuration
```

Imports point one way: `cli → netcode → sim → game → box3d`, with `pod` and `wire` as leaves. Inside `src/`
packages import each other by relative path; consumers (tests, later games) import `unified:<pkg>`.

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

Everything goes through `tools/dev.py`; each command prints its time.

```
python tools/dev.py build [dev|release|debug]   # -> out/<mode>/unified[.exe]; builds Box3D on first use
python tools/dev.py test                        # odin test: unit tests + determinism lint (all packages)
python tools/dev.py check [--only T1,T7]        # release build, then T1-T9 (tools/check.py), ~70 s
python tools/dev.py fmt [--check]               # odinfmt over src/ and tests/
python tools/dev.py vet                         # odin check, strict flags, darwin/linux/windows targets
python tools/dev.py all                         # fmt --check, vet, test, check: what CI runs
```

| Mode | Flags | Use | Build (M4 Pro) |
|---|---|---|---:|
| `dev` | `-o:speed -use-separate-modules -debug` | everyday: optimized, debuggable | 0.9 s |
| `release` | `-o:speed` (one LLVM module) | fastest binary; what `check` and CI test | 2.5 s |
| `debug` | `-o:none -debug` | stepping in a debugger | 0.4 s |

All modes add `-vet -strict-style -vet-tabs -warnings-as-errors`; bounds checks stay on. The plain Odin commands
work too (the bindings import Box3D's static library by relative path): `odin build src/cli`,
`odin test tests -all-packages -collection:unified=src`.

Rosetta determinism check on Apple Silicon (x86_64 build against the macos-x64 Box3D):

```
python tools/dev.py build release --arch x86_64
python tools/check.py --only T1,T7,T8
```

Regenerate the T7/T8 references only on purpose, on macOS ARM64: `python tools/dev.py check --regen` (see
[`testdata/README.md`](testdata/README.md)).

## CI

`.github/workflows/ci.yml`: a `lint` job (format check, vet) and `test` jobs on Linux x64 and Windows x64 (`odin
test`, then T1-T9 with the T9 bench and step timings in the job summary). Odin, odinfmt and Box3D are cached.
