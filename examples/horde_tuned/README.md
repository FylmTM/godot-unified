# horde_tuned: the horde done well with nodes

[examples/horde](../horde/)'s game (its sim, shared) drawn the way a Godot developer who knows the engine would:
the crowds (enemies, their HP bars, bolts, gems) are MultiMesh views whose instances the host writes in one buffer per
frame and whose look is a shader each (`game/multi/`); the few (heroes, bombs, blasts) are scene views; sparks and
damage numbers are ring buffers of MultiMesh instances that the shader animates from their birth, so GDScript touches
one once, when an event makes it (`game/fx/`); lightning arcs are one node drawing every live arc. The HUD is
horde's (`game/ui/hud.gd`). Part of the render experiment: horde's README says what each example compares.

## View contract (`simulation/extension`)

- Scene views: `View_Hero`, `View_Bomb` (its flight's progress), `View_Blast` (its radius in pixels and progress).
- MultiMesh views: `Enemy` (custom: kind, hit flash, HP share, radius; rotation: heading; scale: its size), `Bar`
  (a damaged enemy's HP share), `Bolt` (custom: the shooter's slot), `Gem` (custom: value, bob phase).
- Session data: `Data_Hud`.
