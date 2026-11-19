---
name: release
description: Library releases (one `v<x.y.z>` tag on main, a full check, a GitHub release with generated notes; no game builds published) and local playable game builds (`uni release`: macOS arm64 and Windows x64 zips) - cutting a release, building a game locally, how the pipeline works, and the rules a game's export must follow. Use when the developer asks for a release or a playable build, and when changing a game's export_presets.cfg, its version keys, a .gdextension's dependencies, tools/release.odin or .github/workflows/release.yml.
---

# Releases

A release is a release of the library: one version, one tag, `v<major>.<minor>.<patch>` (optionally
`-rc.<n>`) on `main`. Game repos pin the `unified` submodule to it. **No game builds are published**: a tag's run
exports every game only to prove the pipeline works, and throws the zips away. **Push a tag only when the developer
asks for a release in chat, with its version.**

## Before the tag

1. On `main`, at the commit to release: CI green for that commit (macOS included), and `./uni verify` passes
   locally.
2. If the netcode protocol changed since the last release, a crossplay run passes (`docs/EOS.md`, Crossplay).
3. The version, after the last tag (`git tag -l 'v*'`): the developer's call.

## Cut it

```
git tag v<version> <commit> && git push origin v<version>
```

`.github/workflows/release.yml` runs, all or nothing:

- **the tag**: `v<major>.<minor>.<patch>` or `v<major>.<minor>.<patch>-rc.<n>` (numbers without leading zeros), on
  `main`; the workflow's first job is the one check of that rule;
- **check**: `ci.yml`, called: everything CI runs on a push to `main` (fmt, vet, the four test platforms with macOS,
  the godot job);
- **games**: on windows-x64 and macos-arm64, every game with an `export_presets.cfg` exported and smoke-tested
  (`uni release --no-eos --version <version>`, then the same with `--no-devui`), the zips thrown away;
- **publish**, only when both pass: a GitHub release titled `unified v<version>` (a prerelease while the major
  version is 0, and for a release candidate), its notes generated from the PRs merged since the last tag, with
  GitHub's source archives; no binaries.

Watch the run (`gh run list --workflow release.yml`). A failed run publishes nothing: delete the tag (locally and
`git push origin :refs/tags/v<version>`), fix, tag again. Report the release URL.
Without a tag, **Actions → release → Run workflow** (`gh workflow run release.yml --ref <branch>`) checks the
pipeline on any branch and publishes nothing: windows-x64 only unless `-f macos=true`, the games stamped
`dev-<commit>`.

## A playable build, locally

`uni release` stays local: it is how someone gets a playable build of a game (online-capable with EOS, which CI never
has). It builds this host's package (macOS arm64 on a Mac, Windows x64 on Windows) into
`games/<game>/.out/release/`.

```
./uni release                               # every game with export_presets.cfg, in turn
./uni release <game>                        # one: <game>-dev-<sha>-<platform>.zip
./uni release --version <x.y.z> [<game>]    # stamped with a release's version: <game>-v<x.y.z>-<platform>.zip
./uni release --no-eos <game>               # what a release's check builds: no EOS, single player and LAN
./uni release --no-devui <game>             # without the dev UI (-nodevui.zip): a public build
```

Playtest builds keep the dev UI (F3 notes are how a tester reports a problem); a public build drops it. A release's
check builds both; the smoke test checks the extension's `dev ui on|off`. A game that imports `unified:eos` needs
`UNIFIED_EOS_SDK` and the five `UNIFIED_EOS_*` IDs (`.env`, `docs/EOS.md`), or `--no-eos`.

## How a build works

- **The version.** The repo's `project.godot` says `dev` and the presets `0.0.0`; `uni release` stamps the version
  (`--version`, a release's from its tag; else `dev-<sha>`) into the export (`application/config/version`, which the
  main menu shows, and the presets' numeric version keys: a release candidate's numbers, `0.2.0-rc.1` puts `0.2.0`
  there; a local build's `dev-<sha>` puts `0.0.0`), restores the files byte for byte after, and fails if the export
  doesn't carry it.
- **The build** (`uni release`, `tools/release.odin`, the same on a CI runner and locally), per game: the release
  extension (online play needs the `UNIFIED_EOS_*` IDs and SDK, so only a developer's machine builds it; CI passes
  `--no-eos`; `--no-devui` drops the dev UI), Godot's headless import and export (any error line fails the build),
  ad-hoc codesign on macOS, a zip that unpacks to one folder of its own name with the game inside, its `.sha256` (LF
  line endings, so `shasum -a 256 -c` works on macOS), and a headless smoke test of the unpacked zip.
- **Downloads.** Godot is the pinned editor in the per-user cache, shared by every checkout (`uni setup` prints where;
  or `UNIFIED_GODOT` at exactly that version); export templates go to Godot's standard folder (only this platform's
  files, pulled from the official `.tpz` by range requests). Every download is checked against its SHA-256 in
  `pins.cfg`.

## Rules for a game's export

- Presets named `macOS` (architecture `universal`: the official template has no arm64-only binary; `uni release`
  thins it to arm64 after export) and `Windows Desktop` (`application/modify_resources=false`, no rcedit needed).
  `project.godot` sets `application/config/version` and each preset its version keys (`application/short_version`
  and `application/version` on macOS, `application/file_version` and `application/product_version` on Windows):
  `uni release` fails if one is missing.
- The presets export Godot resources only (`all_resources`): files the game reads raw (`FileAccess`, e.g. `.level`
  files) must match the presets' `include_filter`, or the export silently leaves them out.
- The smoke test runs a single-player session with unified's own flags (`-- --autostart --ticks N --quit-at-end`),
  nothing of the game's: it requires the extension's `unified: extension initialized` line, the session's result
  line at tick N, exit 0 and no `ERROR` lines. A game whose main scene starts a session of its own must leave
  `--autostart` to the library (`UnifiedSession.running` is true by the time its scripts are ready).
- Runtime libraries the extension needs ship through the `.gdextension` `[dependencies]` section; `uni release`
  fails if one is missing from the export. Box3D (unified-box3d's shared library, `libbox3d.dylib` / `box3d.dll`)
  is linked: an extension that uses physics doesn't load without it. `uni build` writes the section from what the
  extension links (Box3D, the EOS SDK): never edit it by hand.
- Online: when the extension imports `unified:eos` (its lobby), a build needs the five `UNIFIED_EOS_*` IDs and
  `UNIFIED_EOS_SDK` (`docs/EOS.md`) and fails unless the game build compiled each value into the extension (as
  `-define`s; logs show them redacted) and the export ships the EOS SDK library; testers' machines have no EOS
  config. With `--no-eos` (CI: no SDK, no secrets, Epic's licence) none of that: the package has no online play (the
  build fails if the export still holds an EOS SDK library). Online-capable packages are made locally.
- Release binaries contain the build machine's source paths (from bounds-check and assert locations). Accepted: they
  reveal only the repo's file layout and the work folder (no secrets, no user data), and keeping bounds checks on in
  release is worth more than the tidiness.
