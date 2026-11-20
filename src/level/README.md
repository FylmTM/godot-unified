# `unified:level`: Godot-authored levels for the sim

A level is authored as a Godot scene, exported to a small binary file (`uni bake`), and loaded by the sim when its
World is created. The scene is also the view: its meshes render as they are, its markers hide themselves. It imports
`unified:wire` and `unified:dmath` (a Curve property); `unified:physics` builds a level's static bodies, its shapes
baked into compounds by cell (`physics.level_change`; src/physics/README.md, Levels), and the Godot host finds a
marker's node by its index (`Unified.level_markers`).

## Authoring

- **Geometry:** Godot's `StaticBody3D` + `CollisionShape3D` children, each shape in its body's frame:

  | Godot | File | Box3D |
  |---|---|---|
  | `BoxShape3D` | Box (scale baked in) | a hull |
  | `SphereShape3D`, `CapsuleShape3D` | Sphere, Capsule (uniform scale; a capsule's x and z) | a sphere, a capsule |
  | `ConvexPolygonShape3D` | Hull (scale baked in), at most 44 distinct points | a hull |
  | `CylinderShape3D` | Hull of 2 × 16 points from a constant table of directions | a hull |
  | `ConcavePolygonShape3D` | Mesh: body-local vertices welded where exactly equal, triangles turned counter-clockwise (Godot's front faces are clockwise) | a mesh, collided from the front |
  | `HeightMapShape3D` | Height_Field: Godot's centred one-unit grid as its corner pose and the node's scale | a height field on a static body of its own |

  Export errors name the node: a convex shape past 44 points (a hull of V points has up to 3V − 6 edges, and Box3D
  takes 128: use a simplified convex collision, a cylinder, or split it; nothing is simplified behind the author's
  back), `backface_collision`, a mirrored or flat height map, NaN heights, world boundary and separation ray shapes,
  and a `PhysicsMaterial` with `rough` or `absorbent` (Box3D mixes surfaces its own way, so they would silently mean
  nothing). Box3D splits a height map's cells along the same diagonal as Godot's physics, so the surface is the one
  the editor collides with; Godot's trimesh has no per-face data, so the exporter writes one surface per mesh shape
  though the file can hold one per triangle.
- **Surfaces:** friction and restitution from the body's `PhysicsMaterial`, the rest from its metadata:
  `unified_category` (the filter category), `unified_material` (the user material a ray or contact reports),
  `unified_rolling_resistance` and `unified_tangent_velocity` (a conveyor). The last three on a `CollisionShape3D`
  give its shape a surface of its own, the body's with those values over it.
- **Markers:** any node whose script has `const UNIFIED_KIND := "platform"` (a script for several kinds: a
  `unified_kind` property; a node without a script: metadata `unified_kind`), in the game's own vocabulary. The
  exporter writes the kind, the node's name and transform, every exported script property (bool, int, float, Vector3,
  String, a NodePath to another marker, a Curve as its samples, which the sim reads as a `dmath.Curve`), and the
  points of a `Path3D` child: its curve's control points in level space, not its baked points, with the in and out
  handles dropped (a curved road is a polyline of as many points as it needs). Every exported property is written,
  defaults included, so the marker script is a property's one home: the sim reads it without a default of its own
  (a `prop_*` default only covers a marker whose script lacks the property) and asserts what its rule needs. Markers
  are in scene-tree order (depth-first, parents first); at run time `Unified.level_markers(level_root)` returns the
  nodes in that order.

- **Navigation:** one `NavigationRegion3D` per 3D level, baked in the editor and saved with the scene. `uni bake
  --nav` does the editor's Bake button without the editor, for a region that opts in (metadata `unified_nav_bake`, so
  a hand-made bake is never overwritten) and whose NavigationMesh parses Static Colliders (the geometry the sim walks;
  the baker never changes the author's settings). The exporter writes the NavigationMesh as it was saved and never
  bakes it: the bytes are what the author committed, the same on every platform, and a stale bake stays stale until
  the author bakes again (Godot's bake depends on the geometry, so rebake after moving it). Vertices are written in
  level space, welded where exactly equal, so adjacent polygons share vertex indices and a reader matches edges by
  index, and lowered onto the static floor under them: Godot's bake floats a few tenths of a metre above it (its
  voxels' rounding and the detail mesh's extra cell, by surface), and the sim's floor is the one it collides with.
  Each polygon is turned counter-clockwise seen from above (Godot bakes them clockwise). A polygon enclosed in a solid
  static shape is left out: Godot's bake rasterizes a shape's surfaces, so a box or a tank taller than the agent leaves
  a walkable island on the floor inside it, which no walker reaches and a nearest-point query could pick. The bake's agent (radius,
  height, max climb) is written too: one region means one agent size per level, which the game sizes its walkers
  from rather than repeating it in code. Export errors name the node: a second region, a region without a saved
  bake, a polygon that isn't simple and convex (degenerate, a zero-length edge, a reflex vertex, a star), and an edge
  shared by more than two polygons. The mesh the editor draws for the region is the one the sim gets.

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
same ones everywhere. The exporter uses no trig or float code of the engine's beyond transforms (a 2D rotation's
quaternion comes from the transform's x axis with + − × ÷ sqrt in doubles, a cylinder's sides from a constant table,
a Curve's samples from its points and tangents with Godot's cubic in doubles), so the staleness check gives the same
bytes on every platform. The file names the scene it was exported from (`level.scene_of` reads it alone), so a host
can show a level's scene from its bytes. Readers take the current version only: every `.level` is committed and
re-baked with the exporter that writes it.

## A level's identity

A game embeds its levels once, `sim.Game.levels` (`src/sim/README.md`, Levels), which every host, run and suite
plays; a headless run can replace one from a file (`sim.Game.levels`). Their identity is `sim.content_hash` over
every level's name and bytes: the log, the snapshot and the netcode's compat carry it, so a replay or a peer with
other levels is refused. A game's World gets the levels from `world_create` and parses them there
(`physics.create_with_levels` for a physics game).

## Baking

The exported file is committed next to its scene (headless runs and CI need no Godot). `uni bake` writes it and
checks that it is current (`uni help`). A game's level scenes are those in `game/levels/` (not its subfolders: they
hold the parts a level instances), where a new one goes, and any other scene with its `.level` beside it, wherever
the game keeps it. A new level's sim embeds a file the bake makes, and the bake needs the game's extension, which
holds the sim: `uni bake` first writes an empty `.level` beside each level scene that has none, so the extension
builds, then bakes over it.
