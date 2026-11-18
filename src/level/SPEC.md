# `unified:level`: Godot-authored levels for the sim

Status: signed off 2026-11-18 (#332)

A level is authored as a Godot scene, exported to a small binary file (`uni bake`), and loaded by the sim when its
World is created. The scene is also the view: its meshes render as they are, its markers hide themselves.

## Authoring

- **Geometry:** Godot's `StaticBody3D` + `CollisionShape3D` (box, sphere, capsule, convex polygon). Uniform scale only
  for spheres and capsules; any scale is baked into boxes and hulls. Friction and restitution come from the body's
  `PhysicsMaterial`, the filter category and user material from its metadata (`unified_category`,
  `unified_material`).
- **Markers:** any node whose script has `const UNIFIED_KIND := "platform"` (or metadata `unified_kind`), in the
  game's own vocabulary. The exporter writes the kind, the node's name and transform, every exported script property
  (bool, int, float, Vector3, String, a NodePath to another marker), and the points of a `Path3D` child.

The exporter is unified's (`src/godot/tools/level_export.gd`, mirrored into every project as `addons/unified/`);
scenes depend on no library script.

## 2D levels

A level whose root is a `Node2D`. The sim's plane is XY with Godot's 2D axes at z = 0 (`src/physics/SPEC.md`, 2D).
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
one-way collision, scene tiles, a 3D body or marker in a 2D level (and the reverse). `Level.px_per_m` records the
scale the level was baked at (0: a 3D level).

## File (`UNLV`)

Little-endian through `unified:wire`; the layout is in `level.odin`'s header. Static bodies (transform, shapes with
local transforms and materials) and markers (kind, name, transform, properties, path points), both in scene-tree
order, with a string table. Transforms are f32 as Godot computed them at export: the bits are committed, so the sim
sees the same ones everywhere. The exporter uses no trig of its own (a 2D rotation's quaternion comes from the
transform's x axis with + − × ÷ sqrt in doubles), so the staleness check gives the same bytes on every platform.
Readers accept only the current version.

## API

```odin
level.load(bytes, allocator := context.allocator) -> (Level, ok) // strings are views into `bytes`
level.destroy(&lvl)                           // frees what load allocated, with load's allocator (not the bytes)
lvl.bodies, lvl.markers, lvl.px_per_m         // file order; a 2D level's pixels per metre (0: 3D)
level.find_named(&lvl, "start") -> ^Marker    // nil: none
m.path                                        // a Path3D/Path2D child's points, world space (empty: none)
m.props: []Prop                               // Prop{key, value: union {bool, i32, f32, [3]f32, string, Marker_Ref}}
level.prop_f32(&m, "speed", default), prop_int, prop_bool, prop_vec3, prop_vec2, prop_string // default: missing or another type
level.prop_ref(&m, "target") -> int           // a NodePath to another marker: its index (-1: none)
```

`physics.create_static` builds a level's static bodies (`src/physics/SPEC.md`). A level's identity is
`sim.content_hash(bytes)`: the log, the snapshot and the netcode's compat carry it, so a replay or a peer with another
level is refused (`src/sim/SPEC.md`). A game's World gets the bytes from `world_create(seed, content)`; Godot reads
`Glue.level`'s file, headless takes a level file or embeds a default (`#load`).

## Baking

The exported file is committed next to its scene (headless runs and CI need no Godot). `uni bake` writes it and
checks that it is current (`uni help`).
