# Game releases

Playable builds of a game under `games/<game>/` (a Godot project with `export_presets.cfg`) for **macOS arm64** and
**Windows x64**. CI makes them only for tags; the same steps run locally on either platform, each building its own.

Cutting a build (the checks before a tag, tagging, a failed run, local builds): the `release` skill
(`.claude/skills/release/`).

## The pipeline

A tag `<game>-v<version>` on a commit of `main` starts it. The tag is the only source of the version: the repo's
`project.godot` says `dev` and the presets `0.0.0`, and `tools/release.py` stamps the tag's version into the export
(`application/config/version`, which the main menu shows, and the presets' version keys) and fails if the export
doesn't carry it.

`.github/workflows/release.yml` then builds `games/survivor` on a Windows and a macOS runner with `tools/release.py`
(dependencies, release extension with the `EOS_*` repo secrets in that one step's environment, Godot 4.7.2 headless
import and export, ad-hoc codesign on macOS, zip, a ~5 s headless smoke test of the unpacked zip) and publishes a
GitHub **prerelease** named after the tag: `<game>-v<version>-macos-arm64.zip`, `<game>-v<version>-windows-x64.zip`
(each unpacks to one folder of its own name with the game inside),
`SHA256SUMS.txt` (LF line endings, so `shasum -a 256 -c` works on macOS), and tester notes (how to open an unsigned
build, plus `games/<game>/RELEASE_NOTES.md`). Only the developer, or a session they authorise, pushes tags. A failed
run publishes nothing.

`tools/release.py build` runs the same steps locally, each platform building its own. Godot comes from
`common.find_godot` (`$GODOT`, `godot` on PATH, `.toolchains/godot/`, `~/tools/godot/`), else the official editor is
downloaded into `.toolchains/godot/`; export templates go to Godot's standard folder (only this platform's files,
pulled from the official `.tpz` by range requests). Every download is checked against a pinned SHA-256
(`tools/common.py`, `tools/release.py`). Without a tag, CI checks the pipeline with **Actions → release → Run
workflow** (Windows only; any game folder, default `games/survivor`).

## Rules for a game

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
