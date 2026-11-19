---
name: godot-game
description: Building, running and checking a unified game in Godot - which step of the godot test suite proves what and the order to run them in, baking a level after editing it, driving a running game with uni drive (input, exact steps, state, screenshots, menus), and the windowed checks that need a display. Use after changing a game's GDScript, scenes, levels, extension or view contract, when asked to run, play or look at a game, and to play-check a game you build.
---

# Working on a Godot game

A game is a Godot project (`res://`): its Odin in `simulation/`, everything Godot in `game/`, unified's tool scripts
mirrored into `addons/unified/` before every run. In a game repo the game is the repo's root and unified is the
`unified/` submodule (library paths below are unified's: `unified/src/...` there); inside unified the games are
`examples/<game>/`. Commands take the game's name, optional where there is one game. Every command builds a stale
extension and re-imports changed files first: there is no separate build or import step.

## The loop, cheapest first

`./uni test <game> --suite godot` runs these steps in order (`--only validate,walk` picks some; `uni test -h` says
what each checks). An `ERROR` line, a leak at exit, a GDScript warning or a warning the game's own scripts raise
(`push_warning` from `res://game/`) fails a step.

- `import`, `editor`: the project imports and the extension loads in a headless editor.
- `session`: a headless Godot session's checksums equal the offline binary's. After a change to the extension or
  anything between input and the sim.
- `bake`: the view index and every `.level` file are current.
- `validate`: every script compiles with warnings as errors, every scene loads, and the game's own contract holds
  (`game/tools/validate.gd`, where a game has one). After every GDScript or scene change. It stops at the first
  strict error; to list them all, run `godot --headless --path <the game's directory> -s
  res://addons/unified/validate.gd -- --no-settings --frames=5` and read its `Parse Error` lines.
- `walk`: a scripted walk through the menus and flows with real input events, and the game's own play smoke
  (`_walk_play()` in its `game/tools/ui_walk.gd`; a game without menus has none).
- `drive`: the game headless under `uni drive`, as an agent drives it (pause, exact steps, a timed press, state,
  events, ui, eval), stopped with a clean log.
- A game's own tool scripts (`uni tool <game> <script>`, e.g. a `tour` through a whole match) are not suite steps.

Before handing back any Godot-side change: the whole godot suite, then `./uni verify`.

## Levels

A level is a Godot scene baked to the `.level` file the sim loads, committed beside it (`src/level/README.md`): a new
one goes in `game/levels/`; one kept elsewhere is found by its `.level`. After editing a level scene or its markers,
run `./uni bake <game>` and commit the `.tscn` and the `.level` together.

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
- **The game decides how a session starts**: `-- --autostart` (single player at once), the session flags
  (`--host-port`, `--join`), or its menus through `click`.
- **Several at once.** `start --name host -- --host-port 7000` and `start --name joiner -- --join 127.0.0.1:7000`,
  then `--name` on every verb (needed only while more than one runs). Instances are under the game's
  `.out/drive/`, with each one's Godot log.
- **Changes.** An instance runs the code it started with: after an Odin or GDScript change, `stop` and `start` again
  (`start` builds a stale extension first).
- `command <name> key=value ...` sends a game command (`Cmd_Dev_*` too: cheats); `eval <expression>` reads anything
  else (`scene`, `session`, `Input`, `Engine.get_singleton("Unified")`).

## Looking at it

These need a display and don't run in CI. A window an agent opens never disturbs the developer: it starts muted on
the leftmost screen and never takes focus (`tool --window`, `coop --window` and `drive start` always do; `run` takes
`--mute --screen left --background`). The editor always takes focus: open it only when asked.

- `./uni run <game>`: play it (arguments after `--` go to the game).
- `./uni tool <game> <script> --window --shots`: a tool script in a window, PNGs in the game's
  `.out/shots/<script>/`. A `tour -- --frames` reports frame times and first-use hitches.
- `./uni coop <game>`: a host and a joiner process through EOS (`--lan`: direct UDP), then the game's own play.

Read the PNGs to check that what you changed looks right.
