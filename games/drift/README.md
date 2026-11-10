# drift

The 2D test game on `unified` (spec: [`SPEC.md`](SPEC.md)): a top-down co-op ship arena, a Godot 4.7 project (this
folder is `res://`). It exists to exercise unified's 2D host features in a real game. The deterministic sim, its
headless binary and the GDExtension live in `simulation/` (Odin); everything Godot is in `game/`. The level is a
Godot 2D scene (`game/levels/arena.tscn`), exported to a `.level` file the sim loads (`src/level/SPEC.md`).

## Run

```
python tools/dev.py game build drift     # the game library -> .out/bin/; the game needs it
python tools/dev.py game run drift       # windowed
```

There is no GDScript mock session: without the library the game says how to build it.

## How the view is built

The view contract is `simulation/extension/extension.odin`; the Godot side follows it:

- Scene views (`game/views/`): `ship.tscn` and `gate.tscn` are `SimView2D`s, `station.tscn` a plain `Node2D` (both
  paths of the host stay in use). Each is drawn in code at the sim's sizes (`Game.constants`, metres) times the
  level's `unified_px_per_m`; the typed view data (`boost_ready`, `thrust`, `hp_frac`, `charge`) arrive as
  properties.
- Bulk views (`game/bulk/`, in `game/arena/arena.tscn`): rocks (`rock_0..rock_3`, one mesh per shape variant, the
  sim's own hull) and gems are `SimBulkView2D`s; bullets are a plain `MultiMeshInstance2D` in the `sim_bulk` group.
  All use `TRANSFORM_2D` MultiMeshes with colours and custom data, read by small shaders (`game/shaders/`).
- `game/arena/arena.gd` sets the aim every frame before the session samples input: the mouse's world position
  relative to the local ship (once the mouse moves), else the right stick. The camera (`follow_camera.gd`) follows
  the local ship within the level's bounds. Sim events (`sim_event_2d`, positions in metres) drive effects and sounds.
- The HUD's lobby prompt sends the `start` command (Enter / X, or the Start button); when the match is over,
  `restart`.

## Levels

`game/levels/arena.tscn` is the level and the arena's art. Walls and obstacles are Godot's own `StaticBody2D` +
`CollisionShape2D` / `CollisionPolygon2D` with a `Polygon2D` for the look; sim objects are marker nodes
(`game/levels/markers/`: `spawn`, `station`, `gate` with its `pair`, `rock_spawn` with its `dir`). After editing it:

```
python tools/dev.py game export-level drift   # game/levels/*.tscn -> *.level (commit both); validate checks it
```

## Checks

`python tools/dev.py godot-checks` runs every Godot check for every game, and `dev.py test` runs this game's end-to-end
suite. Which check proves what, and the order to run them in: the `godot-game` skill (`.claude/skills/`).

## Controls

WASD / left stick to thrust (world directions), mouse / right stick to aim, LMB or Space / RT to fire, RMB or
Shift / LT or A to boost, Enter / X to start (and to restart when the station is lost), Esc / Start for the menu,
F1 for the dev UI.
