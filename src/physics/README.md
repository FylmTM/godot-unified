# `unified:physics`: Box3D for games, characters, kinematic paths

Box3D as `sim` rollback state, its whole API addressed by references from the state block, plus what every co-op
physics game needs: creation helpers, a character controller, kinematic paths, static level geometry and a 2D plane.
Deterministic: f32, `+ − × ÷ sqrt`, no trig, float-to-int through `dmath`, state in the block or the Box3D world.

It uses `sim` (the harness it plugs into), `dmath` and `level` (static geometry); a physics game's sim package uses
it, and reaches Box3D through nothing else.

## The plug-in

A game's World holds one physics `World` (one Box3D world); its `sim.Game.extra` returns `physics.extra(world.phys,
State)`, which makes the Box3D world part of the rollback state:

- **Save and restore.** A save is a Box3D snapshot (a memcpy of the world's arena) and physics' body table, per ring
  slot. A restore puts back everything, contacts, warm starts and trees included, so a re-simulation continues
  bit-exactly.
- **Hash.** On `sim.DEEP_CHECKSUM_EVERY` ticks (what peers compare) the whole world's hash and the body table's; on
  the others, the awake bodies' poses and velocities, a fraction of the cost.
- **Images** (late join, desync reports) are Box3D's canonical image with its geometry, then the body table. Imaging
  a past tick puts that tick in the world for the time it takes and the live state back after. A refused load keeps
  the world as it was.

## Capacity

A rollback at the prediction cap re-steps the whole world, so physics bounds what a tick may hold: the awake bodies in
dense contact (a pile) that fit a step plus that rollback in the frame budget. `uni bench`'s physics row says how many
fit, on 1 and 4 workers (the cost per body is about flat). One worker is the default (`Settings.workers`): more take
CPU from Godot and the netcode and help only worlds several times that size, so a physics-heavy game measures before
it raises it.

Any worker count steps to the same bits, and a game proves it on its own content: its suite runs the reference run
again on the other count (`world_set_worker_count` on the World `world_create` made), in the long tier while it ships
one worker and in every run once it ships more.

## The boundary

Physics is the only package that imports Box3D's bindings (`box3d:bindings`, upstream's C API 1:1; the lint allows
them in `src/physics` and `tests/physics` only). Each Box3D proc is wrapped once: a reference instead of an id, the
physics `World` first, the same meaning. Physics invents no concepts beyond references, tags, the rollback plumbing and
the game helpers below.

- **Names**: Box3D's, mechanically, `get_` dropped (`b3Body_GetPosition` → `body_position`, `b3CreateBody` →
  `create_body`), so Box3D's docs explain a proc by its name; a plane-locked form adds `_2d`.
- **Types**: Box3D's structs mirrored in `box3d_types.odin` (its header says how), enum members without their type's
  word (`.Dynamic`, `.Capsule`, `.Revolute`).
- **Creation** takes defs by value and the references as arguments, and fills the def's ids itself (a joint's bodies
  are links, so a joint can attach to the anchor or a platform). It asserts the def's `user_data` unset: a pointer has
  no place in rollback state.
- **Debug draw** (`debug_draw`): Box3D's own draw for joints, contacts, bounds and the rest, shapes drawn by physics
  (Box3D draws a shape only through a host object it keeps in the world). It never changes what `hash`, a save or an
  image holds: a flag outside `DEBUG_DRAW_PURE` is drawn between a snapshot save and restore, and the tests hold
  every flag to it.
- **Out of scope**: profile and counters, recording (our replays), the dynamic tree, task and worker
  callbacks (`Settings.workers`), pre-solve, custom-filter, friction and restitution callbacks (code run mid-step),
  `user_data` setters, step and snapshots (the plug-in's), narrow-phase internals, `World_EnableSpeculative` (never
  read), demo geometry (`CreateRock`, `CreateComplexHull`, wave and torus meshes), `ComputeCosSin` (ours is `dmath`).

## References

The block names what it owns, and links to what it doesn't:

- A `Body_Ref` is a body the block **owns**: Box3D's id without the world index, so blocks match across worlds and
  machines. Indices come from creation order, so a game creates its bodies in a fixed order.
- A `Body_Link` (same bits) is a body owned elsewhere (a platform stood on, a held item, a query's hit), maybe stale:
  `resolve` gives a ref to use **now**, never to keep; `link` goes back.
- Joints have a typed ref per Box3D joint type, so a setter of another type does not compile; each is a `Joint_Ref`,
  which the generic `joint_*` procs take.
- **No body is an orphan.** Bodies made before `extra` (the anchor, level geometry, platforms made in
  `world_create`) are the World's; every later one must be owned by a `Body_Ref` in the block. `check_refs`, the
  Extra's check after every restore in sync-tests, fails on an orphan or a ref to something dead. Freeing an entity's
  physics is `destroy_refs` on its value, or `despawn` for a table item.

## Entity tags

Each body carries a **tag**, a u64 the game chooses (`sim.handle_key(handle)`, `sim.player_key(player)`), set at
creation. Every result and event carries the tag of the body hit and the category bits of the shape hit, so a game
knows what it hit without decoding anything. Tags are physics' table by body index: rolled back, imaged and
deep-hashed with the world.

## Creating bodies

`body_def`, `shape_def`, `create_box` / `create_sphere` / `create_capsule`, the `*_density` procs and `body_teleport`
are what every game repeats; Box3D's own creation procs stay beside them for full control.

## What physics covers

**Full Box3D coverage**: every Box3D proc of its world, query, event, body, shape, geometry and joint groups is
wrapped, except Out of scope (and a world setter until a test shows it rolls back). Geometry is host-side, outside
the block (`geometry.odin`'s header): a game keeps a mesh, height field or compound alive as long as the world.

## Results

- **Deterministic order.** Collected results are sorted (casts by fraction, then body and shape index; the rest by
  body and shape index); events come in Box3D's order, which is world state.
- **Collecting procs replace `out`'s contents.** A game keeps the array in its World as scratch, and a forgotten
  `clear` can't carry a result into another tick.
- Casts take an origin and a translation (the whole length).
- Events are read in the tick that stepped; a re-simulation regenerates them.

## Character

A dynamic character controller, ported from Box3D's dynamic mover sample, since every game with walking players
needs one: its state is a `Character` in the block, its tuning a `Character_Def` in game code. `character.odin`'s
header says how it works.

## Kinematic paths

A moving platform's pose is a pure function of its phase tick (`path_sample`), so a game keeps only that tick in its
block and the `Path` in its level data; `drive_kinematic` makes the body follow it without drift.

## Static level geometry

A game's level is its World's first bodies: `create_with_level` (or `create_static`) in `world_create`, before
`extra`, so they are the World's. A shape Box3D refuses is never a silent hole: `problem` names it, and the games
assert on it. Every shape carries its level surface (friction, restitution, rolling resistance, a conveyor's tangent
velocity and the material id a ray or contact reports); a mesh's triangles may each name another. Meshes and height
fields are built once, kept by the physics `World` and freed after the Box3D world, since their shapes point at
them; a height field takes no local transform, so it is a static body of its own at its level body's pose.

## 2D

2D bodies are Box3D bodies locked to a plane: the same world, refs, rollback and queries. The plane is XY with Godot's
2D axes (x right, y down), bodies at z = 0. A rotation is about +Z, +x toward +y (Godot's `Node2D.rotation`), held as
a unit vector `(cos a, sin a)`, so no trig. Gravity is the world's (zero for top-down).

The body's pose, velocities, forces and impulses, the shape and body creation procs and the closest ray have a `_2d`
form; the rest (mass, tags, sleep, local and world point conversions, the other queries) take 3D values at z = 0.
The plane holds exactly: z, the quaternion's x and y, v.z, ω.x and ω.y stay ±0 (Box3D and unified-box3d zero them).

## Known limits

- **Box3D generations are u16, reused last-in-first-out**: after 65,536 reuses of an index a stale link is live again.
- **Host geometry only grows while a world lives** (the hull database is append-only, for rollbacks).
