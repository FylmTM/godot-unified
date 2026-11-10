# Survivor

The co-op survivor prototype on `unified`: a Godot 4.7 project (this folder is `res://`). The deterministic sim and
the GDExtension live in `simulation/` (Odin); everything Godot is in `game/`. Spec (the sim, then the
client): [`SPEC.md`](SPEC.md).

## Run

Open this folder with Godot 4.7.2 (standard build), or from the repo root:

```
godot --path games/survivor                  # the game; uses the game library if built, else the mock session
godot --path games/survivor -- --mock        # force the GDScript mock session
```

The game library is built into `.out/bin/` (`libsurvivor.dylib`, `survivor.dll`); without it a dev run uses the
mock session (`game/session/`), a fake sim with the same API, so every screen works. Exports never include the
mock: without the library they show a "game library failed to load" screen.

## Checks

`python tools/dev.py godot-checks` runs every Godot check for every game, and `dev.py test` runs this game's end-to-end
suite. Which check proves what, and the order to run them in: the `godot-game` skill (`.claude/skills/`).

## Controls

WASD / arrows / left stick to move, Space / pad A to dash, 1 2 3 / pad X Y B to pick a level-up, Esc / Start for
the menu, F1 for the dev UI. Settings (volumes, window mode, V-Sync, 3D resolution, FPS counter, player name) are
saved to `user://settings.cfg`.
