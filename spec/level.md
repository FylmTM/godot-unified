# `unified:level`: Godot-authored levels for the sim

Signed off by the developer 2026-11-09. A level is authored as a Godot scene, exported to a small binary
file, and loaded by the sim at runtime. First user: `spec/friendslop.md`.

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
`.uni/tools/` and run it there.

## File (`UNLV`, little-endian, through `unified:wire`)

Header: magic, version u16, record counts. Then static bodies (transform, shapes with local transforms and
materials) in scene-tree order, a string table, and markers (kind, name, transform, properties, path points) in
scene-tree order. Transforms are f32 position + quaternion, taken as Godot computed them at export: the export
runs once on one machine and the bits are committed, so they are the same everywhere.

## API

```odin
level.load(bytes) -> (Level, ok)         // parses into one allocation; Level holds slices into it
level.hash(bytes) -> u64                 // XXH3 of the file: the level's identity
level.markers(&lvl, "platform") -> []Marker
level.prop_f32(&m, "speed", default), prop_int, prop_bool, prop_vec3, prop_string, prop_ref, path_points(&m)
physics.create_static(w, &lvl)           // static bodies in file order
```

## Getting the level to the sim (runtime-loaded)

- `sim.Game.world_create(seed, content: []u8)`: the harness passes the level bytes through (a sim API change; the
  survivor ignores them). `sim.create(&GAME, seed, content)`.
- The level's hash goes everywhere identity matters: the input log (`UNIL` v3) and portable snapshot (`UNIS` v3)
  headers, so `replay` and `resume` refuse a different level and say which; and the netcode's `compat`
  (`build ⊕ level hash`), so joining a host with another level fails with "different level".
- Godot: the extension reads `res://game/levels/<name>.level` and starts the session with it; joiners load the same
  file. Sending the level to joiners (user levels) is later.
- Headless: `--level FILE`. Embedding is an option per game: `DEFAULT_LEVEL :: #load(...)` as the fallback when no
  file is given, so tests and headless runs need no path while the runtime file still wins. Recommended for the
  headless binary and tests; the Godot build always loads the file.
- The exported file is committed next to its scene (CI and headless runs need no Godot). `dev.py game
  export-level <game>` (headless Godot, ~1 s) writes it; `game validate` re-exports in memory and fails if the
  committed file is stale.

## Tests

`tests/level`: round-trip of every record and property type; rejects bad magic, versions and truncated files;
`create_static` builds the expected bodies. `tests/godot`: export a fixture scene and compare to a committed file.
A replay or resume with a different level fails with the level hash in the error.

## Open

More than one level per session (a hub and separate route scenes) and level streaming; per-marker validation
schemas; sending levels to joiners.
