---
name: godot-game
description: Building, running and checking a Godot game under games/<game> (survivor, friendslop, drift, minimal_3d) - which step of the godot test suite proves what, the order to run them in, baking a level after editing it, and the windowed checks that need a display. Use after changing a game's GDScript, scenes, levels, extension or view contract, or src/godot or src/gdext, and when asked to run or look at a game.
---

# Working on a Godot game

A game is a Godot project in `games/<game>/` (`res://`): Odin in `simulation/`, everything Godot in `game/`, the
library's tool scripts mirrored into `addons/unified/` before every run. Every command builds a stale extension and
re-imports changed files first: there is no separate build or import step.

survivor, friendslop and drift each own a copy of the same app layer: `game/app/` (the `Game`, `Settings`, `Sfx` and
`LibraryCheck` autoloads), the menus and HUD panels in `game/ui/`, `game/tools/menu_tool.gd` and `ui_walk.gd`. **A
change to the app layer lands in every game in the same PR**, unless a game differs on purpose. Nothing compares
them.

## The loop, cheapest first

`./uni test <game> --suite godot` runs these steps in order (`--only validate,walk` picks some). An `ERROR` line, a
leak at exit or a GDScript warning fails a step.

- `import`, `editor`: the project imports and the extension loads in a headless editor.
- `session`: a headless Godot session's checksums equal the offline binary's. After a change to the extension,
  `src/godot` or anything between input and the sim.
- `bake`: the view index and every `.level` file are current.
- `validate`: every script compiles with warnings as errors, every scene loads, and the game's own contract holds
  (`game/tools/validate.gd`, where a game has one). After every GDScript or scene change. It stops at the first strict error; to list them
  all, run `godot --headless --path games/<game> -s res://addons/unified/validate.gd -- --no-settings --frames=5`
  and read its `Parse Error` lines.
- `walk`: a scripted walk through the menus and flows with real input events, and the game's own play smoke
  (`_walk_play()` in its `game/tools/ui_walk.gd`).
- `uni tool <game> tour` (not a suite step): the real game through a whole match, by hand or with `--frames`.

Before handing back any Godot-side change: `./uni test --suite godot,godot-bindings` (every game, plus the binding
and host-view tests: what CI's Godot job runs).

## Levels

A level is a Godot scene baked to the `.level` file the sim loads, committed beside it (`src/level/SPEC.md`): a new
one goes in `game/levels/`; one kept elsewhere is found by its `.level`. After
editing a level scene or its markers, run `./uni bake <game>` and commit the `.tscn` and the `.level` together.

## Looking at it

These need a display and don't run in CI. Every window follows AGENTS.md's window rule.

- `./uni run <game>`: play it (arguments after `--` go to the game).
- `./uni tool <game> <script> --window --shots`: a tool script (`ui_walk`, `tour`) in a window, PNGs in
  `games/<game>/.out/shots/<script>/`. `tour -- --frames` reports frame times and first-use hitches.
- `./uni coop <game>`: a host and a joiner process through EOS (`--lan`: direct UDP), then the game's own play.

Read the PNGs to check that what you changed looks right.
