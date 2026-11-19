# Getting started

## Toolchain

macOS ARM64, Linux x64 or Windows x64, with:

- **A C toolchain for Odin's linker:** clang on macOS and Linux; on Windows, Visual Studio Build Tools (its linker
  and the Windows SDK). Nothing in the repo is C or C++.
- **git** and **curl** (macOS, Windows 10+ and Linux ship curl).
- **Editor:** VS Code with the OLS extension picks up `ols.json` (the `unified` and `box3d` collections, the strict
  checker flags, format on save with `odinfmt.json`).

Odin is not installed by hand: the first `./uni` downloads the release `pins.cfg` pins (SHA-256 checked) into a
per-user cache (`~/.cache/unified`, Windows `%LOCALAPPDATA%\unified`) and puts it first on PATH; no other Odin is
used. The CLI fetches or builds everything else (Godot, odinfmt, Box3D) from `pins.cfg` the same way, once per
machine.

A git-ignored `.env` at the root overrides a pin with a local checkout or install (`UNIFIED_GODOT`,
`UNIFIED_BOX3D`; `src/cli/README.md`, Local settings). Online play also needs the EOS SDK, which Epic's licence keeps
out of the repo: [`EOS.md`](EOS.md). Everything else, LAN included, works without it.

## First commands

From the repo root (`uni.cmd` on Windows):

```sh
./uni help                # every command; `./uni <command> -h` for its options (the first run builds the CLI)
./uni test                # build and run the odin suite
./uni run minimal_3d      # play an example game (builds its extension the first time)
./uni verify              # what CI runs, before handing work back
```

## A new game

```sh
./uni init ../mygame                    # a game repo: the template game, with unified as its submodule
./uni init examples/mygame --in-repo    # an example game inside this checkout
```

Both copy [`examples/minimal_3d`](../examples/minimal_3d/), which passes its own `verify` at once. A game repo runs
the same `./uni` from its own root. Coding agents: [`agents.md`](agents.md).

## Next

- [`examples/minimal_3d/README.md`](../examples/minimal_3d/README.md): the template game, what it shows and what a
  new game takes from the other examples; its [`GUIDE.md`](../examples/minimal_3d/GUIDE.md), which every new game
  carries: how to write gameplay that survives rollback.
- `./uni doc` lists the packages, `./uni doc <pkg>` prints one's API.
- [`src/README.md`](../src/README.md): how the core works inside.
