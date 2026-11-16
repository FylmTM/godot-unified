# drift

The 2D test game on `unified` (spec: [`SPEC.md`](SPEC.md)): a top-down co-op ship arena, a Godot project (this
folder is `res://`). It exists to exercise unified's 2D host features in a real game. The deterministic sim, its
headless binary and the GDExtension live in `simulation/` (Odin); everything Godot is in `game/`. The level is a
Godot 2D scene (`game/levels/arena.tscn`), exported to a `.level` file the sim loads (`src/level/SPEC.md`).

## Run

```
uni build drift     # the game library -> .out/bin/; the game needs it
uni run drift       # windowed
```

There is no GDScript mock session: without the library the game says how to build it.

## How the view is built

The view contract is `simulation/extension/extension.odin`; the Godot side follows it:

- Scene views (`game/views/`): `ship.tscn`, `gate.tscn` and `station.tscn` are Node2D roots with a UnifiedView
  marker (`uni bake drift` indexes them). Each is drawn in code at the sim's sizes (`Unified.constants`, metres)
  times the level's `unified_px_per_m`; the typed view data (`boost_ready`, `thrust`, `hp_frac`, `charge`) arrive as
  properties. The HUD (`game/ui/hud.gd`) reads the session data `Unified.data.hud`.
- MultiMesh views (`game/multi/`, in `game/arena/arena.tscn`): rocks (`rock_0..rock_3`, one mesh per shape variant,
  the sim's own hull), bullets and gems are MultiMeshInstance2D nodes, each with a UnifiedMultiView marker. All use
  `TRANSFORM_2D` MultiMeshes with colours and custom data, read by small shaders (`game/shaders/`).
- `game/arena/arena.gd` sets the aim every frame before the session samples input (the input value `aim`): the
  mouse's world position relative to the local ship (once the mouse moves), else the right stick. The camera
  (`follow_camera.gd`) follows the local ship within the level's bounds. Sim events (typed classes, positions in
  pixels) drive effects and sounds.
- The HUD's lobby prompt sends the `start` command (Enter / X, or the Start button); when the match is over,
  `restart`.

## Levels

`game/levels/arena.tscn` is the level and the arena's art. Walls and obstacles are Godot's own `StaticBody2D` +
`CollisionShape2D` / `CollisionPolygon2D` with a `Polygon2D` for the look; sim objects are marker nodes
(`game/levels/markers/`: `spawn`, `station`, `gate` with its `pair`, `rock_spawn` with its `dir`). After editing it:

```
uni bake drift   # game/levels/*.tscn -> *.level (commit both); the godot suite checks it
```

## Checks

`uni test --suite godot` runs every Godot check for every game, and `uni test` runs this game's end-to-end suite.
Which check proves what, and the order to run them in: the `godot-game` skill (`.claude/skills/`).

## Controls

WASD / left stick to thrust (world directions), mouse / right stick to aim, LMB or Space / RT to fire, RMB or
Shift / LT or A to boost, Enter / X to start (and to restart when the station is lost), Esc / Start for the menu,
F1 for the dev UI.
