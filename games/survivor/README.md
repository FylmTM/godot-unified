# Survivor

The co-op survivor prototype on `unified`: a Godot project (this folder is `res://`). The deterministic sim and
the GDExtension live in `simulation/` (Odin); everything Godot is in `game/`. Spec (the sim, then the
client): [`SPEC.md`](SPEC.md).

## Run

Open this folder with the pinned Godot (`pins.cfg`, standard build), or from the repo root:

```
uni run survivor                  # the game; builds the game library first
```

The game library is built into `.out/bin/` (`libsurvivor.dylib`, `survivor.dll`; `uni build survivor`); nothing
runs without it: a checkout that never built it, or an export that lost it, shows a "game library failed to load"
screen.

## Checks

`uni test --suite godot` runs every Godot check for every game, and `uni test` runs this game's end-to-end suite.
Which check proves what, and the order to run them in: the `godot-game` skill (`.claude/skills/`).

## Controls

WASD / arrows / left stick to move, Space / pad A to dash, 1 2 3 / pad X Y B to pick a level-up, Esc / Start for
the menu, F1 for the dev UI. Settings (volumes, window mode, V-Sync, 3D resolution, FPS counter, player name) are
saved to `user://settings.cfg`.
