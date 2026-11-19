---
name: godot-examples
description: This repo's example games under examples/<game> (survivor, friendslop, drift, minimal_3d) and the Godot-side library code (src/godot, src/gdext) - the app layer survivor, friendslop and drift each copy, what a new example takes, and the suites to run before handing back. Use with the godot-game skill (the loop, levels, uni drive, windowed checks) after changing an example's GDScript, scenes or extension, or src/godot or src/gdext.
---

# The example games and the Godot-side library

The `godot-game` skill is how any unified game is built, run, driven and checked; this is what only this repo adds.

survivor, friendslop and drift each own a copy of the same app layer: `game/app/` (the `Game`, `Settings`, `Sfx` and
`LibraryCheck` autoloads), the menus and HUD panels in `game/ui/`, `game/tools/menu_tool.gd` and `ui_walk.gd`. **A
change to the app layer lands in every game in the same PR**, unless a game differs on purpose. Nothing compares
them. A new example doesn't copy it: it stays minimal_3d-shaped (no menus or settings), plays together through the
session's flags and `uni coop`, and opts into online lobbies with `eos.lobby({})` in `godot.init` and `lobbies` in
its headless main (`examples/minimal_3d/README.md`, What a new game takes from where).

A change to `src/godot`, `src/gdext` or anything between input and the sim runs every game's `session` step: it is
the check that the Godot host computes what the offline binary does.

Before handing back any Godot-side change: `./uni test --suite godot,godot-bindings` (every game, plus the binding
and host-view tests: what CI's Godot job runs).
