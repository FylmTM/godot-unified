# `unified:physics`: Box3D for games, characters, kinematic paths

Status: draft, pending #332

Box3D as `sim` rollback state, its whole API addressed by references from the state block, plus what every co-op
physics game needs: a character controller, kinematic paths, static level geometry and a 2D plane. Deterministic: f32,
`+ − × ÷ sqrt`, fixed tables instead of trig, float-to-int through `dmath`, state in the block or the Box3D world.

## The plug-in

```odin
create(settings := Settings{}) -> ^World    // one Box3D world; mutex-guarded (Box3D's world table is global)
destroy(world)
step(world, dt, substeps)
Settings :: struct {workers: i32, gravity: Maybe([3]f32), hit_event_threshold: f32}  // zero: one thread, Box3D's defaults
extra(world, State) -> sim.Extra            // the world as rollback state (a game's sim.Game.extra returns it)
world_anchor(world) -> Body_Link            // a static body every World has (its first): joints that hold a body to the world
```

The `Extra`: saves are Box3D snapshots (a memcpy of the world's arena), one per ring slot; a restore puts back
everything (contacts, warm starts, sleep, trees), so a re-simulation continues bit-exactly. The hash is Box3D's
whole-world hash on `DEEP_CHECKSUM_EVERY` ticks, the ones peers compare; on other ticks the awake bodies' hash (id,
pose and velocities, so also which bodies are awake), a fraction of the cost. Each save, deep hash and image also
carries physics' body table (tags, below). Images are Box3D's canonical images with their geometry, then the table;
`load` puts the world back when Box3D refuses one. Worker counts give bit-identical results.

## The boundary

Physics is the only package that imports Box3D's bindings (`box3d:bindings`, upstream's C API 1:1; the lint allows
them in `src/physics` and `tests/physics` only). Each Box3D proc is wrapped once: a reference instead of an id, the
physics `World` first, the same meaning. Physics invents no concepts beyond references, tags, the rollback plumbing and
the game helpers below.

- **Names**: Box3D's, mechanically, `get_` dropped (`b3Body_GetPosition` → `body_position`, `b3CreateBody` →
  `create_body`), so Box3D's docs explain a proc by its name; a plane-locked form adds `_2d`.
- **Types** (`box3d_types.odin`): mirrors of Box3D's structs with Odin names, `[3]f32` vectors and `[4]f32` rotations
  (x, y, z, w), enum members without their type's word (`.Dynamic`, `.Capsule`, `.Revolute`) and `Filter{category,
  mask, group}`. Each has its binding's layout scalar for scalar, so a conversion is a `transmute` or a pointer cast,
  never math or a copy loop. Opaque data callers only pass around are aliases (`Hull_Data`, `Box_Hull`: `&box.base`
  is the hull). `default_*_def()` are Box3D's defaults.
- **Creation** takes the references as arguments and fills the def's ids itself (`create_revolute_joint(w, link(a),
  link(b), &def)`: links, so a joint can attach to the anchor or a platform); it asserts the def's `user_data` unset
  (a pointer has no place in rollback state). A `name` is copied into the world (hashed and imaged).
- **Conventions**: pointer and count become slices; a result with a `hit` flag is `(value, ok)`.
- **Out of scope**: debug draw, profile and counters, recording (our replays), the dynamic tree, task and worker
  callbacks (`Settings.workers`), pre-solve, custom-filter, friction and restitution callbacks (code run mid-step),
  `user_data` setters, step and snapshots (the plug-in's), narrow-phase internals, `World_EnableSpeculative` (never
  read), demo geometry (`CreateRock`, `CreateComplexHull`, wave and torus meshes), `ComputeCosSin` (ours is `dmath`).

## References

- `Body_Ref {index1, generation}`: a body the block **owns**: Box3D's id without the world index, so blocks match
  across worlds and machines. Indices come from creation order: a game creates its bodies in a fixed order.
- `Body_Link` (same bits): a body owned elsewhere (a platform stood on, a held item, a query's hit), maybe stale:
  `resolve(world, link) -> (Body_Ref, bool)` gives a ref to use **now**, never to keep; `link(ref)` goes back.
- `Shape_Ref`: a shape (`create_*_shape` returns one; results carry the shape hit). Destroyed with its body.
- **Typed joint refs**, one per Box3D joint type (`Revolute_Joint_Ref`, `Motor_Joint_Ref`, ...): a setter of another
  joint type does not compile (the release library doesn't check a joint's type). Each embeds a `Joint_Ref`
  (`using`), so the generic `joint_*` procs take any of them; an untyped one (`body_joints`' results) converts with
  `joint_as(world, ref, Revolute_Joint_Ref) -> (ref, bool)`.
- `check_refs(world, state) -> string` (the `Extra`'s check, after every restore in sync-tests): every ref in the
  block is valid, and **no body is an orphan**: bodies made before `extra()` (the anchor, level geometry) are the
  World's, every later one is owned by a `Body_Ref` in the block. "" or the first problem.

```odin
create_body(world, ^Body_Def, tag: u64 = 0) -> Body_Ref
destroy_body(world, ^Body_Ref)        // checked: a stale ref is a no-op, never another body; zeroes the ref
                                      // (Box3D's release library doesn't check ids: accessors trust refs)
destroy_joint(world, ^Joint_Ref)      // any typed joint ref, checked likewise (destroying a body destroys its joints)
destroy_refs(world, ^$T)              // every body and joint ref inside a plain value, destroyed and zeroed (RTTI, cached)
despawn(world, ^sim.Table(T, N), handle)    // destroy_refs on the item, then sim.despawn
despawn_all(world, ^sim.Table(T, N))        // every item: destroy_refs, then sim.despawn_all
body_valid(world, Body_Link) -> bool  joint_valid(world, Joint_Ref) -> bool  resolve(world, Body_Link) -> (Body_Ref, bool)
```

## Entity tags

Each body carries a **tag**, a u64 the game chooses (`sim.handle_key(handle)`, `sim.player_key(player)`), set at
creation, `body_set_tag` / `body_tag` after. Every result and event carries the tag of the body hit and the category
bits of the shape hit. Tags are physics' table by body index: rolled back, imaged and deep-hashed with the world.

## What physics covers

Every Box3D proc of its world, query, event, body, shape, geometry and joint groups, except Out of scope (a world
setter once a test shows it rolls back). The per-body queries take a `pose: Maybe(Transform)` (nil: where the body
is). Geometry is host-side, outside the block: Box3D copies a hull, but a mesh, height field or compound shape keeps a
pointer to the caller's geometry, so keep it alive as long as the world (a rollback can bring a destroyed shape back).
Height fields and compounds go on static bodies.

## Results

Deterministic order: `out` arrays sorted (casts by fraction, then body and shape index; the rest by body and shape
index), events in Box3D's order (world state). Collecting procs **replace** `out`'s contents: a game keeps the array in
its World as scratch, and a forgotten `clear` can't carry a result into another tick. Casts take an origin and a
translation (the whole length). Events are read in the tick that stepped; a re-simulation regenerates them.

```odin
Filter :: struct {category, mask: u64, group: i32}  // a query's: zero is everything
Overlap :: struct {body: Body_Link, shape: Shape_Ref, tag, category: u64}
Hit :: struct {using overlap: Overlap, material: u64, point, normal: [3]f32, fraction: f32}
Contact_Event :: struct {kind: enum {Begin, End, Hit}, a, b: Overlap, point, normal: [3]f32, speed: f32}  // Hit: normal a → b
Sensor_Event :: struct {kind: enum {Begin, End}, sensor, visitor: Overlap}
world_cast_ray_closest(world, origin, translation, filter := {}, ignore: Body_Link = {}) -> (Hit, bool) // skips ignore, sensors
world_overlap_shape(world, origin, Shape_Proxy, out: ^[dynamic]Overlap, filter := {})    // the exact shape, not fat AABBs
make_proxy(points: [][3]f32, radius) -> Shape_Proxy // a convex point cloud with a radius (one point: a sphere)
world_contact_events(world, out) / world_sensor_events(world, out)  // the begins, the ends (then the hits)
```

## Character: the dynamic character controller

A port of Box3D's dynamic mover sample: a rotation-locked dynamic capsule; a mover joint drives it to a target
horizontal velocity with a force cap; a pogo joint (a spring) holds it above the ground its ray probes find.
Accelerate/friction movement, coyote time, a jump buffer and a limp mode. On a kinematic body the mover joint attaches
to it (platforms carry the character); otherwise to the anchor. Joints come and go with the ground, inside rollback
windows.

```odin
Character :: struct {body: Body_Ref, move_joint: Mover_Joint_Ref, pogo: Pogo_Joint_Ref, ground: Body_Link, ...}  // in the block
Character_Def :: struct {radius, half_height, density, category, mask, material, ..., jump_buffer_s, platform_material}
CHARACTER_DEFAULT                           // the sample's tuning: a game starts from it and sets its own fields
character_create(world, ^Character, Character_Def, pos, tag: u64 = 0)      character_destroy(world, ^Character)
character_update(world, ^Character, Character_Def, move: [2]f32, jump: bool, speed_scale, dt) -> (jumped: bool)
                                           // before the step; move: the wanted (x, z) direction, ≤ 1; jump: a fresh press
character_launch(world, ^Character)        // an outside impulse lifts it (pads, hits): no pogo pull-down until it lands
character_set_limp(world, ^Character, bool) // no drive, no pogo (held, stunned)
character_teleport(world, ^Character, pos)  // respawn
character_grounded(^Character) -> bool      // on walkable ground
```

## Kinematic paths

```odin
Path :: struct {points: [16][3]f32, seconds: [16]f32, wait_s: [16]f32, count: u8, mode: enum u8 {Ping_Pong, Loop, Once},
               ease: enum u8 {Linear, Smooth}}          // level data, outside the block; times round to whole ticks
path_duration_ticks(^Path, tick_hz) -> u32
path_sample(^Path, phase_tick, tick_hz) -> [3]f32      // pure; smoothstep is 3t² − 2t³
drive_kinematic(world, Body_Ref, target: [3]f32, tick_hz)  // velocity = (target − position) · tick_hz: no drift
```

## Static level geometry

`create_static(world, ^level.Level, default_category) -> (count: int, problem: string)`: one static body per level
body, in file order, the World's (shapes without a category get `default_category`); `create_level_shape(world,
Body_Ref, ^Shape_Def, ^level.Shape) -> bool` adds one level shape to any body. A shape Box3D refuses (a hull under 4
points, or past its edge limit) is never a silent hole: `problem` names it, and the games assert on it.

## 2D

A 2D game uses the same world, refs, rollback and queries; its bodies are Box3D bodies locked to a plane, so there is
no second engine. The plane is XY with Godot's 2D axes (x right, y down, z into the screen), in metres; bodies live at
z = 0. A 2D rotation is about +Z, positive turns +x toward +y (Godot's `Node2D.rotation`), held as a unit vector
`(cos a, sin a)` so the sim needs no trig. Gravity is the world's (zero for top-down, `{0, g, 0}` for a side view).

Every proc whose vectors differ in 2D has a `_2d` form; the rest (mass, tags, sleep, queries at z = 0) are shared:

```odin
body_def_2d(type, pos: [2]f32, rot: [2]f32 = {1, 0}) -> Body_Def  // z = 0, locks linear Z, angular X and Y
quat_2d(rot: [2]f32) -> [4]f32        // any non-zero direction (normalised; zero: identity) -> about +Z, w ≥ 0
rot_2d(q: [4]f32) -> [2]f32           // (w² − z², 2wz)
body_position_2d, body_rotation_2d, body_set_transform_2d, ..., body_apply_angular_impulse_2d   // angles and torques: f32
create_circle_shape_2d(world, Body_Ref, ^Shape_Def, radius, center: [2]f32 = {}) -> Shape_Ref      // a sphere at z = 0
create_box_shape_2d(world, Body_Ref, ^Shape_Def, half: [2]f32, depth) -> Shape_Ref                 // centred on the plane
create_polygon_shape_2d(world, Body_Ref, ^Shape_Def, points: [][2]f32, depth) -> (Shape_Ref, bool) // convex hull of 3..32 points
```

The plane holds exactly: Box3D zeroes locked velocity components before each substep's position update, and
unified-box3d again after the step, so z, the quaternion's x and y, v.z, ω.x and ω.y stay ±0.

## Known limits

- **Box3D generations are u16, reused last-in-first-out**: after 65,536 reuses of an index a stale `Body_Link` or
  `Joint_Ref` names a live one again. Keep links short-lived.
- **Host geometry only grows while a world lives** (the hull database is append-only, for rollbacks).

## Tests (`tests/physics`)

Box3D itself (`box3d_test.odin`): the mirrors' layouts and enums, a library sync-test, image loads on damaged bytes.
Through physics: the plug-in, every game-facing proc once, the character, paths, the exact 2D plane, and two small
games (a character rig, a top-down field) sync-tested on 1 and 4 workers and resumed from a portable snapshot. Golden
traces pin the results on every platform: `BOX3D_GOLDEN` (Box3D alone), `GOLDEN_CHARACTERS`, `GOLDEN_FIELD`.
