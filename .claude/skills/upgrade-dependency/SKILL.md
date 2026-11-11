---
name: upgrade-dependency
description: Upgrading a pinned dependency of unified - Box3D (the unified-box3d release), Godot (the editor, export templates and the GDExtension API dump), Odin, odinfmt (OLS) or the EOS SDK. Where each pin lives (pins.cfg), what to bump together, and what proves the upgrade safe. Use when bumping any of them, or when a pin's hash or commit has to change.
---

# Upgrading a dependency

Every pin is in `pins.cfg` (`src/cli/SPEC.md`, Pins): a commit or a SHA-256 for every download that ends up in a
toolchain or a shipped build. An upgrade is safe when the tests say so: every dependency has tests covering what we
use (AGENTS.md).

For every upgrade:

1. Bump the pins listed below together, in one commit. Every build stamp covers its pins, so the next command
   rebuilds or refetches what changed.
2. `./uni verify --long` (every suite's long variant). Every game's reference run must still reproduce byte for byte: if one changes, the simulation
   changed, and the `sim-change` skill applies. Say in the commit why it changed.
3. `./uni selftest` (a fresh clone and a new game repo, end to end).
4. Run CI on the branch on all four platforms: `gh workflow run ci.yml --ref <branch>`.
5. The PR names the old and new version and what changed upstream that matters to us.

## Box3D (unified-box3d)

- Box3D is a release of [unified-box3d](https://github.com/FylmTM/unified-box3d) (Box3D ported to Odin, a shared
  library with its bindings). Pins in `[box3d]`: `tag` (`<upstream commit>-r<revision>`) and each platform's zip
  hash, from the release's `SHA256SUMS`: `gh release download <tag> -R FylmTM/unified-box3d -p SHA256SUMS -O -`.
- The bindings come with the release: `src/b3` mirrors them, and `tests/b3` checks every mirrored struct's layout
  and each wrapper against the library. Update `src/b3` until `./uni vet` and those tests pass.
- `tests/b3`'s golden trace (`GOLDEN`) pins the library's results. If it or a reference run changes, the simulation
  changed: update `GOLDEN` and regenerate the reference runs deliberately (`sim-change`).
- CI on all four platforms proves each platform's library (they must agree on every golden value and reference run).
- Before a release exists: `UNIFIED_BOX3D=<unified-box3d checkout>` in `.env`, and `./uni setup` builds the library
  there (`src/cli/SPEC.md`, Dependencies). Pin the release before merging.
- What we use: `src/b3/SPEC.md`; how the port differs from upstream: unified-box3d's README and SPEC.md.

## Godot

- **Editor and export templates** (a patch release, same baseline): `[godot] version` and its three editor hashes,
  `[godot_templates]` (GitHub's asset digests for the new release:
  `gh api repos/godotengine/godot/releases/tags/<version>-stable --jq '.assets[] | [.name, .digest]'`; the
  templates' hashes are of the files inside the `.tpz`). Update the version in the games' READMEs if they name it.
  Check with `./uni test --suite godot,godot-bindings` and a local release build (`release` skill).
- **The GDExtension API baseline** (a new minor version, e.g. 4.7 to 4.8): regenerate the committed dump in
  `src/gdext/api/` with the official standard build, from that folder, then regenerate the bindings:

  ```
  godot --headless --dump-extension-api --dump-gdextension-interface-json
  ./uni godot-gen --force && ./uni vet && ./uni test --suite godot,godot-bindings
  ```

  `compatibility_minimum` in every `.gdextension` (the games', `tests/godot*` and the template game's in
  `src/cli/template/`) follows the baseline. `bindings.txt` lists what we bind (a test fails on unused entries).
  Never edit the dump by hand.

## Odin

- Pins in `[odin]`: `tag`, `commit` (the CLI refuses any other Odin) and the release assets' hashes:
  `gh api repos/odin-lang/Odin/releases/tags/<tag> --jq '.assets[] | [.name, .digest]'` and
  `gh api repos/odin-lang/Odin/git/ref/tags/<tag> --jq .object.sha`. Install the same release locally.
- Odin's own changes can move float results: the reference runs are the check. Look at the release notes for
  changes to `core:` packages we use (`core:hash/xxhash`, `core:net`, `core:encoding`, `core:os`, `core:flags`,
  `core:compress`) and to `-vet` rules.
- odinfmt is built with Odin: it rebuilds on the next `./uni fmt`.

## odinfmt (OLS)

- Pin: `[odinfmt] commit`.
- A new formatter may reformat code: run `./uni fmt` and commit the result on its own, so the diff of the bump stays
  readable.

## EOS SDK

- Pins in `[eos_sdk]`: `version` and the hash of each part's zip. The library names in `src/cli/eos.odin`
  (`EOS_PARTS`, `eos_lib`) must agree with `LIB_NAME` in `src/eos/api.odin` and the games' `.gdextension`
  `[dependencies]`.
- Unzip the new C SDK locally (`docs/EOS.md`, step 3), point `UNIFIED_EOS_SDK` at it (`.env`), then
  `./uni eos upload` packs the pruned SDK into a new draft release `eos-sdk-<version>` and prints the hashes to pin.
- Check the header layouts with `tests/eos`, then two processes through EOS and a crossplay run (`src/eos/SPEC.md`,
  Testing and Crossplay).
