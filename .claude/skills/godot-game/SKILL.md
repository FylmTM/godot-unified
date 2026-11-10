---
name: godot-game
description: Building, running and checking a Godot game under games/<game> (survivor, friendslop, drift) - which dev.py game check proves what, the order to run them in, exporting a level after editing it, and the windowed checks that need a display. Use after changing a game's GDScript, scenes, levels, extension or view contract, or src/godot_host, src/view or src/gdext, and when asked to run or look at a game.
---

# Working on a Godot game

A game is a Godot project in `games/<game>/` (`res://`): Odin in `simulation/` (the sim, its headless binary, its
GDExtension in `extension/`, its tests), everything Godot in `game/`. The view reads the sim and never writes it;
player input and commands are the only way in. Every command and its options: `python tools/dev.py -h`. Rules for
editing Godot files load on their own (`.claude/rules/godot.md`).

## The loop, cheapest first

Run from the repo root. `<game>` is the folder name under `games/`.

1. `game build <game>`: the GDExtension into `games/<game>/.out/bin/`. Needed after any Odin change under
   `simulation/` or `src/`; the games without a GDScript mock (friendslop, drift) don't start without it.
2. `game validate <game>`: compiles every script with warnings as errors (`untyped_declaration` included), loads
   and instantiates every scene, flags unknown `.tscn` properties, checks the game's own contract (survivor: the mock
   session's `constants()` and idle `hud()` against the native session's; friendslop: item sizes against the sim;
   drift: the view contract) and that each level's `.level` export is current, runs the menu for 30 frames, and fails
   on leaks reported at exit. Run it after every GDScript or scene change.
3. `game walk <game>`: a headless scripted walk through the menus and flows with real input events (survivor: with
   the mock session).
4. `game tour <game>`: the real game, headless, through lobby and match (needs the library).
5. `game headless <game>`: a Godot session's checksums must equal the offline binary's. Run it after a change to the
   extension, `src/godot_host` or anything between input and the sim.
6. `game session-check <game>`: leave, then host or join at once. Run it after a session or netcode change.
7. `game editor-check <game>`: the extension loads in a headless editor with no `ERROR` lines.

`python tools/dev.py godot-checks` runs `godot-test` (bindings and host views), then 5, 6, 7, 2 and 3 for every game:
what CI's Godot job runs. Run it before handing back any Godot-side change.

## Levels

A game's levels are Godot scenes in `game/levels/` exported to `.level` files the sim loads (`src/level/SPEC.md`).
After editing a level scene or its markers:

```
python tools/dev.py game export-level <game>
```

Commit the `.tscn` and the `.level` together; `game validate` fails when they disagree.

## Looking at it

These need a display and steal focus; they don't run in CI:

- `game run <game>` (windowed; arguments after `--` go to the game), `game editor <game>`.
- `game shots <game>`: the walk in a window, PNGs in `games/<game>/.out/shots/`.
- `game tour <game> --shots`: a whole match in a window, PNGs in `games/<game>/.out/tour/`. `--frames` reports frame
  times and first-use hitches.
- `game play <game>`: a bot plays in a window (`--coop`, `--bench N`).
- `game coop <game>`: two processes through EOS, the host picks the friend up (EOS setup: `docs/EOS.md`).

Read the PNGs to check what you changed looks right.

## When the import cache is stale

`game import <game>` refreshes Godot's import cache (`.godot/`); the checks run it when an imported file changed.
