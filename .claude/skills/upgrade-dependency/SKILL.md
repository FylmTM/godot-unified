---
name: upgrade-dependency
description: Upgrading a pinned dependency of unified - Box3D (the fork), Dear ImGui and dear_bindings, Godot (the editor, export templates and the GDExtension API dump), Odin, odinfmt (OLS) or the EOS SDK. Where each pin lives, what to bump together, and what proves the upgrade safe. Use when bumping any of them, or when a pin's hash or commit has to change.
---

# Upgrading a dependency

Every download that ends up in a toolchain or a shipped build is pinned by commit or SHA-256 (`tools/README.md`).
An upgrade is safe when the tests say so: every dependency has tests covering what we use (AGENTS.md).

For every upgrade:

1. Bump the pins listed below together, in one commit.
2. Rebuild cold (the tool's `--clean`, or delete its folder under `third_party/` or `.toolchains/`).
3. `python tools/dev.py all`. Every game's reference run must still reproduce byte for byte: if one changes, the
   simulation changed, and the `sim-change` skill applies. Say in the commit why it changed.
4. Run CI on the branch on all four platforms: `gh workflow run ci.yml --ref <branch>`.
5. The PR names the old and new version and what changed upstream that matters to us.

## Box3D (the fork)

- Pin: `BOX3D_COMMIT` in `tools/box3d.py`. The fork is `third_party/box3d.patch`: rebase it until it applies exactly.
- `tests/box3d` compiles a C layout probe against the pinned headers: update the bindings in `src/box3d` and their
  `#assert`s until it passes.
- `tests/box3d`'s golden trace (`GOLDEN`) pins the fork's results. If it or a reference run changes, the simulation
  changed: update `GOLDEN` and regenerate the reference runs deliberately (`sim-change`).
- Run `python tools/box3d.py --clean` after a compiler upgrade too (the build stamp doesn't cover the compiler).
- What we use and how the fork works: `src/box3d/SPEC.md`.

## Dear ImGui and dear_bindings

- Pins in `tools/imgui.py`: `IMGUI_TAG`, `IMGUI_COMMIT`, `DB_TAG` and the `DB_FILES` hashes, together.
- Re-vendor `src/imgui/imgui.odin` from odin-imgui for the same dear_bindings version, then re-apply the local
  changes marked `unified:` (`src/imgui/SPEC.md` lists them).
- Check with `python tools/dev.py vet` and `python tools/dev.py godot-checks`.

## Godot

- **Editor and export templates** (a patch release, same baseline): `GODOT_VERSION` and the `GODOT_EDITORS` hashes in
  `tools/common.py`, `TEMPLATE_SHA256` in `tools/release.py` (GitHub's asset digests for the new release). Update the
  version in `README.md` (Getting started) and the games' READMEs if they name it. Check with `godot-checks`, each
  game's `game validate` and `game tour`, and a local release build (`release` skill).
- **The GDExtension API baseline** (a new minor version, e.g. 4.7 to 4.8): regenerate the committed dump in
  `src/gdext/api/` with the official standard build, from that folder, then regenerate the bindings:

  ```
  godot --headless --dump-extension-api --dump-gdextension-interface-json
  python tools/dev.py gen --force && python tools/dev.py vet && python tools/dev.py godot-checks
  ```

  `compatibility_minimum` in every `.gdextension` (the games' and `tests/godot*`) follows the baseline. `bindings.txt` lists what we bind (a
  test fails on unused entries). Never edit the dump by hand.

## Odin

- Pin: `ODIN_TAG` in `.github/workflows/ci.yml` and `.github/workflows/eos-crossplay.yml`, and the release assets'
  hashes in `ODIN_SHA256` in `tools/ci.py`:
  `gh api repos/odin-lang/Odin/releases/tags/<tag> --jq '.assets[] | [.name, .digest]'`.
- Odin's own changes can move float results: the reference runs are the check. Look at the release notes for
  changes to `core:` packages we use (`core:hash/xxhash`, `core:net`, `core:encoding`) and to `-vet` rules.
- odinfmt is built with Odin: rebuild it (below) and run `python tools/dev.py fmt`.

## odinfmt (OLS)

- Pin: `OLS_COMMIT` in `tools/ci.py`. Build it with `python tools/ci.py odinfmt <dest>` (README.md, Getting
  started).
- A new formatter may reformat code: run `python tools/dev.py fmt` and commit the result on its own, so the diff of
  the bump stays readable.

## EOS SDK

- Pin: `VERSION` and `ASSET_SHA256` in `tools/eos.py`; the library names in `LIB_NAMES` must agree with
  `LIB_NAME` in `src/eos/api.odin`.
- Unzip the new C SDK locally (`docs/EOS.md`, step 3), then `python tools/eos.py upload` packs the pruned SDK into a
  new draft release `eos-sdk-<version>` and prints the hashes to pin. `tools/eos.py -h` has the details.
- Check the header layouts with `tests/eos`, then two processes through EOS and a crossplay run (`src/eos/SPEC.md`,
  Testing and Crossplay).
