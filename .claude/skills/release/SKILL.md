---
name: release
description: Cut a playable build of a game (macOS arm64 and Windows x64 zips in a GitHub prerelease) from a tag, or build one locally. Use only when the developer asks for a release or a release build.
disable-model-invocation: true
---

# Releasing a game

How the pipeline works and the rules a game's export must follow: `docs/RELEASE.md`. Only the developer, or a
session they authorise in chat, pushes tags.

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
`git push origin :refs/tags/<game>-v<version>`), fix, tag again.

Report the prerelease URL and the zip names to the developer.

## Locally

```
python tools/release.py build games/<game>                    # -> games/<game>/.out/release/<game>-dev-<sha>-<platform>.zip
python tools/release.py build games/<game> --version <x.y.z>  # what the tag build does (stamps the version)
```

Each platform builds its own. Without a tag, CI checks the pipeline from **Actions → release → Run workflow**
(Windows only; any game folder).
