---
name: godot-examples
description: This repo's example games under examples/<game> (survivor, friendslop, drift, deckbuilder, holdout, playground, minimal_3d) and the Godot-side library code (src/godot, src/gdext) - the app layer survivor, friendslop and drift each copy, what a new example takes, and the suites to run before handing back. Use with the unified-godot skill (the godot suite, levels, uni drive, windowed checks) after changing an example's GDScript, scenes or extension, or src/godot or src/gdext.
---

# The example games and the Godot-side library

The `unified-godot` skill is how any unified game is checked, run and driven; this is what only this repo adds. Here
there are several games: every command it names takes the example's name (`./uni test <game> --suite godot`,
`./uni drive <game> start`, `./uni bake <game>`), and its paths are under `examples/<game>/`.

survivor, friendslop and drift each own a copy of the same app layer: `game/app/` (the `Game`, `Settings`, `Sfx` and
`LibraryCheck` autoloads), the menus and HUD panels in `game/ui/`, `game/tools/menu_tool.gd` and `ui_walk.gd`. **A
change to the app layer lands in every game in the same PR**, unless a game differs on purpose. Nothing compares
them. A new example doesn't copy it: it stays minimal_3d-shaped (no menus or settings: holdout is one), plays together
through the session's flags and `uni coop`, and opts into online lobbies with `eos.lobby({})` in `godot.init` and `lobbies` in
its headless main (`examples/minimal_3d/README.md`, What a new game takes from where).

deckbuilder is such an example with a UI of its own and no app layer: one table scene (`game/main.tscn`) that holds
the session and its menus as panels, Control views with data only, and a `game/tools/ui_walk.gd` that extends
`UnifiedTool` directly; `canvas_items` stretch scales its table with the window. Its sim tests and the headless
binary run the `quick` tuning (`GAME_QUICK`); Godot plays `GAME`.

A change to `src/godot`, `src/gdext` or anything between input and the sim runs every game's `session` step: it is
the check that the Godot host computes what the offline binary does.

Before handing back any Godot-side change: `./uni test --suite godot,godot-bindings` (every game, plus the binding
and host-view tests: what CI's Godot job runs).
