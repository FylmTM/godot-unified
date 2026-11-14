# devui

Pending developer review (Godot controls replace Dear ImGui, developer, 2026-11-11).

The in-game dev UI, built from Godot's own controls and driven from Odin (`src/devui`). Game-agnostic: the game
passes its values; it knows nothing about any game. **Every build includes it for now**, release too (developer's
call). `unified:godot` reaches it only through `godot/dev.odin`: building with `-define:UNIFIED_DEVUI=false` turns
those calls into no-ops. `uni vet` checks that build. No third-party code.

## API

```odin
devui.init({feedback_dir, on_feedback, user, layer = 128, visible})   // main thread, scene tree up
devui.shutdown()
// each frame, before devui.frame:
devui.inspect(name, any_value)                      // RTTI tree (read-only)
devui.plot(name, value, lo, hi, group = "game")     // a line graph (lo == hi: 0 to a round value above the max)
devui.lines(name, values, legend, lo, hi, group)    // up to 4 lines in one graph
devui.stack(name, parts, legend, group)             // up to 4 parts stacked bottom up
devui.mark(strip, lane, group)                      // a mark this frame in a strip (up to 4 lanes)
devui.stat(label, format, args..)                   // overlay line
devui.log(tick, format, args..)                     // event log row (newest 1000 kept)
devui.frame(dt)                                     // updates the panels; dt feeds the frame-time graph
devui.visible, devui.netsim, devui.netsim_changed   // F1 state; Conditions panel netsim (up, down; the host applies it)
devui.wants_mouse() / wants_keyboard()
```

## How it works

- **Retained.** The controls are built once on a CanvasLayer (128); `frame()` updates values: text at 10 Hz,
  graphs every frame, the inspector's expanded rows at 10 Hz (a row's text is set only when it changed). Hidden:
  the layer is hidden; graph samples are still recorded.
- **Size.** Points, whatever the game's stretch: the layer's scale is HiDPI scale / the root viewport's canvas
  stretch, so a game's `canvas_items` stretch doesn't grow the dev UI. Compact by design: 12 px system fonts,
  1 px borders, an 18 px title bar, no help text.
- **Theme.** Complete and its own (`theme.odin`): a game may change Godot's default theme in place, and theme
  lookup ends there, so every item the dev UI uses is set. Fonts are the system's (sans-serif; monospace for the
  overlay's numbers).
- **Overlay**, top right (◳ moves it to the next corner, when the game's own UI is there): the panel toggles, the
  graph-group toggles, the stat lines as a key / value grid, the graphs. Nearly opaque, so it reads over game UI.
  Clicks go through it, except on its buttons.
- **Graphs** share one time axis, real time (the last 2 s): each frame takes a width proportional to how long it
  lasted, so a hitch covers as much of a graph as the time it cost and the graphs line up. Columns are fixed slices
  of absolute time, so the graphs scroll by whole columns instead of re-slicing (which made them jump). A pixel column shows the
  frames overlapping it: the frame graph and stacks their longest frame, lines their largest value, marks any. The
  frame graph is coloured green / yellow / red against 16.7 and 33.3 ms; scales pick the smallest round step that
  fits. Each graph has its title and legend in a band above it: its parts with their average per frame over the
  last second (marks: per second); a thin rule separates the graphs. Graphs belong to groups the overlay toggles; only `frame` starts shown. The host's groups
  (`godot/dev.odin`): `frame` (frame; main thread ms: views, dev ui, game, render), `sim` (sim thread ms and ticks
  stepped: verified, rollback, predicted; ticks ahead; sim events: rollback, late input, stall), `net` (round trip ms,
  bandwidth kB/s in and out, relay silence ms: time since the relay's last message), plus a render stats line (draw
  calls, triangles, video memory, nodes). The overlay shrinks to fit what is shown.
- **Conditions** panel: a frame-rate cap (`Engine.max_fps`: none, 144, 60, 30, 15) and the network simulation per
  direction (latency, jitter, loss up to the relay and down from it; presets; "both ways" moves both together).
- **Panels** (Inspector, Conditions, Events, Note): our own floating panels, closed until toggled. Drag the title bar
  to move, the corner to resize; ⧉ moves the body into a native OS window (closing it docks it back), × closes.
- **Inspector.** A Tree walked by Odin RTTI, built lazily: a struct gets its rows when first expanded. Arrays are
  lists of their live elements ("300 of 1200"): a `sim.Table` (matched by RTTI) shows the items whose slot is alive,
  any other array the elements that aren't all zero; rows are keyed by element index, so an expanded entity stays
  expanded while others come and go (256 rows at most). Up to 4 numbers show as one value. Rows address values
  relative to their parent's, so the host may pass a new pointer each frame. Rows expanded by a click are built on the next frame (a Tree refuses new rows inside its own mouse
  handling). Measured: 870 rows expanded cost nothing per frame and ≤ 0.4 ms per 10 Hz refresh.
- **Input.** Godot routes it: a click on a panel or button stops there, the overlay lets clicks through. Only text
  fields take the keyboard (trees, sliders and buttons don't take focus); a click outside the dev UI gives it back.
  `wants_keyboard` is true while a dev text field (or a popped-out window) has the keyboard: the host's polled game
  input ignores keys then. A callable on the root window's `window_input` (before the scene sees anything) takes
  F1 (toggle) and F3 (open / close the note), also while hidden, and tracks the cursor for `wants_mouse`.
- **F3.** Opens the note on its own (the rest of the dev UI stays as it is, hidden or not); F3 again closes it.
  Saves a screenshot, then shows the note with it (aspect kept as the panel resizes). Enter sends (Ctrl+Enter: new line): writes
  `<dir>/<stamp>/screenshot.png` and `note.txt` and calls `on_feedback`, where the host adds its snapshot, input
  log and net stats (not wired yet).
- **Tests.** `uni test --suite godot-bindings` builds it under headless Godot (its controls exist). Every entry
  point needs Godot, so there is no Odin unit test.
- **Cost.** About 0.1 ms per frame shown with the frame group, the same as the Dear ImGui version it replaced
  (measured side by side in a 600-enemy survivor match). Every group shown: about 0.4 ms of our own code.

## Open

- Switching it off in release builds (the flag above) once the developer decides.
- Game-specific panels (through `unified:godot` when a game needs one).
- Edits through tick-stamped debug commands (WORK.md). Today the inspector is read-only.
- Panel layout isn't remembered between runs.
- The F3 capture on a worker thread (~60 ms on the main thread today; it shows as a red bar in the frame graph).
