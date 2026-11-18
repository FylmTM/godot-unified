# drift

A top-down co-op ship arena on `unified`, its example of a 2D game: up to four players defend a turning station from
rocks that split, with warp gates and gems. A Godot project (this folder is `res://`): the sim, its tests, the
headless binary and the GDExtension in `simulation/` (Odin), everything Godot in `game/`. Spec: [`SPEC.md`](SPEC.md).
`uni run drift` plays it.

## Controls

WASD / left stick to thrust (world directions), mouse / right stick to aim, LMB or Space / RT to fire, RMB or Shift /
LT or A to boost, Enter / X to start (and to restart when the station is lost), Esc / Start for the menu, F1 for the
dev UI.
