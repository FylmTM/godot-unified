# friendslop

A third-person co-op physics sandbox on `unified`, its example of a physics-heavy game: up to four wobbly characters
ride platforms, carry and throw things and each other, and take a trophy along a route of physics puzzles. A Godot
project (this folder is `res://`): the sim, its tests, the headless binary and the GDExtension in `simulation/`
(Odin), everything Godot in `game/`; the level is a Godot scene (`game/levels/park.tscn`). Spec:
[`SPEC.md`](SPEC.md). `uni run friendslop` plays it.

## Controls

WASD / left stick to move (camera-relative), mouse / right stick to look, Space / A to jump, LMB or E / RT to grab
and drop, RMB or Q / LT held to charge a throw (release throws), Esc / Start for the menu, F1 for the dev UI. Grab a
friend to carry them; mash jump to break free.
