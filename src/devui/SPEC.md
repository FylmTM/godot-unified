# devui

Status: signed off 2026-11-16 (#10).

The in-game dev UI, built from Godot's own controls and driven from Odin (`src/devui`). Game-agnostic: the host passes
its values; it knows nothing about any game. `unified:godot` reaches it only through `godot/dev.odin`, which also
says what the host feeds it; building with `-define:UNIFIED_DEVUI=false` turns those calls into no-ops and drops the
package. Player builds keep it while friends playtest (F3 notes are how they report a problem); `uni release
--no-devui` builds without it, for the first public build (#33). `uni vet` checks that build compiles and the release
workflow builds and smoke-tests it. No third-party code.

## API

```odin
devui.init({feedback_dir, on_feedback, user, layer = 128, visible})   // main thread, scene tree up
devui.shutdown()
// each frame, before devui.frame:
devui.inspect(name, any_value)                      // a root of the Inspector's RTTI tree (read-only)
devui.inputs(name, any_value)                       // a root of the Input panel's
devui.plot(name, value, lo, hi, group = "game")     // a line graph (lo == hi: 0 to a round value above the max)
devui.lines(name, values, legend, lo, hi, group)    // up to 4 lines in one graph
devui.stack(name, parts, legend, group)             // up to 4 parts stacked bottom up
devui.mark(strip, lane, group)                      // a mark this frame in a strip (up to 4 lanes)
devui.stat(label, format, args..)                   // overlay line
devui.log(tick, state, format, args..)              // Events row: .Emitted / .Confirmed / .Cancelled, .None (a note)
devui.command(tick, state, format, args..)          // Commands row: .Sent / .Confirmed / .Refused
devui.frame(dt)                                     // updates the panels; dt feeds the frame graph and the frames line
devui.frames_reset()                                // the frames line (p50, p99, max) starts over (a session starts)
devui.group_shown(name)                             // a group's stat lines are shown with its graphs
devui.visible, devui.netsim, devui.netsim_changed   // F1 state; Conditions panel netsim (up, down; the host applies it)
devui.netsim_applies                                // false: no remote links (single player): the netsim part is greyed
devui.wants_mouse() / wants_keyboard()
devui.panel_shown(.Inspector)                       // the panel is open and the dev UI shown: worth feeding
```

## How it works

- **Retained.** The controls are built once on a CanvasLayer (128); `frame()` updates values: text at 10 Hz,
  graphs every frame, the trees' expanded rows at 10 Hz (a row's text is set only when it changed). Hidden: the
  layer is hidden; graph samples and log rows are still recorded.
- **Size.** Points, whatever the game's stretch: the layer's scale is HiDPI scale / the root viewport's canvas
  stretch, so a game's `canvas_items` stretch doesn't grow the dev UI. Compact by design: 12 px system fonts,
  1 px borders, an 18 px title bar, no help text. Checked on Windows (1280×720 to 1920×1080); a Retina Mac is not
  checked yet.
- **Theme.** Complete and its own (`theme.odin`): a game may change Godot's default theme in place, and theme
  lookup ends there, so every item the dev UI uses is set. Fonts are the system's (sans-serif; monospace for the
  overlay's numbers).
- **Overlay**, top right (◳ moves it to the next corner, when the game's own UI is there): the panel toggles, the
  graph-group toggles, the stat lines as a key / value grid, the graphs. Nearly opaque, so it reads over game UI.
  Clicks go through it, except on its buttons. The first line is `frames`: p50, p99 and max frame time since the
  session started (a click starts it over). The value column only grows while the same lines are shown, so numbers
  changing width never move the overlay; it fits again when the lines change.
- **Graphs** share one time axis, real time (the last 2 s): each frame takes a width proportional to how long it
  lasted, so a hitch covers as much of a graph as the time it cost and the graphs line up. Columns are fixed slices
  of absolute time, so the graphs scroll by whole columns instead of re-slicing. A pixel column shows the frames
  overlapping it: the frame graph and stacks their longest frame, lines their largest value, marks any. The frame
  graph is coloured green / yellow / red against 16.7 and 33.3 ms, its title the frame rate (frames shown in the
  last second), the last frame, the average and the longest of the last second; scales pick the smallest round step
  that fits. Each graph has its title and legend in a band above it: its parts with their average per frame over
  the last second (marks: per second); a thin rule separates the graphs. Graphs belong to groups the overlay
  toggles; only `frame` starts shown. The overlay shrinks to fit what is shown. What the host draws:
  `src/godot/SPEC.md` (The dev UI).
- **Panels**: our own floating panels, closed until toggled (not Godot `Window`s: embedded windows draw in the
  game's stretched coordinates, so their chrome can't be both small and unscaled). Drag the title bar to move, the
  corner to resize; ⧉ moves the body into a native OS window (closing it docks it back), × closes.
- **Inspector and Input.** Each a Tree walked by Odin RTTI, built lazily: a struct gets its rows when first
  expanded. Arrays are lists of their live elements ("300 of 1200"): a `sim.Table` (matched by RTTI) shows the items
  whose slot is alive, any other array the elements that aren't all zero; rows are keyed by element index, so an
  expanded entity stays expanded while others come and go (256 rows at most). Up to 4 numbers show as one value.
  Rows address values relative to their parent's, so the host may pass a new pointer each frame. Rows expanded by a
  click are built on the next frame (a Tree refuses new rows inside its own mouse handling). Read-only. Measured:
  870 rows expanded cost nothing per frame and ≤ 0.4 ms per 10 Hz refresh. The host copies the whole State for the
  Inspector every published frame while the dev UI is shown: cheap for today's games, it grows with the State.
- **Events and Commands.** Logs (the newest 1000 rows each): tick, state, text. Events: each event emitted (when
  first predicted), then confirmed or cancelled (a rollback undid it), and notes (desyncs). Commands: sent,
  confirmed (a verified tick carried it, any player's; its tick can be later than the one it was sent at), refused.
  `confirmed` in the title bar shows only confirmed rows and notes; `follow` keeps the newest in view.
- **Conditions.** A frame-rate cap (`Engine.max_fps`: none, 144, 60, 30, 15) and the network simulation per
  direction (latency, jitter, loss up to the relay and down from it; presets; "both ways" moves both together),
  greyed while `netsim_applies` is false (the settings stay for the next session with remote links).
- **Input.** Godot routes it: a click on a panel or button stops there, the overlay lets clicks through. Polled game
  input reads Input's action state, which Godot updates before the window sees the event, so a press on the dev UI
  (or in a popped-out panel) releases the actions it triggered: it never reaches the game, until the button is let go
  and pressed again. Only text fields take the keyboard (trees, sliders and buttons don't take focus); a click
  outside the dev UI gives it back. `wants_keyboard` is true while a dev text field (or a popped-out window) has the
  keyboard: the host's polled game input ignores keys then. A callable on the root window's `window_input` (before
  the scene sees anything) takes F1 (toggle) and F3 (open / close the note), also while hidden, tracks the cursor
  for `wants_mouse`, and releases the actions of a press on the dev UI.
- **F3.** Opens the note on its own (the rest of the dev UI stays as it is, hidden or not); F3 again closes it.
  The frame is read back before the note covers it and kept in memory, shown in the note (aspect kept as the panel
  resizes); closing without sending drops it. Enter sends (Ctrl+Enter: new line): writes
  `<dir>/<local time>[-n]/` (`20261116-153012`, `-2` for a second within the second) with `screenshot.png` (a
  failure is reported in the log and the note) and `note.txt` (`[note]` or `[bug]`, then the text), then calls
  `on_feedback`, where the host adds the session's recording so the note replays (`src/godot/SPEC.md`). Notes are a
  local tool: nothing is sent anywhere. Cost: F3 one ~20 ms frame (the read back), sending one ~30 ms frame (the PNG
  encode; drift, Windows, 1280×720).
- **Tests.** `uni test --suite godot-bindings` builds it under headless Godot (its controls exist) and checks that a
  press on an overlay button leaves an action bound to it released while a press elsewhere presses it. Every entry
  point needs Godot, so there is no Odin unit test; `tests/godot_driver` checks what the host feeds it (the
  confirmed commands, the recording).
- **Cost.** About 0.1–0.2 ms per frame shown with the frame group, the same as the Dear ImGui version it replaced
  (measured side by side in a 600-enemy survivor match). Every group shown: about 0.4 ms of our own code.

## Open

- Game-specific panels (through `unified:godot` when a game needs one).
- Edits through tick-stamped debug commands: the trees are read-only.
- The replay session's Timeline panel and the op log (`src/godot/SPEC.md`, Replay sessions; #124).
- Panel layout isn't remembered between runs.
