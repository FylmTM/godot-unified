# devui

Pending developer review (Godot controls replace Dear ImGui, developer, 2026-11-11).

The in-game dev UI, built from Godot's own controls and driven from Odin (`src/devui`). Game-agnostic: the game
passes its values; it knows nothing about any game. **Every build includes it for now**, release too (developer's
call). `godot_host` reaches it only through `godot_host/dev.odin`: building with `-define:UNIFIED_DEVUI=false` turns
those calls into no-ops. `uni vet` checks that build. No third-party code.

## API

```odin
devui.init({feedback_dir, on_feedback, user, layer = 128, visible})   // main thread, scene tree up
devui.shutdown()
// each frame, before devui.frame:
devui.inspect(name, any_value)                      // RTTI tree (read-only)
devui.plot(name, value, lo, hi)                     // overlay graph, 250 samples (lo == hi: auto scale)
devui.stat(label, format, args..)                   // overlay line
devui.log(tick, format, args..)                     // event log row (newest 1000 kept)
devui.frame(dt)                                     // updates the panels; dt feeds the frame-time graph
devui.visible, devui.netsim, devui.netsim_changed   // F1 state; Netsim panel values (the host applies them)
devui.wants_mouse() / wants_keyboard()
```

## How it works

- **Retained.** The controls are built once on a CanvasLayer (128); `frame()` updates values: text at 10 Hz,
  graphs every frame, the inspector's expanded rows at 10 Hz (a row's text is set only when it changed). Hidden:
  the layer is hidden and only the frame-time history is kept.
- **Size.** Points, whatever the game's stretch: the layer's scale is HiDPI scale / the root viewport's canvas
  stretch, so a game's `canvas_items` stretch doesn't grow the dev UI. Compact by design: 12 px system fonts,
  1 px borders, an 18 px title bar, no help text.
- **Theme.** Complete and its own (`theme.odin`): a game may change Godot's default theme in place, and theme
  lookup ends there, so every item the dev UI uses is set. Fonts are the system's (sans-serif; monospace for the
  overlay's numbers).
- **Overlay**, top right: the panel toggles, the stats, the frame-time graph, the plots. Clicks go through it,
  except on its buttons. The frame-time graph puts real time on the x axis (the last 2 s): each frame is as wide
  and as tall as it lasted, so a hitch covers as much of the graph as the time it cost; each pixel column shows the
  longest frame overlapping it, green / yellow / red against 16.7 and 33.3 ms, with the scale picking the smallest
  step that fits.
- **Panels** (Inspector, Netsim, Events, Note): our own floating panels, closed until toggled. Drag the title bar
  to move, the corner to resize; ⧉ moves the body into a native OS window (closing it docks it back), × closes.
- **Inspector.** A Tree walked by Odin RTTI, built lazily: a struct or array gets its rows when first expanded,
  arrays longer than 64 in chunks of 64. Rows address values by offset, so the host may pass a new pointer each
  frame. Rows expanded by a click are built on the next frame (a Tree refuses new rows inside its own mouse
  handling). Measured: 870 rows expanded cost nothing per frame and ≤ 0.4 ms per 10 Hz refresh.
- **Input.** Godot routes it: a click on a panel or button stops there, the overlay lets clicks through. Only text
  fields take the keyboard (trees, sliders and buttons don't take focus); a click outside the dev UI gives it back.
  `wants_keyboard` is true while a dev text field (or a popped-out window) has the keyboard: the host's polled game
  input ignores keys then. A callable on the root window's `window_input` (before the scene sees anything) takes
  F1 (toggle) and F3 (open / close the note), also while hidden, and tracks the cursor for `wants_mouse`.
- **F3.** Saves a screenshot, then shows the note with a thumbnail. Enter sends (Ctrl+Enter: new line): writes
  `<dir>/<stamp>/screenshot.png` and `note.txt` and calls `on_feedback`, where the host adds its snapshot, input
  log and net stats (not wired yet).
- **Tests.** `uni test --suite godot-bindings` builds it under headless Godot (its controls exist). Every entry
  point needs Godot, so there is no Odin unit test.
- **Cost.** About 0.1 ms per frame shown, the same as the Dear ImGui version it replaced (measured side by side in
  a 600-enemy survivor match); 0.07 ms of it is our own code.

## Open

- Switching it off in release builds (the flag above) once the developer decides.
- Game-specific panels (through `godot_host` when a game needs one).
- Edits through tick-stamped debug commands (WORK.md). Today the inspector is read-only.
- Panel layout isn't remembered between runs.
- The F3 capture on a worker thread (~60 ms on the main thread today; it shows as a red bar in the frame graph).
