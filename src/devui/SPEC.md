# devui

Status: draft, pending #358

The in-game dev UI, built from Godot's own controls and driven from Odin (`src/devui`). Game-agnostic: the host passes
its values; it knows nothing about any game. `unified:godot` reaches it only through `godot/dev.odin`, which also
says what the host feeds it; building with `-define:UNIFIED_DEVUI=false` turns those calls into no-ops and drops the
package. Player builds keep it while friends playtest (F3 notes are how they report a problem); `uni release
--no-devui` builds without it. No third-party code.

## API

```odin
devui.init(shown, on_feedback)                      // main thread, scene tree up; on_feedback(dir, tag_bug) after an F3 note
devui.shutdown()
devui.is_ready()
// each frame, before devui.frame:
devui.inspect(name, any_value)                      // a root of the Inspector's RTTI tree (read-only)
devui.inputs(name, any_value)                       // a root of the Input panel's
devui.plot(group, name, value)                      // a line graph, from 0 to a round value above the max shown
devui.lines(group, name, values, legend)            // up to 4 lines in one graph
devui.stack(group, name, parts, legend)             // up to 4 parts stacked bottom up
devui.mark(group, strip, lane)                      // a mark this frame in a strip (up to 4 lanes)
devui.stat(label, format, args..)                   // an overlay line
devui.log(tick, state, format, args..)              // Events row: .Emitted / .Confirmed / .Cancelled, .None (a note)
devui.command(tick, state, format, args..)          // Commands row: .Sent / .Confirmed / .Refused
devui.frame(dt)                                     // updates the panels; dt feeds the frame graph and the frames line
devui.frame_stats() -> (items, ui_ms)               // controls and rows it made; its own time last frame
devui.frames_reset()                                // the frames line (p50, p99, max) starts over (a session starts)
devui.group_shown(name)                             // a group's stat lines are shown with its graphs
devui.visible, devui.netsim, devui.netsim_changed   // F1 state; the Conditions panel's netsim (the host applies it)
devui.netsim_applies                                // false: no remote links (single player): the netsim part is greyed
devui.wants_keyboard()                              // a dev text field has the keyboard: polled game input ignores keys
devui.wants_state()                                 // the Inspector or Input panel is open and shown: worth feeding
```

## How it works

- **Retained.** The controls are built once on a CanvasLayer above the game's UI; `frame()` updates values: text at
  10 Hz, graphs every frame, the trees' expanded rows at 10 Hz (a row's text is set only when it changed). Hidden:
  the layer is hidden; graph samples and log rows are still recorded.
- **Size.** Points, whatever the game's stretch: the layer's scale is HiDPI scale / the root viewport's canvas
  stretch, so a game's `canvas_items` stretch doesn't grow the dev UI.
- **Theme.** Complete and its own (`theme.odin`): a game may change Godot's default theme in place, and theme
  lookup ends there, so every item the dev UI uses is set.
- **Overlay** (a corner of the screen, movable): the panel toggles, the graph-group toggles, the stat lines, the
  graphs. Clicks go through it, except on its buttons. Its first line is `frames`: p50, p99 and max frame time since
  the session started (a click starts it over). The value column only grows while the same lines are shown, so
  numbers changing width never move the overlay.
- **Graphs** share one time axis, real time: each frame takes a width proportional to how long it lasted, so a
  hitch covers as much of a graph as the time it cost and the graphs line up. Columns are fixed slices of absolute
  time, so the graphs scroll by whole columns. A pixel column shows the frames overlapping it: the frame graph and
  stacks their longest frame, lines their largest value, marks any. Each graph's legend gives its parts' average per
  frame over the last second (marks: per second). Graphs belong to groups the overlay toggles; only `frame` starts
  shown. A graph's quads are drawn in one triangle array, sized once per frame.
- **Panels**: our own floating panels, closed until toggled (not Godot `Window`s: embedded windows draw in the
  game's stretched coordinates). Moved by the title bar, resized by the corner, popped out into a native OS window
  and docked back.
- **Inspector and Input.** Each a Tree walked by Odin RTTI, built lazily: a struct gets its rows when first
  expanded. Arrays are lists of their live elements: a `sim.Table` (matched by RTTI) shows the items whose slot is
  alive, any other array the elements that aren't all zero; rows are keyed by element index, so an expanded entity
  stays expanded while others come and go, and a row that leaves is reused. Rows address values relative to their
  parent's, so the host may pass a new pointer each frame. Read-only. The host copies the State for them only while
  one is shown (`wants_state`).
- **Events and Commands.** Logs (the newest 1000 rows each): tick, state, text. Events: each event emitted, then
  confirmed or cancelled, and notes (desyncs). Commands: sent, confirmed (a verified tick carried it, any player's),
  refused.
- **Conditions.** A frame-rate cap (`Engine.max_fps`) and the network simulation per direction (latency, jitter,
  loss), greyed while `netsim_applies` is false (the settings stay for the next session with remote links).
- **Input.** Godot routes it: a click on a panel or button stops there, the overlay lets clicks through. Polled game
  input reads Input's action state, which Godot updates before the window sees the event, so a press on the dev UI
  releases the actions it triggered: it never reaches the game until the button is let go and pressed again. Only
  text fields take the keyboard (`wants_keyboard`). A callable on the root window's `window_input` (before the scene
  sees anything) takes F1 (toggle) and F3 (the note), also while hidden.
- **F3.** Opens the note on its own; F3 again closes it. The frame is read back before the note covers it and shown
  in the note; closing without sending drops it. Enter sends: writes `<user data>/feedback/<local time>[-n]/` with
  `screenshot.png` and `note.txt` (`[note]` or `[bug]`, then the text), then calls `on_feedback`, where the host adds
  the session's recording so the note replays (`src/godot/SPEC.md`). Notes are a local tool: nothing is sent
  anywhere.
