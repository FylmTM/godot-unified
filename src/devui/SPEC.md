# devui

Decided autonomously 2026-11-09, pending developer review.

The in-game dev UI: Dear ImGui drawn into Godot from Odin (`src/devui`, with `src/imgui`, built by `uni setup`).
Game-agnostic: the game passes its values; it knows nothing about any game. **Every build includes it for now**,
release too (developer's call). `godot_host` reaches it only through `godot_host/dev.odin`: building with
`-define:UNIFIED_DEVUI=false` turns those calls into no-ops and links no ImGui (survivor's library: 2.9 MB ->
1.5 MB). `uni vet` checks that build; turning it off for players is that one flag.

## API

```odin
devui.init({feedback_dir, on_feedback, user, layer = 128, visible})   // main thread, scene tree up
devui.shutdown()
// each frame, before devui.frame:
devui.inspect(name, any_value, editable = false)   // RTTI tree (structs, arrays with a list clipper, enums, ...)
devui.plot(name, value, lo, hi)                     // overlay graph, 240 samples (lo == hi: auto scale)
devui.stat(label, format, args..)                   // overlay line
devui.log(tick, format, args..)                     // event log row (newest 1000 kept)
devui.frame(dt)                                     // build + submit
devui.visible, devui.netsim, devui.netsim_changed   // F1 state; Netsim panel values (the host applies them)
devui.wants_mouse() / wants_keyboard()
```

## How it works

- **Third-party code.** `uni setup` builds Dear ImGui 1.92.9b-docking and dear_bindings v0.21's C API into
  one static library per platform: clang++ on macOS and Linux, clang-cl + llvm-lib on Windows, the same compilers
  Box3D uses. It takes ~2.5 s and is cached by a stamp. `src/imgui` is odin-imgui at a pinned commit with three
  marked local changes: the library path, the `ImGuiMod_*` keys, and `SizingStretchProp`. The font is Open Sans
  SemiBold, committed with its OFL license, because Godot's default font is a WOFF2 that stb_truetype can't read.
- **Rendering.** Each ImGui draw command becomes a pooled RenderingServer canvas item on a CanvasLayer (layer
  128), clipped to its rect, with the command's vertex range copied into reused Packed arrays. ImGui 1.92's
  texture requests map to `texture_2d_*`. The Godot traps from the spike are handled: canvas children need an
  explicit `draw_index`, and the clip flag must be set again after `canvas_item_clear`. When hidden, nothing is
  built or drawn.
- **Input.** A Callable on the root Window's `window_input` signal decodes events before the scene sees them. F1
  toggles the UI and F3 opens the note; both are consumed. While ImGui wants the mouse or keyboard, events are
  marked handled. Sizes are in points (`screen_get_scale`).
- **F3.** Saves a screenshot, then shows a note with a thumbnail. Send writes `<dir>/<stamp>/screenshot.png` and
  `note.txt` and calls `on_feedback`, where the host adds its snapshot, input log and net stats (not wired yet).
- **Tests.** `uni test --suite godot-bindings` draws it under headless Godot (canvas items appear). Every entry point
  needs Godot, so there is no Odin unit test.
- **Cost.** About 0.2–0.5 ms of main-thread time per frame when shown (spike: 0.34–0.52 ms with every panel open).

## Open

- Switching it off in release builds (the flag above) once the developer decides.
- Game-specific windows (an `add_panel` existed unused and was removed; add it back through `godot_host` when a
  game needs one).
- Edits through tick-stamped debug commands (WORK.md). Today the inspector is read-only over a state copy.
- The F3 capture on a worker thread (~60 ms on the main thread today).
