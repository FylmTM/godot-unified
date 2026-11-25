---
name: upgrade-dependency
description: Upgrading a pinned dependency of unified - Box3D (the unified-box3d release), Godot (the editor, export templates and the GDExtension API dump), Odin, odinfmt (OLS) or the EOS SDK. Where each pin lives (pins.cfg), what to bump together, and what proves the upgrade safe. Use when bumping any of them, or when a pin's hash or commit has to change.
---

# Upgrading a dependency

Every pin is in `pins.cfg` (`src/cli/README.md`, Pins): a commit or a SHA-256 for every download that ends up in a
toolchain or a shipped build. An upgrade is safe when the tests say so: every dependency has tests covering what we
use (AGENTS.md).

For every upgrade:

1. Bump the pins listed below together, in one commit. Every build stamp covers its pins, so the next command
   rebuilds or refetches what changed.
2. `./uni verify --long` (every suite's long variant). Every game's reference run must still reproduce byte for
   byte: if one changes, the simulation changed, and the `library-sim-change` skill applies. Say in the commit why it
   changed.
3. `./uni selftest` (a fresh clone and a new game repo, end to end).
4. The PR's own CI (Linux x64 and arm64, Windows x64) is the check before merging; `main`'s run after the merge
   covers macOS (AGENTS.md, Workflow).
5. The PR names the old and new version and what changed upstream that matters to us.

## Box3D (unified-box3d)

- Box3D is a release of [unified-box3d](https://github.com/FylmTM/unified-box3d) (Box3D ported to Odin, a shared
  library with its bindings). Pins in `[box3d]`: `tag` (`<upstream commit>-r<revision>`) and each platform's zip
  hash, from the release's `SHA256SUMS`: `gh release download <tag> -R FylmTM/unified-box3d -p SHA256SUMS -O -`.
- The bindings come with the release: `src/physics/box3d_types.odin` mirrors their structs, and
  `tests/physics/box3d_test.odin` checks every mirror's layout and enum against them. Update `src/physics` (the
  mirrors, and a wrapper per new or changed Box3D proc) until `./uni vet` and those tests pass.
- `BOX3D_GOLDEN` there pins the library's results. If it or a reference run changes, the simulation changed:
  `./uni test --bless` re-pins them with the new pin, deliberately (`library-sim-change`).
- `tests/physics/debug_draw_test.odin` holds Box3D's debug draw to "changes nothing": a flag in
  `physics.DEBUG_DRAW_PURE` that starts writing to the world fails `debug_draw_changes_nothing` (take it out of the
  set: it is then drawn between a snapshot save and restore); `debug_draw_joint_extras_write` failing means joint
  extras stopped writing (move `.Joint_Extras` into the set).
- The `tag` is part of `sim.compat_of` (builds on other releases refuse each other), so every reference run's log and
  snapshot carry a new compat: `./uni test --bless` re-pins every `REFERENCE` (the games' and the toy's) and
  `GOLDEN_LIBRARY`, with the bump; what moved says whether the results did (`unified/src/headless/README.md`,
  Re-pinning).
- CI proves each platform's library (they must agree on every golden value and reference run): the PR's own run
  before merging, `main`'s after it for macOS (AGENTS.md, Workflow). `verify` also runs the odin suite against the
  release's debug library (the `box3d-debug` suite), whose asserts catch misused ids.
- Speed: compare `./uni bench`'s `physics` row (`.out/bench.json`'s `rows.physics`: through the plug-in, step, save,
  restore, both hashes, image and load, and rays on a pile of 512 awake boxes, plus 64 character updates;
  `tests/physics/bench`) on the old pin and the new one, on the same
  machine (`git worktree add --detach .out/old-pin origin/main` for the old one), and each game's step, save and
  re-sim. A slower operation is found and explained before the bump merges.
- Before a release exists: `UNIFIED_BOX3D=<unified-box3d checkout>` in `.env`, and `./uni setup` builds the library
  there (`src/cli/README.md`, Dependencies). Pin the release before merging.
- What we use: `src/physics/README.md`; how the port differs from upstream: unified-box3d's README and SPEC.md.

## Godot

- **Editor and export templates** (a patch release, same baseline): `[godot] version` and its four editor hashes
  (macOS, Windows, Linux x64 and arm64), `[godot_templates]` (GitHub's asset digests for the new release:
  `gh api repos/godotengine/godot/releases/tags/<version>-stable --jq '.assets[] | [.name, .digest]'`; the
  templates' hashes are of the files inside the `.tpz`). Check with `./uni test --suite godot,godot-bindings` and a
  local release build (`./uni release <game>`, the `unified-release` skill).
- **The GDExtension API baseline** (a new minor version, e.g. 4.7 to 4.8): regenerate the committed dump in
  `src/gdext/api/` with the official standard build, from that folder, then regenerate the bindings:

  ```
  godot --headless --dump-extension-api --dump-gdextension-interface-json
  ./uni vet && ./uni test --suite godot,godot-bindings   # vet regenerates the bindings: the dump changed
  ```

  `compatibility_minimum` in every `.gdextension` (the games' and `tests/godot*`'s) follows the baseline. `bindings.txt`
  lists what we bind (a test fails on unused entries). Never edit the dump by hand.

## Odin

- Pins in `[odin]`: `tag`, `commit` (the CLI refuses any other Odin) and the release assets' hashes:
  `gh api repos/odin-lang/Odin/releases/tags/<tag> --jq '.assets[] | [.name, .digest]'` and
  `gh api repos/odin-lang/Odin/git/ref/tags/<tag> --jq .object.sha`. Install the same release locally.
- Odin's own changes can move float results: the reference runs and golden traces are the check. Odin isn't in
  `sim.compat_of`, so a moved one means bump `sim.LIBRARY_VERSION`, then `./uni test --bless` (`library-sim-change`).
  Look at the release notes for
  changes to `core:` packages we use (`core:hash/xxhash`, `core:net`, `core:encoding`, `core:os`, `core:flags`,
  `core:compress`) and to `-vet` rules.
- odinfmt is built with Odin: it rebuilds on the next `./uni fmt`.

## odinfmt (OLS)

- Pin: `[odinfmt] commit`.
- A new formatter may reformat code: run `./uni fmt` and commit the result on its own, so the diff of the bump stays
  readable.

## EOS SDK

- Pin in `[eos_sdk]`: `version` only (the SDK is never fetched: Epic's licence). The library names in
  `src/cli/eos.odin` (`EOS_LIB`) must agree with `LIB_NAME` in `src/eos/api.odin` and the games' `.gdextension`
  `[dependencies]`.
- Download the new C SDK from Epic's portal on each developer machine (`docs/EOS.md`, step 3), point
  `UNIFIED_EOS_SDK` at it (`.env`); `uni setup` checks its `eos_version.h` against the pin.
- CI has no SDK, so the checks are local: the header layouts and library load in `tests/eos` (on each OS you can),
  then two processes through EOS and a crossplay run (`docs/EOS.md`,
  Testing over real EOS).
