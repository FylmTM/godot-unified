# `unified:level`: Godot-authored levels for the sim

A level is authored as a Godot scene, exported to a small binary file (`uni bake`), and loaded by the sim when its
World is created. The scene is also the view: its meshes render as they are, its markers hide themselves. It imports
only `unified:wire`; `unified:physics` builds a level's static bodies (`physics.create_static`), and the
Godot host finds a marker's node by its index (`Unified.level_markers`).

## Authoring

- **Geometry:** Godot's `StaticBody3D` + `CollisionShape3D` (box, sphere, capsule, convex polygon). Uniform scale only
  for spheres and capsules; any scale is baked into boxes and hulls. Friction and restitution come from the body's
  `PhysicsMaterial`, the filter category and user material from its metadata (`unified_category`,
  `unified_material`).
- **Markers:** any node whose script has `const UNIFIED_KIND := "platform"` (a script for several kinds: a
  `unified_kind` property; a node without a script: metadata `unified_kind`), in the game's own vocabulary. The
  exporter writes the kind, the node's name and transform, every exported script property (bool, int, float, Vector3,
  String, a NodePath to another marker), and the points of a `Path3D` child. Every exported property is written,
  defaults included, so the marker script is a property's one home: the sim reads it without a default of its own
  (a `prop_*` default only covers a marker whose script lacks the property) and asserts what its rule needs. Markers
  are in scene-tree order (depth-first, parents first); at run time `Unified.level_markers(level_root)` returns the
  nodes in that order.

The exporter is unified's (`src/godot/tools/level_export.gd`, mirrored into every project as `addons/unified/`);
scenes depend on no library script.

## 2D levels

A level whose root is a `Node2D`. The sim's plane is XY with Godot's 2D axes at z = 0 (`src/physics/README.md`, 2D).
Pixels are divided by the game's `Glue.view_scale` (a fixture baked without a game sets the root's metadata
`unified_px_per_m`; both, disagreeing, is an error); shapes are extruded to ±`unified_depth_m` / 2 (default 1 m).

| Godot | File |
|---|---|
| `StaticBody2D` | a body: position, rotation about Z; scale (and skew, mirroring) baked into its shapes |
| `CollisionShape2D` rectangle / circle / capsule | Box (half depth/2 in z) / Sphere / Capsule along local Y (uniform scale for the last two) |
| convex polygon | Hull: the points at z = ±depth/2 (3 to 32 points) |
| `CollisionPolygon2D` (solids) | convex parts (`Geometry2D.decompose_polygon_in_convex`), a Hull each |
| `TileMapLayer` with collision | one body; per used cell, sorted by (y, x), physics layer 0's polygons (with the cell's flip/transpose), convex Hulls; material from the layer |
| marker (`Node2D`) | position, rotation about Z, scale (sx, sy, 1); a `Path2D` child's points in metres; a Vector2 property raw, z = 0 (`prop_vec2`) |

Export errors name the node: segment, world boundary, concave and separation ray shapes, a polygon in segments mode,
one-way collision, scene tiles, a 3D body or marker in a 2D level (and the reverse).

## File (`UNLV`)

Little-endian through `unified:wire`; the layout is in `level.odin`'s header. Bodies and markers are both in
scene-tree order. Transforms are f32 as Godot computed them at export: the bits are committed, so the sim sees the
same ones everywhere. The exporter uses no trig of its own (a 2D rotation's quaternion comes from the transform's x
axis with + − × ÷ sqrt in doubles), so the staleness check gives the same bytes on every platform.

## A level's identity

A level's identity is `sim.content_hash(bytes)`: the log, the snapshot and the netcode's compat carry it, so a replay
or a peer with another level is refused (`src/sim/README.md`). A game embeds the level it ships with once,
`sim.Game.content = #load(...)`, which every host, run and suite plays; a headless run can take another file
(`uni help`). A game's World gets the bytes from `world_create(seed, content)` and loads them there
(`physics.create_with_level` for a physics game).

## Baking

The exported file is committed next to its scene (headless runs and CI need no Godot). `uni bake` writes it and
checks that it is current (`uni help`). A game's level scenes are those in `game/levels/` (not its subfolders: they
hold the parts a level instances), where a new one goes, and any other scene with its `.level` beside it, wherever
the game keeps it.
