# `unified:physics`: Box3D for games, characters, kinematic paths

Status: signed off 2026-11-14 (#7); first 2026-11-09; 2026-11-16 the boundary, full coverage and entity tags
(#236, #237).

Box3D as `sim` rollback state, the whole of Box3D a game uses, addressed by references from the state block, plus
what every co-op physics game needs. First user: `games/friendslop/SPEC.md`.
Everything stays deterministic: f32, `+ − × ÷ sqrt`, fixed tables instead of trig, float-to-int through `dmath`,
Box3D (any worker count steps identically), state in the block or in the Box3D world (both snapshotted).

## The plug-in

```odin
create(settings := Settings{}) -> ^World    // one Box3D world; mutex-guarded (Box3D's world table is global)
destroy(world)
Settings :: struct {workers: i32, gravity: Maybe([3]f32), hit_threshold: f32, anchor: bool}
extra(world, State) -> sim.Extra            // the world as rollback state; finds every ref by RTTI once; make it last
```

- `workers`: Box3D's threads for the step (0 or 1: the caller's thread). Results are bit-identical for any count;
  each game sets it (`PHYSICS_WORKERS`, 1 for now: Godot and the netcode share the CPU).
- `gravity` nil: Box3D's default; `hit_threshold` 0: Box3D's default approach speed for hit events; `anchor`: the
  static body characters attach their joints to, created first (it shifts every later body's index).
- The `Extra`: saves are Box3D snapshots (a memcpy of the world's arena), one per ring slot (`sim.ring_size(tick_hz)`,
  so 32 at 128 Hz; room for `sim.MAX_RING_SIZE`, the unused ones stay empty); a restore puts back everything
  (contacts, warm starts, sleep, trees), so a re-simulation continues bit-exactly. The hash is Box3D's whole-world
  hash (its canonical image's) on `DEEP_CHECKSUM_EVERY` ticks, the ones peers compare; on other ticks the awake
  bodies' hash (every awake body's id, pose and velocities, so also which bodies are awake), a fraction of the cost,
  so a divergence anywhere in the awake world shows on the next tick in sync-tests and traces. Each save, hash (deep
  ticks) and image also carries physics' body table (Entity tags, below). Images are Box3D's canonical images with
  their geometry (unified-box3d's SPEC.md), then the table; `load` puts the world back when Box3D refuses one.

## The boundary (#236)

**Games import `unified:physics`, never `unified:b3`**: their sim package, extension and tests (the lint allows
`unified:b3` in `src/physics` and `tests/b3` only). Physics re-addresses Box3D: each wrapper is one Box3D proc taking
a reference instead of an id, with the same meaning; physics invents no concepts beyond references, tags and the
rollback plumbing.

- **Names**: Box3D's, by b3's rule, with `get_` dropped: `b3Body_GetPosition` → `body_position`,
  `b3Body_SetLinearVelocity` → `body_set_linear_velocity`, `b3Shape_SetFriction` → `shape_set_friction`,
  `b3RevoluteJoint_SetMotorSpeed` → `revolute_joint_set_motor_speed`, `b3World_CastShape` → `world_cast_shape`,
  `b3CreateBody` → `create_body`. Every proc takes the physics `World` first. A plane-locked form adds `_2d` (2D,
  below). An agent finds a proc's meaning in Box3D's docs by its name, and coverage diffs against Box3D's API.
- **Types**: def structs, value types and their defaults are b3's, re-exported by alias (`Body_Def :: b3.Body_Def`,
  `default_shape_def :: b3.default_shape_def`, `Transform`, `Sphere`, `Capsule`, `Hull_Data`, `Mass_Data`, the joint
  defs, ...). Creation takes the references as arguments and fills the def's ids itself (`create_revolute_joint(w,
  link(a), link(b), &def)`: links, so a joint can attach to the anchor, `world_anchor(world)`, or a platform); it
  asserts the def's `user_data` unset (a pointer has no place in rollback state). A `name` is fine: Box3D copies it
  into the world (its names table, hashed and imaged), and `body_set_name` / `shape_set_name` set one later.
- **Out of scope**, each for a reason: debug draw, profile and counters (host-side diagnostics; the bench reads them
  through b3), Box3D's recording (our replays), the dynamic tree (internal), task and worker callbacks (`Settings`
  owns `workers`), pre-solve, custom-filter, friction and restitution callbacks (code pointers run mid-step on
  workers), the `user_data` setters (pointers), step and snapshots (the plug-in's), narrow-phase internals
  (`ShapeDistance`, pair casts, simplexes, the mover's `SolvePlanes` / `ClipVector`: the world and body queries cover
  games), `World_EnableSpeculative` (Box3D stores the flag and never reads it: speculation is per shape), Box3D's demo
  geometry
  (`CreateRock`, `CreateComplexHull`, the wave and torus meshes), and `ComputeCosSin` (ours is `dmath`).

## References

- `Body_Ref {index1, generation}`: a body the block **owns**: Box3D's id without the world index, so blocks match
  across worlds and machines. Indices come from creation order, so a game creates its bodies in a fixed order.
  Accessors trust it (`check_refs` covers the block's).
- `Body_Link` (same bits): a body owned elsewhere (the platform a character stands on, a held item, a query's hit).
  May be stale: `resolve(world, link) -> (Body_Ref, bool)` checks it and gives a ref to use **now**, never to keep;
  `link(ref)` goes the other way. So every accessor has one form, on a `Body_Ref`.
- `Shape_Ref`: a shape (`create_*_shape` returns one; results carry the shape hit). Destroyed with its body.
- **Typed joint refs**, one per Box3D joint type: `Distance_Joint_Ref`, `Filter_Joint_Ref`, `Motor_Joint_Ref`,
  `Mover_Joint_Ref`, `Parallel_Joint_Ref`, `Pogo_Joint_Ref`, `Prismatic_Joint_Ref`, `Revolute_Joint_Ref`,
  `Spherical_Joint_Ref`, `Weld_Joint_Ref`, `Wheel_Joint_Ref`: a setter of another joint type does not compile (the
  release library doesn't check a joint's type). The generic `joint_*` procs take any of them; an untyped
  `Joint_Ref` (`body_joints`' results) converts with `joint_as(world, ref, Revolute_Joint_Ref) -> (ref, bool)`.
- `check_refs(world, state) -> string`: every body, shape and joint ref in the block is valid, and **no body is an
  orphan**: bodies created before `extra()` (level geometry, the anchor, trigger sensors: a game makes `extra` last in
  `world_create`) are the World's; every
  body created after must be owned by a `Body_Ref` in the block. "" when all holds, else the first problem. It is the
  `Extra`'s `check`, so `scenarios.rollback_every_tick` runs it after every restore.

```odin
create_body(world, ^Body_Def, tag: u64 = 0) -> Body_Ref
destroy_body(world, ^Body_Ref)        // checked: a stale ref is a no-op, never another body; zeroes the ref
destroy_joint(world, ^$J)             // any typed joint ref, checked likewise (destroying a body destroys its joints)
destroy_refs(world, ^$T)              // every body and joint ref inside a plain value, destroyed and zeroed (RTTI, cached)
despawn(world, ^sim.Table(T, N), index | handle)    // destroy_refs on the item, then sim.despawn
body_valid(world, Body_Link) -> bool  joint_valid(world, $J) -> bool  resolve(world, Body_Link) -> (Body_Ref, bool)
```

Box3D's release library (what every build links but `--mode debug`) compiles its id checks out, so a stale id reaches
whatever now has its index. Accessors trust refs (`check_refs` covers them); `destroy_*` and `resolve` check, where a
stale one is plausible. `uni test --box3d-debug` (run by `verify`) runs the suite against the debug library, whose
asserts trap a misused id. `body_id`, `link_id` and `joint_id` (raw `b3` ids) stay for the library and `tests/b3`.

## Entity tags (#237)

Each body carries a **tag**, a u64 the game chooses (`sim.handle_key(handle)`, `sim.player_key(player)`): set at
`create_body` (and `character_create`), `body_set_tag` / `body_tag` after. Every query result and event carries the
tag of the body hit and the **category bits of the shape hit**, so a game switches on its categories (`CAT_ITEM`,
`CAT_PLAYER`) and decodes the tag as that table's key (`sim.handle_of_key`). `user_material_id` is a material again.
Tags live in a table in the physics `World` by body index, saved per ring slot with the Box3D snapshot, carried in
the image, hashed on the deep ticks, and reset when physics destroys the body.

## What physics covers

Every Box3D proc in these groups, on references, named by the rule above:

| Group     | Procs |
|-----------|-------|
| World     | `world_set/_gravity`, `world_explode`, the solver settings (`world_enable_sleeping`, `_continuous`, `_warm_starting`, `_speculative`, `_restitution_propagation`; `world_set/_restitution_threshold`, `_restitution_iterations`, `_hit_event_threshold`, `_contact_tuning`, `_contact_recycle_distance`, `_maximum_linear_speed`, `_isotropic_inertia_tolerance`; `world_is_*`), `world_bounds`, `world_awake_body_count`. A setter is covered only once a test shows it rolls back with the snapshot. |
| Queries   | `world_cast_ray_closest`, `world_cast_ray`, `world_cast_shape`, `world_overlap_aabb`, `world_overlap_shape`, `world_cast_mover`, `world_collide_mover`; per body `body_cast_ray`, `body_cast_shape`, `body_overlap_shape`, `body_closest_point`, `body_collide_mover`, `body_time_of_impact_mover` (a `pose: Maybe(Transform)`, nil: where the body is now); per shape `shape_ray_cast`, `shape_closest_point`. The mover queries skip sensors and take an `ignore` body like the ray's, and give `Mover_Plane`s (body, shape, tag, category, plane, point) |
| Events    | `world_contact_events` (begin, end, hit), `world_sensor_events` (begin, end), `world_joint_events` (force and torque thresholds), `world_body_events` (moves) |
| Bodies    | create, destroy; type; transform (`body_position`, `_rotation`, `_transform`, `body_set_transform`, `body_set_target_transform`); local and world points and vectors; velocities (linear, angular, of a point); forces, torques and impulses (at a point, at the centre); mass, inertia, mass data; damping; gravity scale; sleep (awake, threshold, enable); enable and disable; motion locks; bullet; fast rotation; contact recycling; hit events; safety factor; extents and AABB; `body_shapes`, `body_joints`, `body_contact_data` |
| Shapes    | `create_sphere_shape`, `_capsule_`, `_hull_`, `_transformed_hull_`, `_mesh_`, `_height_field_`, `_baked_compound_shape`, `destroy_shape`; type, body, sensor, density, friction, restitution, surface materials (the mesh ones too), filter, the event switches (sensor, contact, hit), geometry get and set (sphere, capsule, hull, mesh), AABB, mass data, contact and sensor data, `shape_apply_wind` |
| Geometry  | host-side, outside the block: `create_hull`, `clone_hull`, `clone_and_transform_hull`, `destroy_hull`, `make_box_hull` and its cube, offset, transformed and scaled forms, `create_cylinder`, `create_cone`, `create_mesh`, `create_box_mesh`, `create_hollow_box_mesh`, `create_platform_mesh`, `create_grid_mesh`, `destroy_mesh`, `create_height_field`, `create_grid` (height field), `destroy_height_field`, `create_compound`, `destroy_compound`, `compute_*_mass`, `compute_*_aabb`. Box3D copies a hull into its database, but a mesh, height field or compound shape keeps a pointer to the caller's geometry (a compound to its meshes too): keep it alive as long as the world, since a rollback can bring a destroyed shape back. Height fields and compounds go on static bodies. Images carry all of them (tested) |
| Joints    | generic, on any joint ref: type, bodies, local frames, collide-connected, wake, awake, constraint force and torque, linear and angular separation, constraint tuning, force and torque thresholds; per type, create and every getter and setter of Box3D's distance, filter, motor, mover, parallel, pogo, prismatic, revolute, spherical, weld and wheel joints |

Results come back in a deterministic order: `out` arrays sorted (casts by fraction then body index, overlaps and
contact data by body index), events in Box3D's order (part of the world state, so the same after a restore and on
every machine). Procs that collect **replace** `out`'s contents, never append: a game keeps the array in its World
as scratch, and a forgotten `clear` can't carry one tick's results into the next, which would diverge after a
rollback unhashed (`src/sim/SPEC.md`, World). Rays and casts take an origin and a translation (the whole length), not
two points. Events are read in the tick that stepped, so a re-simulation regenerates them; nothing about them is
kept.

```odin
Query :: struct {category, mask: u64}  // zero: everything
Ray_Hit :: struct {body: Body_Link, shape: Shape_Ref, tag, category, material: u64, point, normal: [3]f32, fraction: f32}
Overlap :: struct {body: Body_Link, shape: Shape_Ref, tag, category: u64}
Contact_Event :: struct {kind: enum {Begin, End, Hit}, a, b: Overlap, point, normal: [3]f32, speed: f32}  // Hit: normal a → b
world_contact_events(world, out) / world_sensor_events(world, out)  // the begins, the ends (then the hits), each in Box3D's order
Sensor_Event :: struct {kind: enum {Begin, End}, sensor, visitor: Overlap}
step(world, dt, substeps)
world_cast_ray_closest(world, origin, translation, query := {}, ignore: Body_Link = {}) -> (Ray_Hit, bool) // skips ignore, sensors
world_overlap_shape(world, origin, Shape_Proxy, out: ^[dynamic]Overlap, query := {})    // the exact shape, not fat AABBs
world_cast_shape(world, origin, Shape_Proxy, translation, out: ^[dynamic]Ray_Hit, query := {})
make_proxy(points: [][3]f32, radius) -> Shape_Proxy // a convex point cloud with a radius (one point: a sphere)
shape_sensor_data(world, sensor: Shape_Ref, out: ^[dynamic]Overlap)  // what is in a sensor after the step, sorted
```

## Character: the dynamic character controller

A port of Box3D's dynamic mover sample (which says to vendor it). A rotation-locked dynamic capsule; a mover joint
(Box3D's name) drives it to a target horizontal velocity with a force cap; a pogo joint (spring) holds it above the
ground found by ray probes (one centre ray, plus 8 skirt rays from a fixed direction table when the centre misses).
Ground and air follow a classic accelerate/friction model, with coyote time, a jump buffer and a limp mode. Standing on
a kinematic body attaches the mover joint to it, so platforms carry the character sideways; the pogo carries it up and
down.

```odin
Character :: struct {             // in the block, plain data
	body:                                      Body_Ref,
	move_joint:                                Mover_Joint_Ref,
	pogo:                                      Pogo_Joint_Ref,
	ground:                                    Body_Link, // what the pogo stands on (zero: air)
	velocity:                                  [3]f32,    // the drive's target, relative to the body it is attached to
	pogo_impulse, pogo_velocity, time_sliding: f32,
	coyote, jump_buffer, jump_ticks:           u16,       // ticks
	flags:                                     Character_Flags, // On_Ground, Walkable, Jumping, Limp
}
Character_Def :: struct {radius, half_height, density, category, mask, material, hit_events, sensor_events, max_speed,
                         min_speed, stop_speed, accelerate, friction, air_steer, jump_speed, gravity_scale, max_ground_force,
                         max_air_force, pogo_rest, pogo_hertz, pogo_damping, pogo_compression_scale,
                         pogo_tension_scale, min_ground_normal_y, slide_s, coyote_s, jump_buffer_s,
                         platform_material}   // constants in game code, not in the block; CHARACTER_DEFAULT
character_create(world, ^Character, ^Character_Def, pos, tag: u64 = 0)      character_destroy(world, ^Character)
character_update(world, ^Character, ^Character_Def, move: [2]f32, jump: bool, speed_scale, dt) -> (jumped: bool)
character_launch(world, ^Character)        // an outside impulse lifts it (pads, hits): no pogo pull-down until it lands
character_set_limp(world, ^Character, bool) // no drive, no pogo (held, stunned)
character_teleport(world, ^Character, pos)  // respawn
character_grounded(^Character) -> bool      // on walkable ground
```

`character_update` runs before the step: `move` is the wanted (x, z) direction, length ≤ 1; `jump` a fresh press.
Each character's joints attach to the anchor (`Settings.anchor`) or the platform under it. Joints are created and
destroyed as the ground changes, inside rollback windows; Box3D's snapshot covers them.

## Kinematic paths

```odin
Path :: struct {points: [16][3]f32, seconds: [16]f32, wait_s: [16]f32, count: u8, mode: enum u8 {Ping_Pong, Loop, Once},
               ease: enum u8 {Linear, Smooth}}          // level data, outside the block; times round to whole ticks
path_duration_ticks(^Path, tick_hz) -> u32
path_sample(^Path, phase_tick, tick_hz) -> [3]f32      // pure; smoothstep is 3t² − 2t³
drive_kinematic(world, Body_Ref, target: [3]f32, tick_hz)  // velocity = (target − position) · tick_hz: no drift
```

The game keeps each platform's runtime state (`running`, `phase_tick`) in its block. Yaw-only rotation, if a game
needs it, comes later as a unit-vector path.

## Static level geometry

`create_static(world, ^level.Level, default_category) -> (count: int, problem: string)`: one static body per level
body, in file order (shapes without a category get `default_category`; the World's, made before `extra`);
`create_level_shape(world, Body_Ref, ^Shape_Def, ^level.Shape) -> bool` adds one level shape to any body. A shape
Box3D refuses (a hull under 4 points, or past its 128 edges at the 64-vertex cap) is never a silent hole:
`create_level_shape` returns false, and `problem` names the first such level body and shape ("" when every shape was
built); the games assert on it. Baking the level into compound shapes is #148; triangle meshes and height fields in
levels are #149.

## 2D

Decided with the developer 2026-11-10 (Box3D locked to a plane); API signed off 2026-11-14. A 2D game uses the same
world, refs, rollback and queries; its bodies are Box3D bodies locked to a plane, so there is no second engine.

Convention: the sim's 2D plane is XY with Godot's 2D axes (x right, y down, z into the screen), in metres; bodies
live at z = 0. A 2D rotation is about +Z, positive turns +x toward +y (Godot's `Node2D.rotation`,
`view.quat_angle2d`), held as a unit vector `(cos a, sin a)` so the sim needs no trig. Gravity is the world's
(`Settings.gravity`: zero for top-down, `{0, g, 0}` for a side view, y down).

Every proc whose vectors differ in 2D has a `_2d` form, the same name with the suffix; the rest (mass, tags, damping,
sleep, queries with z = 0, ...) are shared:

```odin
body_def_2d(type, pos: [2]f32, rot: [2]f32 = {1, 0}) -> Body_Def  // z = 0, locks linear Z, angular X and Y
quat_2d(rot: [2]f32) -> [4]f32        // any non-zero direction (normalised; zero: identity) -> about +Z, w ≥ 0
rot_2d(q: [4]f32) -> [2]f32           // (w² − z², 2wz)
body_position_2d, body_rotation_2d (a unit vector), body_set_transform_2d(pos, rot)
body_linear_velocity_2d -> [2]f32, body_angular_velocity_2d -> f32, body_set_linear_velocity_2d, body_set_angular_velocity_2d
body_apply_force_2d, body_apply_force_to_center_2d, body_apply_torque_2d (f32),
body_apply_linear_impulse_2d, body_apply_linear_impulse_to_center_2d, body_apply_angular_impulse_2d (f32)
create_circle_shape_2d(world, Body_Ref, ^Shape_Def, radius, center: [2]f32 = {}) -> Shape_Ref      // a sphere at z = 0
create_box_shape_2d(world, Body_Ref, ^Shape_Def, half: [2]f32, depth) -> Shape_Ref                 // centred on the plane
create_polygon_shape_2d(world, Body_Ref, ^Shape_Def, points: [][2]f32, depth) -> (Shape_Ref, bool) // convex hull of 3..32 points
```

A force F over a tick is F · dt as an impulse. Rays are `world_cast_ray_closest` with z = 0. The half angle comes
from `√((1 + c)/2)` when c ≥ 0, else from `√((1 − c)/2)`, so neither branch divides by a small number near ±180°.

How it holds: Box3D zeroes locked velocity components right before each substep's position update (and in the
continuous-collision time-of-impact pose), so with z, quaternion x and y starting at zero they stay exactly zero
(±0): tested bit-exact. Box and hull contacts (points at z = ±depth/2, solved with full 3D inertia) leave off-plane
velocity after the relax iterations; unified-box3d zeroes the locked components again when the step ends (#87), so
the reported v.z, ω.x and ω.y are exactly zero too (tested).

Portable images carry the geometry their shapes use (#86), so a late joiner loads an image whose hulls were made after
tick 0 (arbitrary split shapes included).

## Known limits

- **Box3D generations are u16, and ids are reused last-in-first-out**: after 65,536 reuses of one index, a stale
  `Body_Link` or `Joint_Ref` names a live body or joint again (`body_valid` says yes). The block's `sim.Handle` has u32
  generations; physics refs wrap 65,536 times sooner. Keep links short-lived, or re-check them against the block.
- **Host geometry only grows while a world lives**: the hull database is append-only, so a rollback can bring back a
  destroyed hull's shape. A game that makes new hulls all session (arbitrary splits) grows memory all session.

## Tests (`tests/physics`)

- The plug-in: refs found by RTTI, save/restore through the ring, the world hash, a portable image into a second
  world; `destroy_body` on a stale ref leaves the body that reused its index alone; `check_refs` after every restore,
  and it reports a broken ref and an orphaned body; tags survive restore and an image, and change the deep hash;
  `despawn` and `destroy_refs` free every ref inside an item.
- Every game-facing proc once, through physics (setters read back through their getters; creation, queries and
  events on a small scene; results sorted and `out` replaced); every world setter rolls back with the snapshot.
  `tests/b3` keeps the mirror layouts, the golden trace and the library sync-test.
- Joints under save/restore: a two-character rig (motor, mover and pogo joints created and destroyed inside 8-tick
  windows, a platform, hit events) sync-tests through the harness with 0 mismatches and resumes bit-exact from a
  portable snapshot.
- Character: stands still on flat ground (no drift over 10 s), climbs a 0.3 m step, slides off a steep slope, jumps to
  the expected height, rides a horizontal and a vertical platform for a full cycle without slipping off, is pushed
  by a thrown box, stands on another character; limp and teleport.
- Paths: sampling at segment ends and waits is exact; a kinematic body follows a path with no drift over 10 cycles.
- 2D: the plane (positions and reported velocities) stays exact for 10 s of 42 mixed bodies (circles, boxes, hulls)
  hitting each other and static walls under impulses and angular velocity, two of them near 60 m/s (continuous
  collision keeps them in); circles don't sink into each other or more than 0.15 m into walls; rotation round trips,
  near ±180° included; shape masses, ray hits and poses; a top-down game (ships turning and thrusting, ray-cast shots
  splitting rocks, respawns) sync-tests in 8-tick windows with 0 mismatches and resumes bit-exact from a portable
  image, also with a hull made after tick 0; a damaged image is refused and leaves the world as it was.
- Cross-platform: two golden traces, `GOLDEN_CHARACTERS` (riding a platform for a whole cycle, walking over a step
  and jumping, pushed by a heavy box) and `GOLDEN_FIELD` (the top-down game), hashed every 128 ticks; the values are
  pinned in the tests and must match on every platform. An intended change updates them in the same commit.
- Workers: both sync-tests and both golden traces run on 1 and on 4 workers and must give the same checksums.
- Speed: the games' benchmarks (`uni bench`: step plus a re-sim of the prediction cap, and each tick's save size)
  cover physics as games use it; `uni bench`'s `physics` row (`tests/physics/bench`, #260) times Box3D apart from any
  game on a fixed pile of 512 awake boxes: step, save, restore, deep hash, a batch of 64 rays, and the arena
  snapshot's size. A Box3D upgrade compares it (the `upgrade-dependency` skill).
