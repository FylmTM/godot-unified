---
name: godot-examples
description: This repo's example games under examples/<game> (survivor, friendslop, drift, deckbuilder, holdout, playground, minimal_3d) and the Godot-side library code (src/godot, src/gdext) - the app layer every example but minimal_3d copies, what a new example takes, and the suites to run before handing back. Use with the unified-godot skill (the godot suite, levels, uni drive, windowed checks) after changing an example's GDScript, scenes or extension, or src/godot or src/gdext.
---

# The example games and the Godot-side library

The `unified-godot` skill is how any unified game is checked, run and driven; this is what only this repo adds. Here
there are several games: every command it names takes the example's name (`./uni test <game> --suite godot`,
`./uni drive <game> start`, `./uni bake <game>`), and its paths are under `examples/<game>/`.

Every example but minimal_3d (survivor, friendslop, drift, holdout, playground, deckbuilder) owns a copy of the same
app layer, so they all open on the same main menu and play the same way: `game/app/` (the `Game`, `Settings`, `Sfx`
and `LibraryCheck` autoloads), the menus and HUD panels in `game/ui/` (main menu, pause menu, settings, connect
overlay, session and controls panels, banner), `game/tools/menu_tool.gd`, `validate.gd` (it names the play scene:
the main scene is the menu) and `ui_walk.gd`. **A change to the app layer lands in every copy in the same PR**, unless
a game differs on purpose. Nothing compares them. On purpose: each game's `Sfx` sounds, `Settings` rows and
`UiTheme.PLAYER_COLORS` (its players' or heroes' colours); friendslop's and deckbuilder's pause menu and `Game` invite
friends into a running single-player session; the mouse-look games (friendslop, holdout, playground) let clicks
through the pause menu's dim, so the session panel's Copy works while the mouse is free; deckbuilder's `UiTheme`
palette and serif face are its tabletop's. A new example starts minimal_3d-shaped (no menus or settings: it plays
together through the session's flags and `uni coop`) and takes the app layer when it becomes one players open.
Online lobbies: `eos.lobby({})` in `godot.init` and `lobbies` in its headless main (`examples/minimal_3d/README.md`,
What a new game takes from where). An example with `export_presets.cfg` is one `uni release` builds: every one but
minimal_3d.

deckbuilder is the 2D one: its play scene is a table of Controls (`game/table.tscn`) on `canvas_items` stretch, its
views are Controls with data only, and its cards, enemies, map and felt are drawn in code (`game/ui/card_face.gd`,
`glyph.gd`: no image assets). Its sim tests and the headless binary run the `quick` tuning (`GAME_QUICK`); Godot plays
`GAME`.

A change to `src/godot`, `src/gdext` or anything between input and the sim runs every game's `session` step: it is
the check that the Godot host computes what the offline binary does.

Before handing back any Godot-side change: `./uni test --suite godot,godot-bindings` (every game, plus the binding
and host-view tests: what CI's Godot job runs).
