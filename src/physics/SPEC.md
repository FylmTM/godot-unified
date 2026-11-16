# `unified:physics`: characters, joints, kinematic paths

Status: signed off 2026-11-14 (#7); first 2026-11-09.

Box3D as `sim` rollback state, plus what every co-op physics game needs. First user: `games/friendslop/SPEC.md`.
Everything stays deterministic: f32, `+ − × ÷ sqrt`, fixed tables instead of trig, float-to-int through `dmath`,
Box3D (any worker count steps identically), state in the block or in the Box3D world (both snapshotted).

## The plug-in

```odin
create(settings := Settings{}) -> ^World    // one Box3D world; mutex-guarded (Box3D's world table is global)
destroy(world)
Settings :: struct {workers: i32, gravity: Maybe([3]f32), hit_threshold: f32, anchor: bool}
extra(world, State) -> sim.Extra            // the world as rollback state; finds every Body_Ref/Joint_Ref by RTTI once
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
  so a divergence anywhere in the awake world shows on the next tick in sync-tests and traces. Images are Box3D's
  canonical images with their geometry (unified-box3d's SPEC.md); `load` puts the world back when Box3D refuses one.

## References in the block

- `Body_Ref {index1, generation}`: a body the block **owns**: Box3D's id without the world index, so blocks match
  across worlds and machines. Indices come from creation order, so a game creates its bodies in a fixed order.
- `Body_Link` (same bits): a body owned elsewhere (the platform a character stands on, a held item, a query's hit).
  May be stale: `body_valid(world, link)` before use.
- `Joint_Ref`: like `Body_Ref`, for a joint.
- `check_refs(world, state)`: every `Body_Ref` and `Joint_Ref` in the block is valid (tests run it after every restore).

```odin
create_body(world, ^b3.Body_Def) -> Body_Ref     // games create bodies here; shapes with b3 or the *_2d helpers
destroy_body(world, ^Body_Ref)                   // checked: a stale ref is a no-op, never another body
destroy_joint(world, ^Joint_Ref)                 // checked likewise (destroying a body destroys its joints)
body_id(world, Body_Ref) -> b3.Body_Id           // asserts on a zero ref; link_id, joint_id likewise, unchecked
ref_of(b3.Body_Id) -> Body_Ref   link_of(b3.Body_Id) -> Body_Link   link(Body_Ref) -> Body_Link   joint_ref_of
body_valid(world, Body_Link) -> bool             joint_valid(world, Joint_Ref) -> bool
```

Box3D's release library (what every build links but `--mode debug`) compiles its id checks out, so a stale id reaches
whatever now has its index. Accessors trust `Body_Ref` (`check_refs` covers them); `destroy_body` and `destroy_joint`
check, where a stale ref is plausible. `uni test --box3d-debug` (run by `verify`) runs the suite against the debug
library, whose asserts trap a misused id.

## Box3D

Through `unified:b3` (`src/b3/SPEC.md`): `[3]f32`/`[4]f32` everywhere, Odin callbacks, mirrored defs. What physics
and the games use is what `b3` covers; each proc has a test in `tests/b3`.

## Queries and events

Games step and query only through here, never `b3.world_step` or `b3.world_cast_ray*` directly.

```odin
step(world, dt, substeps)
Query :: struct {category, mask: u64}   // zero: everything
Ray_Hit :: struct {body: Body_Link, point, normal: [3]f32, fraction: f32, material: u64}
ray_first(world, origin, translation, query := {}) -> (Ray_Hit, bool)                    // b3World_CastRayClosest
ray_closest(world, origin, translation, query := {}, ignore: Body_Link = {}) -> (Ray_Hit, bool) // skips ignore, sensors
overlap_aabb(world, lo, hi, out: ^[dynamic]Body_Link, query := {})   // clears out; fat AABBs; by body index, no duplicates
Hit_Event :: struct {a, b: Body_Link, point, normal: [3]f32, speed: f32, material_a, material_b: u64}  // normal a → b
hit_events(world, out: ^[dynamic]Hit_Event)   // clears out; after the step, in Box3D's order
position, velocity, set_velocity, rotation, mass, impulse, teleport(world, ref, pos, rot)   // thin body helpers
```

Rays take an origin and a translation (the ray's whole length), not two points. Hit events are read in the tick that
stepped, so a re-simulation regenerates them; nothing about them is kept. `overlap_aabb` and `hit_events` **replace**
`out`'s contents, never append: a game keeps the array in its World as scratch (no allocation per tick once it has
grown), and a forgotten `clear` can't carry one tick's results into the next, which would diverge after a rollback
unhashed (`src/sim/SPEC.md`, World).

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
	move_joint, pogo:                          Joint_Ref,
	ground:                                    Body_Link, // what the pogo stands on (zero: air)
	velocity:                                  [3]f32,    // the drive's target, relative to the body it is attached to
	pogo_impulse, pogo_velocity, time_sliding: f32,
	coyote, jump_buffer, jump_ticks:           u16,       // ticks
	flags:                                     Character_Flags, // On_Ground, Walkable, Jumping, Limp
}
Character_Def :: struct {radius, half_height, density, category, mask, material, hit_events, max_speed, min_speed,
                         stop_speed, accelerate, friction, air_steer, jump_speed, gravity_scale, max_ground_force,
                         max_air_force, pogo_rest, pogo_hertz, pogo_damping, pogo_compression_scale,
                         pogo_tension_scale, min_ground_normal_y, slide_s, coyote_s, jump_buffer_s,
                         platform_material}   // constants in game code, not in the block; CHARACTER_DEFAULT
character_create(world, ^Character, ^Character_Def, pos)      character_destroy(world, ^Character)
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
body, in file order (shapes without a category get `default_category`); `create_shape(body, ^b3.Shape_Def,
^level.Shape) -> bool` adds one level shape to any body. A shape Box3D refuses (a hull under 4 points, or past its 128
edges at the 64-vertex cap) is never a silent hole: `create_shape` returns false, and `problem` names the first such
level body and shape ("" when every shape was built); the games assert on it. Baking the level into compound shapes is #148; triangle meshes and height fields are #149.

## 2D

Decided with the developer 2026-11-10 (Box3D locked to a plane); API signed off 2026-11-14. A 2D game uses the same
world, refs, rollback and queries; its bodies are Box3D bodies locked to a plane, so there is no second engine.

Convention: the sim's 2D plane is XY with Godot's 2D axes (x right, y down, z into the screen), in metres; bodies
live at z = 0. A 2D rotation is about +Z, positive turns +x toward +y (Godot's `Node2D.rotation`,
`view.quat_angle2d`), held as a unit vector `(cos a, sin a)` so the sim needs no trig. Gravity is the world's
(`Settings.gravity`: zero for top-down, `{0, g, 0}` for a side view, y down).

```odin
body_def_2d(type, pos: [2]f32, rot: [2]f32 = {1, 0}) -> b3.Body_Def  // z = 0, locks linear Z, angular X and Y
quat_2d(rot: [2]f32) -> [4]f32        // any non-zero direction (normalised; zero: identity) -> about +Z, w ≥ 0
rot_2d(q: [4]f32) -> [2]f32           // (w² − z², 2wz)
pose_2d(world, Body_Ref) -> (pos: [2]f32, rot: [2]f32)
velocity_2d(world, Body_Ref) -> (linear: [2]f32, angular: f32)
set_velocity_2d(world, Body_Ref, linear: [2]f32, angular: f32)
apply_impulse_2d(world, Body_Ref, j: [2]f32)   // at the centre of mass; a force F over a tick is F · dt (no force call)
circle_2d(body, ^b3.Shape_Def, radius, center: [2]f32 = {}) -> b3.Shape_Id        // a sphere at z = 0
box_2d(body, ^b3.Shape_Def, half: [2]f32, depth) -> b3.Shape_Id                  // centred on the plane
polygon_2d(body, ^b3.Shape_Def, points: [][2]f32, depth) -> (b3.Shape_Id, bool)  // convex hull of 3..32 points, extruded
```

Rays are `ray_closest`/`ray_first` with z = 0. The half angle comes from `√((1 + c)/2)` when c ≥ 0, else from
`√((1 − c)/2)`, so neither branch divides by a small number near ±180°.

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
  world; `destroy_body` on a stale ref leaves the body that reused its index alone; `check_refs` after every restore
  (the Box3D procs themselves, and a library-level sync-test: `tests/b3`).
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
