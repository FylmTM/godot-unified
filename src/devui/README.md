# `unified:devui`: the in-game dev UI

Graphs, stats, an inspector of the sim's state, event and command logs, network conditions and F3 notes, built from
Godot's own controls (through `unified:gdext`) and driven from Odin. Game-agnostic: the host passes its values and
the dev UI knows nothing about any game. `unified:godot` reaches it only through `godot/dev.odin`, which says what
the host feeds it; `-define:UNIFIED_DEVUI=false` turns those calls into no-ops. Player builds keep it while friends
playtest (F3 notes are how they report a problem); a public build turns it off. No third-party code.

## How it works

- **Retained.** The controls are built once on a CanvasLayer above the game's UI; `frame()` updates their values.
  While hidden the layer is hidden, and graph samples and log rows are still recorded, so showing it shows the
  recent past. The overlay and its graphs are `overlay.odin`'s header, the Inspector and Input trees
  `inspector.odin`'s, the theme (complete and its own, whatever a game does to Godot's default one) `theme.odin`'s.
- **Draw groups.** The host passes the sim's debug draw group names every frame (`draw_groups`); the overlay keeps a
  toggle per name, remembered by name while it lives, so the next session shows what the last one did, and returns
  the shown ones. What is drawn and where is the host's.
- **Command forms.** The host describes forms (numbers, toggles, choices: a game's dev commands) and packs what a
  Send returns (`command_forms`, `take_form`); they sit above the Commands log, which then shows the command Sent and
  Confirmed like a script's.
- **Timeline.** While the host plays a replay it passes the playhead's state every frame (`timeline`) and gets what
  the panel asked for (play or pause, a step, a seek on the slider, the speed); the panel opens with a replay.
- **Size.** In points, whatever the game's stretch: the layer's scale is the HiDPI scale over the root viewport's
  canvas stretch, so a game's `canvas_items` stretch doesn't grow the dev UI.
- **Panels** are our own floating controls, closed until toggled, not Godot `Window`s: an embedded window draws in
  the game's stretched coordinates. A panel pops out into a native OS window and docks back.
- **Input.** Godot routes it: a click on a panel or button stops there, the overlay lets clicks through. Polled game
  input reads Input's action state, which Godot updates before the window sees the event, so a press on the dev UI
  releases the actions it triggered: it never reaches the game until the button is let go and pressed again. Only
  text fields take the keyboard (`wants_keyboard`, which the host's game input obeys). F1 (toggle) and F3 (the note)
  are taken from the root window's `window_input`, before the scene sees anything, also while the dev UI is hidden.
- **F3.** Opens the note on its own, without F1; F3 again closes it. The frame is read back before the note covers
  it and shown in the note, and `on_note_open` lets the host note the moment (the tick the note is about, not the one
  it is sent at); closing without sending drops it. Enter sends: the note is written into a new directory
  under `<user data>/feedback/`, then `on_feedback` lets the host add the session's recording, so the note replays
  (`src/godot/README.md`, How it works). `note_save` writes one the same way with no one typing it (the host's
  control socket). Notes are a local tool: nothing is sent anywhere.
