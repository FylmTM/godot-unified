---
name: godot-game
description: Building, running and checking a Godot game under games/<game> (survivor, friendslop, drift) - which step of the godot test suite proves what, the order to run them in, baking a level after editing it, and the windowed checks that need a display. Use after changing a game's GDScript, scenes, levels, extension or view contract, or src/godot_host, src/view or src/gdext, and when asked to run or look at a game.
---

# Working on a Godot game

A game is a Godot project in `games/<game>/` (`res://`): Odin in `simulation/` (the sim, its headless binary, its
GDExtension in `extension/`, its tests), everything Godot in `game/`. The view reads the sim and never writes it;
player input and commands are the only way in. Every command and its options: `./uni help`, `-h` on a command. Rules
for editing Godot files load on their own (`.claude/rules/godot.md`).

## The loop, cheapest first

Run from the repo root. `<game>` is the folder name under `games/`. Every command builds the game's extension when
it is stale and re-imports the project when an imported file changed, so there is no separate build or import step
(`./uni build <game>` builds anyway).

`./uni test <game> --suite godot` runs these steps in order, each when the game has what it needs; `--only` picks
steps (`--only validate,walk`). Every run is strict: an `ERROR` line, a leak at exit or a GDScript warning fails it.

1. `validate`: compiles every script with warnings as errors (`untyped_declaration` included), loads and
   instantiates every scene, flags unknown `.tscn` properties, checks the game's own contract (survivor: the mock
   session's `constants()` and idle `hud()` against the native session's; friendslop: item sizes against the sim;
   drift: the view contract), runs the menu for 30 frames. Run it after every GDScript or scene change.
2. `walk` (`ui_walk.gd`, survivor): a headless scripted walk through the menus and flows with real input events,
   on the mock session.
3. `tour`: the real game, headless, through lobby and match (quick).
4. `session`: a headless Godot session's checksums must equal the offline binary's. Run it after a change to the
   extension, `src/godot_host` or anything between input and the sim.
5. `editor`: the extension loads in a headless editor with no `ERROR` lines.
6. `bake`: each level's `.level` file is current.

`./uni test --suite godot,godot-bindings` runs every game's steps (the games in parallel) plus the binding,
host-view and session-lifecycle tests (`tests/godot_views/session_check.gd`: leave, then host or join at once; it
covers a session or netcode change): what CI's Godot job runs. Run it before handing back any Godot-side change.

## Levels

A game's levels are Godot scenes in `game/levels/` baked to `.level` files the sim loads (`src/level/SPEC.md`).
After editing a level scene or its markers:

```
./uni bake <game>
```

Commit the `.tscn` and the `.level` together; the `bake` step fails when they disagree.

## Looking at it

These need a display and steal focus (the CLI gives it back on macOS); they don't run in CI:

- `./uni run <game>` (windowed; arguments after `--` go to the game), `./uni editor <game>`.
- `./uni tool <game> <script> --window [--shots] [-- args]`: any of the game's tool scripts in a window, PNGs in
  `games/<game>/.out/shots/<script>/` with `--shots`. Survivor's walk: `tool survivor ui_walk --window --shots --
  --mock`. A whole match: `tool <game> tour --window --shots`; `-- --frames` reports frame times and first-use
  hitches, `--cold` clears the shader caches first.
- `./uni tool survivor play_check --window`: a bot plays (`-- --coop`, `-- --bench N`).
- `./uni coop <game>`: two processes through EOS, the host picks the friend up (EOS setup: `docs/EOS.md`).

Read the PNGs to check what you changed looks right.
