---
name: release
description: Playable game builds (macOS arm64 and Windows x64 zips in a GitHub prerelease) - cutting one from a tag, building one locally, how the pipeline works, and the rules a game's export must follow. Use when the developer asks for a release or a release build, and when changing a game's export_presets.cfg, its version keys, a .gdextension's dependencies, tools/release.py or .github/workflows/release.yml.
---

# Releasing a game

Playable builds of a game under `games/<game>/` (a Godot project with `export_presets.cfg`) for **macOS arm64** and
**Windows x64**. CI makes them only for tags; the same steps run locally on either platform, each building its own.
**Push a tag only when the developer asks for a release in chat.**

## Before the tag

1. On `main`, at the commit to release: CI green for that commit, and `python tools/dev.py all` passes locally.
2. A local release build and smoke test pass on this machine (below).
3. If the netcode protocol or the game's lobby bucket changed since the last release, a crossplay run passes
   (`src/eos/SPEC.md`, Crossplay).
4. `games/<game>/RELEASE_NOTES.md` is current: the tester notes ship with the build.
5. Pick the version: `<game>-v<major>.<minor>.<patch>`, after the last tag (`git tag -l '<game>-v*'`).

## Cut it

```
git tag <game>-v<version> <commit> && git push origin <game>-v<version>
```

`.github/workflows/release.yml` builds both platforms and publishes the prerelease. Watch the run
(`gh run list --workflow release.yml`). A failed run publishes nothing: delete the tag (locally and
`git push origin :refs/tags/<game>-v<version>`), fix, tag again. Report the prerelease URL and the zip names.

## Locally

```
python tools/release.py build games/<game>                    # -> games/<game>/.out/release/<game>-dev-<sha>-<platform>.zip
python tools/release.py build games/<game> --version <x.y.z>  # what the tag build does (stamps the version)
```

Without a tag, CI checks the pipeline from **Actions → release → Run workflow** (Windows only; any game folder,
default `games/survivor`).

## How the pipeline works

- **The version.** The tag is its only source: the repo's `project.godot` says `dev` and the presets `0.0.0`, and
  `tools/release.py` stamps the tag's version into the export (`application/config/version`, which the main menu
  shows, and the presets' version keys) and fails if the export doesn't carry it.
- **The build** (`tools/release.py`, the same on a CI runner and locally): dependencies, the release extension (on
  CI with the `EOS_*` repo secrets in that one step's environment), Godot's headless import and export, ad-hoc
  codesign on macOS, zip, and a headless smoke test of the unpacked zip.
- **The prerelease**, named after the tag: `<game>-v<version>-macos-arm64.zip` and `<game>-v<version>-windows-x64.zip`
  (each unpacks to one folder of its own name with the game inside), `SHA256SUMS.txt` (LF line endings, so
  `shasum -a 256 -c` works on macOS), and tester notes (how to open an unsigned build, plus
  `games/<game>/RELEASE_NOTES.md`).
- **Downloads.** Godot comes from `common.find_godot` (`$GODOT`, `godot` on PATH, `.toolchains/godot/`,
  `~/tools/godot/`), else the official editor is downloaded into `.toolchains/godot/`; export templates go to Godot's
  standard folder (only this platform's files, pulled from the official `.tpz` by range requests). Every download is
  checked against a pinned SHA-256 (`tools/common.py`, `tools/release.py`).

## Rules for a game's export

- Presets named `macOS` (architecture `universal`: the official template has no arm64-only binary; `release.py`
  thins it to arm64 after export) and `Windows Desktop` (`application/modify_resources=false`, no rcedit needed).
  `project.godot` sets `application/config/version` and each preset its version keys (`application/short_version`
  and `application/version` on macOS, `application/file_version` and `application/product_version` on Windows):
  `release.py` fails if one is missing.
- The presets export Godot resources only (`all_resources`): files the game reads raw (`FileAccess`, e.g. `.level`
  files) must match the presets' `include_filter`, or the export silently leaves them out.
- The extension prints `unified: extension initialized` when it loads; the smoke test requires that line, exit 0
  and no `ERROR` lines. With the `--smoke-test` user argument the game starts single player and fails (an `ERROR`
  line, exit 1) if the session fails to start.
- Runtime libraries the extension needs ship through the `.gdextension` `[dependencies]` section; `release.py`
  fails if one is missing from the export (and, on tag builds with EOS, if the EOS SDK library is).
- Online: when the extension imports `unified:eos`, every CI build needs the five `EOS_*` secrets and fails unless
  the game build compiled each value into the extension (`-define`s from `eos.defines()`; `python tools/eos.py
  defines` shows them redacted) and the export ships the EOS SDK library; testers' machines have no EOS config.
  The EOS SDK reaches the build job as a cache entry from `.github/workflows/eos-sdk.yml`, so the build job's token
  is read-only.
- Release binaries contain the CI runner's source paths (`/Users/runner/work/...`, from bounds-check and assert
  locations). Accepted: they reveal only the repo's file layout and the runner's work folder (no secrets, no user
  data), and keeping bounds checks on in release is worth more than the tidiness.
