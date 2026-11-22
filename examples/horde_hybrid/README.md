# horde_hybrid: the world in Odin, the HUD in GDScript

[examples/horde](../horde/)'s game (its sim, shared) with the world drawn in Odin, immediate mode
(`src/godot/immediate.odin`, experimental): every frame `draw` reads the shown State and the tick before it
(`godot.Draw`) and draws into layers and quad batches on Godot's RenderingServer. There are no views: an enemy is a
quad in a batch drawn by `shaders/enemy.gdshader`, placed between its two ticks by its table index and generation. The
effects are the view's own Odin state (`fx.odin`), made by events that arrive as the game's union (`Glue.event`),
with no GDScript object per event (`Glue.no_script_events`). The HUD stays GDScript Controls on `Data_Hud` (the
match-over banner from the phase, since no script gets events). Part of the render experiment: horde's README says
what each example compares.

What a reader could get wrong:

- **Corrections snap.** A view's pose glides after a rollback; here a mispredicted position is drawn as the
  corrected one at once. A game that wants the glide keeps it in its own draw state.
- **Interpolation is the draw's.** `Draw.alpha` places the screen between `prev` and `state`; a thing new this tick
  (no match by index and generation in `prev`) is drawn where it is.
- **The shaders are files in `simulation/extension/shaders/`, loaded into the binary** (`#load`): `simulation/` is
  hidden from Godot (`.gdignore`).
