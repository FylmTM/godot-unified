# `unified:level`: Godot-authored levels for the sim

Signed off by the developer 2026-11-09. A level is authored as a Godot scene, exported to a small binary
file, and loaded by the sim at runtime. First user: `games/friendslop/SPEC.md`.

## Authoring

- **Geometry:** Godot's own `StaticBody3D` + `CollisionShape3D` (box, sphere, capsule, convex polygon), with the
  meshes next to them as usual. Uniform scale only for spheres and capsules; any scale is baked into boxes and hulls.
  Friction, restitution and a category come from the body's `PhysicsMaterial` and metadata.
- **Markers:** any node whose script has `const UNIFIED_KIND := "platform"` (or metadata `unified_kind`). The game
  writes its marker scripts with typed `@export` properties (its own vocabulary: platform, pad, plate, item...). The
  exporter writes the kind, the node's name and global transform, every exported script property (bool, int,
  float, Vector3, String, a NodePath as a marker index), and the points of a `Path3D` child.
- **Runtime:** the level scene is also the view. Its meshes render as-is; markers hide themselves (they're
  placeholders for sim objects, which get their own views). The camera may use the static colliders for camera
  collision (view only).

The library ships the exporter only, not scripts that scenes depend on. The tools install it into the game's
`.out/tools/` and run it there.

## 2D levels

Decided with the developer 2026-11-10 (2D levels in unified:level); mapping pending review.

A level whose root is a `Node2D` is a 2D level. The sim's plane is XY with Godot's 2D axes (x right, y down, z into
the screen) at z = 0; a rotation is about +Z (positive turns +x toward +y, as `Node2D.rotation`). Pixels are divided
by the root's metadata `unified_px_per_m` (default 64); shapes are extruded to ±`unified_depth_m` / 2 (default 1 m).

| Godot | File |
|---|---|
| `StaticBody2D` | a body: position, rotation about Z; scale (and skew, mirroring) baked into its shapes |
| `CollisionShape2D` rectangle | Box, half (w/2, h/2, depth/2) |
| circle | Sphere (uniform scale only) |
| capsule | Capsule along local Y, segment half = height/2 − radius (Godot's height includes the caps; uniform scale only) |
| convex polygon | Hull: the points at z = ±depth/2 (3 to 32 points) |
| `CollisionPolygon2D` (solids) | split into convex parts (`Geometry2D.decompose_polygon_in_convex`), a Hull each |
| `TileMapLayer` with collision | one body; per used cell, sorted by (y, x), each physics layer 0 polygon of its tile (with the cell's flip/transpose flags), split into convex Hulls. Friction and bounce from the tile set's physics layer 0 material; category and material from the layer's metadata |
| marker (`Node2D`) | position (z = 0), rotation about Z, scale (sx, sy, 1) as Godot's `Transform2D` decomposes it; a `Path2D` child's curve points in world metres; a Vector2 property as a Vec3 with z = 0, raw (not in metres: `prop_vec2`) |

Export errors, naming the node: segment, world boundary, concave and separation ray shapes, a polygon in segments
mode, one-way collision, scene tiles, a 3D body or marker in a 2D level (and the reverse).

The file records `px_per_m` (`Level.px_per_m`, 0 for a 3D level) so the game's view maps metres back to pixels with
the level's own number. `physics.create_static` needs nothing new: the bodies are ordinary static bodies at z = 0.

## File (`UNLV`, little-endian, through `unified:wire`)

Header: magic, version u16 (2; version 1, without px_per_m, still loads as a 3D level), px_per_m f32, record
counts. Then static bodies (transform, shapes with local transforms and
materials) in scene-tree order, a string table, and markers (kind, name, transform, properties, path points) in
scene-tree order. Transforms are f32 position + quaternion, taken as Godot computed them at export: the export
runs once on one machine and the bits are committed, so they are the same everywhere.

## API

```odin
level.load(bytes) -> (Level, ok)         // parses into one allocation; Level holds slices into it
level.hash(bytes) -> u64                 // XXH3 of the file: the level's identity
level.markers(&lvl, "platform") -> []Marker
level.prop_f32(&m, "speed", default), prop_int, prop_bool, prop_vec3, prop_vec2, prop_string, prop_ref, path_points(&m)
lvl.px_per_m                             // a 2D level's pixels per metre; 0: 3D
physics.create_static(w, &lvl)           // static bodies in file order
```

## Getting the level to the sim (runtime-loaded)

- `sim.Game.world_create(seed, content: []u8)`: the harness passes the level bytes through (a sim API change; the
  survivor ignores them). `sim.create(&GAME, seed, content)`.
- The level's hash goes everywhere identity matters: the input log (`UNIL` v3) and portable snapshot (`UNIS` v3)
  headers, so `replay` and `resume` refuse a different level and say which; and the netcode's `compat` (`sim.compat_of(game, content)`), so joining a host with another level
  fails with "a different game build or level".
- Godot: `Glue.level` names the file (`res://game/levels/<name>.level`); `UnifiedSession` reads it with
  `FileAccess` when a session starts and hands the bytes to the sim. Joiners load the same file. Sending the
  level to joiners (user levels) is later.
- Headless: `--level FILE`. Embedding is an option per game: `DEFAULT_LEVEL :: #load(...)` as the fallback when no
  file is given, so tests and headless runs need no path while the runtime file still wins. Recommended for the
  headless binary and tests; the Godot build always loads the file.
- The exported file is committed next to its scene (CI and headless runs need no Godot). `dev.py game
  export-level <game>` (headless Godot, ~1 s) writes it; `game validate` re-exports in memory and fails if the
  committed file is stale.

## Tests

`tests/level`: round-trip of every record and property type; rejects bad magic, versions and truncated files;
version 1 loads; `create_static` builds the expected bodies, also from the 2D fixture's exported file. `tests/godot`
(`dev.py godot-test`): export the 2D fixture scene (`levels/level_2d.tscn`) and compare to its committed file; an
unsupported shape fails the export with the node's name.
A replay or resume with a different level fails with the level hash in the error.

## Open

More than one level per session (a hub and separate route scenes) and level streaming; per-marker validation
schemas; sending levels to joiners.
