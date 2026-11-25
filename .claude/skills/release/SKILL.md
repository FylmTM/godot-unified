---
name: release
description: Library releases of unified (one `v<x.y.z>` tag on main, a full check, every example exported and smoke-tested, a GitHub release with generated notes; no game builds published) - cutting a release and how its pipeline works. Use when the developer asks for a release of unified, and when changing .github/workflows/release.yml or `uni release` itself (src/cli/cmd_release.odin). A playable build of a game is the unified-release skill.
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
- **games**: on windows-x64 and macos-arm64, every game with an `export_presets.cfg` (minimal_3d, the template,
  included) exported and smoke-tested (`uni release --no-eos --version <version>`, then the same with `--no-devui`), the
  zips thrown away;
- **publish**, only when both pass: a GitHub release titled `unified v<version>` (a prerelease while the major
  version is 0, and for a release candidate), its notes generated from the PRs merged since the last tag, with
  GitHub's source archives; no binaries.

Watch the run (`gh run list --workflow release.yml`). A failed run publishes nothing: delete the tag (locally and
`git push origin :refs/tags/v<version>`), fix, tag again. Report the release URL.
Without a tag, **Actions → release → Run workflow** (`gh workflow run release.yml --ref <branch>`) checks the
pipeline on any branch and publishes nothing: windows-x64 only unless `-f macos=true`, the games stamped
`dev-<commit>`.

## Game builds

`uni release` is a public command of `unified:cli` (`src/cli/cmd_release.odin`): a game repo builds its game with it,
and here it builds every example with an `export_presets.cfg` into `examples/<game>/.out/release/` (`./uni release
<game>` for one). Building one, how a build works and the rules a game's export follows: the `unified-release` skill
(written for a game repo: drop `unified/` from its paths). A change to `uni release` is a change every game sees: check
it against the demo game (the `demo-game` skill) with a local build there.
