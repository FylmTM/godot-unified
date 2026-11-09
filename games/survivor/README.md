# Survivor

The co-op survivor prototype on `unified`: a Godot 4.7 project (this folder is `res://`). The deterministic sim and
the GDExtension live in `simulation/` (Odin); everything Godot is in `game/` (spec: `spec/survivor-client.md`,
sim: `spec/GAME.md`).

## Run

Open this folder with Godot 4.7.2 (standard build), or from the repo root:

```
godot --path games/survivor                  # the game; uses the game library if built, else the mock session
godot --path games/survivor -- --mock        # force the GDScript mock session
```

The game library is built into `.uni/bin/` (`libsurvivor.dylib`, `survivor.dll`); without it a dev run uses the
mock session (`game/session/`), a fake sim with the same API, so every screen works. Exports never include the
mock: without the library they show a "game library failed to load" screen.

## Checks (from the repo root)

```
python tools/dev.py game validate   # compile scripts (warnings fail), load scenes, unknown .tscn properties, mock vs
                                    # native constants(), 30 menu frames (~0.6 s)
python tools/dev.py game walk       # headless UI walk with the mock: menu, settings, single, lobby, match,
                                    # level-up, Esc menu, game over, host, join error (~2.5 s)
python tools/dev.py game shots      # the walk in a window; PNGs in games/survivor/.uni/shots/ (steals focus)
python tools/dev.py game build survivor   # the game library -> .uni/bin/
python tools/dev.py game tour       # the real game, headless: menu -> lobby -> match (~2.6 s); --shots: a whole
                                    # match in a window, PNGs in games/survivor/.uni/tour/
```

## Controls

WASD / arrows / left stick to move, Space / pad A to dash, 1 2 3 / pad X Y B to pick a level-up, Esc / Start for
the menu, F1 for the dev UI. Settings (volumes, window mode, V-Sync, 3D resolution, FPS counter, player name) are
saved to `user://settings.cfg`.
