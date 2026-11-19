---
name: godot-game
description: Building, running and checking a Godot game under examples/<game> (survivor, friendslop, drift, minimal_3d) - which step of the godot test suite proves what, the order to run them in, baking a level after editing it, driving a running game with uni drive (input, exact steps, state, screenshots, menus), and the windowed checks that need a display. Use after changing a game's GDScript, scenes, levels, extension or view contract, or src/godot or src/gdext, when asked to run, play or look at a game, and to play-check a game you build.
---

# Working on a Godot game

An example game is a Godot project in `examples/<game>/` (`res://`): Odin in `simulation/`, everything Godot in `game/`,
the library's tool scripts mirrored into `addons/unified/` before every run. Every command builds a stale extension and
re-imports changed files first: there is no separate build or import step.

survivor, friendslop and drift each own a copy of the same app layer: `game/app/` (the `Game`, `Settings`, `Sfx` and
`LibraryCheck` autoloads), the menus and HUD panels in `game/ui/`, `game/tools/menu_tool.gd` and `ui_walk.gd`. **A
change to the app layer lands in every game in the same PR**, unless a game differs on purpose. Nothing compares
them. A new game doesn't copy it: it stays minimal_3d-shaped (no menus or settings), plays together through the
session's flags and `uni coop`, and opts into online lobbies with `eos.lobby({})` in `godot.init` and `lobbies` in its
headless main (`examples/minimal_3d/README.md`, What a new game takes from where).

## The loop, cheapest first

`./uni test <game> --suite godot` runs these steps in order (`--only validate,walk` picks some). An `ERROR` line, a
leak at exit, a GDScript warning or a warning the game's own scripts raise (`push_warning` from `res://game/`) fails
a step.

- `import`, `editor`: the project imports and the extension loads in a headless editor.
- `session`: a headless Godot session's checksums equal the offline binary's. After a change to the extension,
  `src/godot` or anything between input and the sim.
- `bake`: the view index and every `.level` file are current.
- `validate`: every script compiles with warnings as errors, every scene loads, and the game's own contract holds
  (`game/tools/validate.gd`, where a game has one). After every GDScript or scene change. It stops at the first strict error; to list them
  all, run `godot --headless --path examples/<game> -s res://addons/unified/validate.gd -- --no-settings --frames=5`
  and read its `Parse Error` lines.
- `walk`: a scripted walk through the menus and flows with real input events, and the game's own play smoke
  (`_walk_play()` in its `game/tools/ui_walk.gd`).
- `drive`: the game headless under `uni drive`, as an agent drives it (pause, exact steps, a timed press, state,
  events, ui, eval), stopped with a clean log. After a change to the control socket or what it reads.
- `uni tool <game> tour` (not a suite step): the real game through a whole match, by hand or with `--frames`.

Before handing back any Godot-side change: `./uni test --suite godot,godot-bindings` (every game, plus the binding
and host-view tests: what CI's Godot job runs).

## Levels

A level is a Godot scene baked to the `.level` file the sim loads, committed beside it (`src/level/README.md`): a new
one goes in `game/levels/`; one kept elsewhere is found by its `.level`. After
editing a level scene or its markers, run `./uni bake <game>` and commit the `.tscn` and the `.level` together.

## Driving a running game

`./uni drive` plays a running game from outside, the way a person does: start it, give it input, look at it, check
what it computed. Use it to play and check a game you build or change, beside its tests. `./uni drive -h` lists the
verbs; each prints the game's JSON reply and exits 1 when the reply says `ok: false`.

```
./uni drive <game> start -- --autostart   # a window (muted, leftmost, no focus); --headless: none; prints status
./uni drive <game> pause                  # single player: the clock stops; nothing moves until step or resume
./uni drive <game> press move_right 30    # hold an Input Map action for 30 ticks (paused: steps exactly 30)
./uni drive <game> state players.data     # the newest State as JSON, or the part a path names
./uni drive <game> events                 # event states since the last `events`
./uni drive <game> shot                   # a PNG of the window; read it to see what the player sees
./uni drive <game> ui                     # the visible buttons and texts; `click "Single player"` presses one
./uni drive <game> stop                   # quit, and judge its log as a tool run (errors, leaks: exit 1)
```

- **Paused is exact.** `pause`, then `press <action> <n>` or `press` + `step <n>` + `release`: every tick is
  accounted for, so a check can say where a thing must be after n ticks. A running session moves between verbs.
- **The game decides how a session starts**: `-- --autostart` (single player at once), the session flags (`--host-port`,
  `--join`), or its menus through `click`.
- **Several at once.** `start --name host -- --host-port 7000` and `start --name joiner -- --join 127.0.0.1:7000`,
  then `--name` on every verb (needed only while more than one runs). Instances are under
  `examples/<game>/.out/drive/`, with each one's Godot log.
- **Changes.** An instance runs the code it started with: after an Odin or GDScript change, `stop` and `start` again
  (`start` builds a stale extension first).
- `command <name> key=value ...` sends a game command (`Cmd_Dev_*` too: cheats); `eval <expression>` reads anything
  else (`scene`, `session`, `Input`, `Engine.get_singleton("Unified")`).

## Looking at it

These need a display and don't run in CI. Every window follows AGENTS.md's window rule.

- `./uni run <game>`: play it (arguments after `--` go to the game).
- `./uni tool <game> <script> --window --shots`: a tool script (`ui_walk`, `tour`) in a window, PNGs in
  `examples/<game>/.out/shots/<script>/`. `tour -- --frames` reports frame times and first-use hitches.
- `./uni coop <game>`: a host and a joiner process through EOS (`--lan`: direct UDP), then the game's own play.

Read the PNGs to check that what you changed looks right.
