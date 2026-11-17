---
name: godot-game
description: Building, running and checking a Godot game under games/<game> (survivor, friendslop, drift, minimal_3d) - which step of the godot test suite proves what, the order to run them in, baking a level after editing it, and the windowed checks that need a display. Use after changing a game's GDScript, scenes, levels, extension or view contract, or src/godot, src/view or src/gdext, and when asked to run or look at a game.
---

# Working on a Godot game

A game is a Godot project in `games/<game>/` (`res://`): Odin in `simulation/` (the sim, its headless binary, its
GDExtension in `extension/`, its tests), everything Godot in `game/`. What every game shares (the flow, settings,
sounds, menus, HUD panels, tool scripts) is demo-games code in `games/shared` (its SPEC.md; not the library), which
`uni` mirrors into the game's `addons/shared/` before every run: edit it there, never the copy. The view reads the sim
and never writes it; player input and commands are the only way in. Every command and its options: `./uni help`, `-h` on a command. Rules
for editing Godot files load on their own (`.claude/rules/godot.md`).

## The loop, cheapest first

Run from the repo root. `<game>` is the folder name under `games/`. Every command builds the game's extension when
it is stale and re-imports the project when an imported file changed, so there is no separate build or import step
(`./uni build <game>` builds anyway). Agents work through these cold headless Godot processes: no editor bridge, no
daemon.

`./uni test <game> --suite godot` runs these steps in order, each when the game has what it needs; `--only` picks
steps (`--only validate,walk`). Every run is strict: an `ERROR` line, a leak at exit or a GDScript warning fails it.

1. `editor`: the extension loads in a headless editor with no `ERROR` lines.
2. `session`: a headless Godot session's checksums must equal the offline binary's. Run it after a change to the
   extension, `src/godot` or anything between input and the sim.
3. `bake`: the view index (`unified_index.tres`, every scene with a UnifiedView marker by kind) and each level's
   `.level` file are current (`./uni bake <game>` writes them; every build refreshes the index too; commit both).
4. `validate` (the library's `UnifiedValidate`, `src/godot/tools`): compiles every script with warnings as errors
   (the strict typing in each `project.godot`: untyped or unsafe code is an error outside the tool scripts), loads
   and instantiates every scene, flags unknown `.tscn` properties, checks the game's own contract (friendslop: item
   sizes against the sim; drift: the view contract), fails on a `preload(` in a script the play scene loads (it
   loads on a thread: `games/shared/SPEC.md`), runs the menu for 30 frames. Run it after every GDScript or scene
   change. A `-d` run stops at the first strict error (its debugger prompt quits at once): to list them all, run the
   validate script without `-d` (`godot --headless --path games/<game> -s res://addons/unified/validate.gd --
   --no-settings --frames=5`) and read its `Parse Error` lines.
5. `walk` (`ui_walk.gd`): a headless scripted walk through the games' shared menus and flows with real input events
   (settings, pad navigation, single player, Esc menu, LAN host, a failed join); survivor adds its match flows.
6. `tour`: the real game, headless, through lobby and match (quick).

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

These need a display; they don't run in CI. **A window you start for the developer (to look at, or as a check)
opens muted on the leftmost screen and never takes focus**: they may be typing on the main screen. `tool --window`
and `coop --window` always open that way (and keep running while not frontmost); `run` needs `--mute --screen left
--background` (`--screen` also takes Godot's index, `right`, `primary`); the editor always takes focus, so open it
only when asked. On macOS Godot activates itself as its window opens and `uni` hands
the focus straight back (under half a second, twice per start); that a window there keeps running while not
frontmost is unproven (#49). `--screen left|right|primary` reads the screens from the OS in Godot's order (macOS:
CoreGraphics, checked by CI on a one-display Mac, two screens not yet confirmed, #231; Linux: `xrandr`, or pass
Godot's index).

- `./uni run <game> --mute --screen left --background` (arguments after `--` go to the game), `./uni editor <game>`.
- `./uni tool <game> <script> --window [--shots] [-- args]`: any of the game's tool scripts in a window, PNGs in
  `games/<game>/.out/shots/<script>/` with `--shots`. The walk: `tool <game> ui_walk --window --shots` (survivor:
  `-- --mock`). A whole match: `tool <game> tour --window --shots`; `-- --frames` reports frame times and first-use
  hitches, `--cold` clears the shader caches first.
- `./uni tool survivor play_check --window`: a bot plays (`-- --coop`, `-- --bench N`).
- `./uni coop <game>`: a host and a joiner process through EOS (`--lan`: direct UDP, no EOS), in every game; then
  the game's own play (survivor: a match, friendslop: the host picks the friend up, drift: the host starts a match)
  (EOS setup: `docs/EOS.md`).

Read the PNGs to check what you changed looks right.
