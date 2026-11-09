# imgui

Pending developer review (written after the code, 2026-11-09).

Dear ImGui for the dev UI (`src/devui/SPEC.md`): `src/imgui` is vendored odin-imgui declarations, `tools/imgui.py`
builds the C++ library. No tests of its own; the dev UI's are in `tests/godot` and the game's checks.

## What it is

- **Pinned:** Dear ImGui `v1.92.9b-docking` (commit `b48d1af`, checked after the clone) and dear_bindings v0.21's
  generated C API for that tag (release files, checked by SHA-256), matching the vendored Odin declarations in
  `src/imgui/imgui.odin` (MIT, `src/imgui/LICENSE`).
- **Local changes** in the vendored file, marked `unified:`: the library comes from `third_party/imgui/build/
  <platform>/` by relative path; `Key` gains the `ImGuiMod_*` chord bits; `TableFlag.SizingStretchProp` is
  removed (use `TableFlags_SizingStretchProp`).
- **Build** (`tools/imgui.py`, called by `dev.py game build` and `godot-test`): six C++ files in parallel (~2.5 s on
  an M4 Pro), then a ~1 ms stamp check. Same compilers as Box3D, static CRT on Windows.
- It is render-side code: nothing in it feeds the sim.

## Upgrading

Bump `IMGUI_TAG`, `IMGUI_COMMIT`, `DB_TAG` and the `DB_FILES` hashes together, re-vendor `imgui.odin` from
odin-imgui for the same dear_bindings version, re-apply the `unified:` changes, then `dev.py vet` and
`godot-checks`.

## Open

- Nothing.
