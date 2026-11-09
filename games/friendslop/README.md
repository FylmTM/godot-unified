# friendslop

The co-op physics sandbox on `unified` (spec: [`SPEC.md`](SPEC.md)): a Godot 4.7 project (this folder is `res://`).
The deterministic sim, its headless binary and the GDExtension live in `simulation/` (Odin); everything Godot is in
`game/`. Levels are Godot scenes (`game/levels/`), exported to `.level` files the sim loads (`src/level/SPEC.md`).

## Run

```
python tools/dev.py game build friendslop     # the game library -> .out/bin/ (~1 s); the game needs it
python tools/dev.py game run friendslop       # windowed
```

There is no GDScript mock session: without the library the game says how to build it.

## Levels

`game/levels/park.tscn` (instancing `parts/hub.tscn`) is the level. Geometry is Godot's own `StaticBody3D` +
`CollisionShape3D`; sim objects are marker nodes (`game/levels/markers/`: `item.gd`, `platform.gd` with a `Path3D`
child, `volumes.gd` for pads, plates, bells, switches, bumpers, checkpoints, start, finish and spawns). At runtime
each sim view adopts its marker's visuals, so a level is authored once. After editing a level:

```
python tools/dev.py game export-level friendslop   # game/levels/*.tscn -> *.level (commit both); validate checks it
```

## Checks (from the repo root)

```
python tools/dev.py game validate friendslop   # scripts, scenes, item sizes vs the sim, the level export (~1 s)
python tools/dev.py game tour friendslop       # the real game headless: hub, grab, throw (~5 s); --shots: windowed
                                               # with the jump pad, PNGs in .out/tour/
python tools/dev.py game headless friendslop   # a Godot session's checksums == the offline binary's
python tools/dev.py game coop friendslop       # EOS: a host and a joiner; the host picks the friend up, they break free
odin test games/friendslop/simulation/tests -collection:unified=src   # its end-to-end suite (suite_test.odin: sessions
                                               # under loss, late join, the reference run) and scenarios
```

## Controls

WASD / left stick to move (camera-relative), mouse / right stick to look, Space / A to jump, LMB or E / RT to grab
and drop, RMB or Q / LT held to charge a throw (release throws), Esc / Start for the menu, F1 for the dev UI. Grab a
friend to carry them; mash jump to break free.
