---
name: release
description: Playable game builds (macOS arm64 and Windows x64 zips in a GitHub prerelease) - cutting one from a tag, building one locally, how the pipeline works, and the rules a game's export must follow. Use when the developer asks for a release or a release build, and when changing a game's export_presets.cfg, its version keys, a .gdextension's dependencies, tools/release.odin or .github/workflows/release.yml.
---

# Releasing a game

Playable builds of a game under `games/<game>/` (a Godot project with `export_presets.cfg`) for **macOS arm64** and
**Windows x64**. CI makes them only for tags; the same steps run locally on either platform, each building its own.
**Push a tag only when the developer asks for a release in chat.**

## Before the tag

1. On `main`, at the commit to release: CI green for that commit, and `./uni verify` passes locally.
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
./uni release <game>                        # -> games/<game>/.out/release/<game>-dev-<sha>-<platform>.zip
./uni release --tag <game>-v<x.y.z>         # what the tag build does (the game and the version from the tag)
```

A game that imports `unified:eos` needs the five `EOS_*` IDs in the environment (`.env` holds `UNIFIED_*` only).
Without a tag, CI checks the pipeline from **Actions → release → Run workflow** (Windows only; any game, default
`survivor`).

## How the pipeline works

- **The version.** The tag is its only source: the repo's `project.godot` says `dev` and the presets `0.0.0`, and
  `uni release` stamps the tag's version into the export (`application/config/version`, which the main menu
  shows, and the presets' version keys) and fails if the export doesn't carry it.
- **The build** (`uni release`, `tools/release.odin`, the same on a CI runner and locally): dependencies, the release extension (on
  CI with the `EOS_*` repo secrets in that one step's environment), Godot's headless import and export, ad-hoc
  codesign on macOS, zip, and a headless smoke test of the unpacked zip.
- **The prerelease**, named after the tag: `<game>-v<version>-macos-arm64.zip` and `<game>-v<version>-windows-x64.zip`
  (each unpacks to one folder of its own name with the game inside), `SHA256SUMS.txt` (LF line endings, so
  `shasum -a 256 -c` works on macOS), and tester notes (how to open an unsigned build, plus
  `games/<game>/RELEASE_NOTES.md`).
- **Downloads.** Godot is the pinned editor in `.out/godot/<version>/` (or `UNIFIED_GODOT` at exactly that
  version); export templates go to Godot's standard folder (only this platform's files, pulled from the official
  `.tpz` by range requests). Every download is checked against its SHA-256 in `pins.cfg`.

## Rules for a game's export

- Presets named `macOS` (architecture `universal`: the official template has no arm64-only binary; `uni release`
  thins it to arm64 after export) and `Windows Desktop` (`application/modify_resources=false`, no rcedit needed).
  `project.godot` sets `application/config/version` and each preset its version keys (`application/short_version`
  and `application/version` on macOS, `application/file_version` and `application/product_version` on Windows):
  `uni release` fails if one is missing.
- The presets export Godot resources only (`all_resources`): files the game reads raw (`FileAccess`, e.g. `.level`
  files) must match the presets' `include_filter`, or the export silently leaves them out.
- The extension prints `unified: extension initialized` when it loads; the smoke test requires that line, exit 0
  and no `ERROR` lines. With the `--smoke-test` user argument the game starts single player and fails (an `ERROR`
  line, exit 1) if the session fails to start.
- Runtime libraries the extension needs ship through the `.gdextension` `[dependencies]` section; `uni release`
  fails if one is missing from the export.
- Online: when the extension imports `unified:eos`, every build needs the five `EOS_*` IDs and fails unless the game
  build compiled each value into the extension (as `-define`s; logs show them redacted) and the export ships the EOS
  SDK library; testers' machines have no EOS config.
  The EOS SDK reaches the build job as a cache entry from `.github/workflows/eos-sdk.yml`, so the build job's token
  is read-only.
- Release binaries contain the CI runner's source paths (`/Users/runner/work/...`, from bounds-check and assert
  locations). Accepted: they reveal only the repo's file layout and the runner's work folder (no secrets, no user
  data), and keeping bounds checks on in release is worth more than the tidiness.
