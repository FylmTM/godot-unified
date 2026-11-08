# Game releases

Playable builds of a game under `games/<game>/` (a Godot project with `export_presets.cfg`) for **macOS arm64** and
**Windows x64**. CI makes them only for tags; the same steps run locally on a Mac.

## Cut a build

```
git tag survivor-v0.1.0 && git push origin survivor-v0.1.0      # <game>-v<version>, on a commit of main
```

`.github/workflows/release.yml` then builds `games/survivor` on a Windows and a macOS runner with `tools/release.py`
(dependencies, release extension with the `EOS_*` repo secrets in its environment, Godot 4.7.2 headless import and
export, ad-hoc codesign on macOS, zip, a ~5 s headless smoke test of the unpacked zip) and publishes a GitHub
**prerelease** named after the tag: `<game>-<version>-macos-arm64.zip`, `<game>-<version>-windows-x64.zip`,
`SHA256SUMS.txt`, and tester notes (how to open an unsigned build, plus `games/<game>/RELEASE_NOTES.md`). Only the
orchestrator pushes tags. A failed run publishes nothing; delete the tag, fix, tag again.

## Locally (macOS)

```
python tools/release.py build games/survivor    # -> games/survivor/.uni/release/survivor-dev-<sha>-macos-arm64.zip
```

~20 s warm (~50 s cold). Godot comes from `$GODOT`, `~/tools/godot/Godot_v4.7.2.app` or a download into `.toolchains/godot/`;
export templates go to Godot's standard folder (only this platform's files, pulled from the official `.tpz` by
range requests). Without a tag, CI checks the pipeline with **Actions → release → Run workflow** (Windows only; any
game folder, default `games/survivor`; `experiments/release-standin` is a minimal project with a tiny Odin
GDExtension that checks the pipeline without any game code).

## Rules for a game

- Presets named `macOS` (architecture `universal`: the official template has no arm64-only binary; `release.py`
  thins it to arm64 after export) and `Windows Desktop` (`application/modify_resources=false`, no rcedit needed).
- The extension prints `unified: extension initialized` when it loads; the smoke test requires that line, exit 0
  and no `ERROR` lines. The game may use the `--smoke-test` user argument.
- Runtime libraries the extension needs ship through the `.gdextension` `[dependencies]` section; `release.py`
  fails if one is missing from the export (and, on tag builds with EOS, if the EOS SDK library is).
- Online: once `tools/eos.py` exists, tag builds need the five `EOS_*` secrets and fail unless the game build
  compiled each value into the extension (`-define`s from `python tools/eos.py defines`); testers' machines have
  no EOS config. The build job has `contents: write` because the EOS SDK is a draft-release asset.
