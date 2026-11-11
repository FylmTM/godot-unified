# `unified:physics`: characters, joints, kinematic paths

Signed off by the developer 2026-11-09. Extends the physics plug-in in `src/sim/SPEC.md` with what every co-op
physics game needs. First user: `games/friendslop/SPEC.md`. Everything stays deterministic: f32, `+ − × ÷ sqrt`, fixed
tables instead of trig, Box3D with one worker, state in the block or in the Box3D world (both snapshotted).

## References in the block

- `Body_Ref` (exists): a body this block **owns**. Found by RTTI, hashed (pose and velocities) in block order.
- `Body_Link` (new, same bits): a body owned elsewhere (the platform a mover stands on, a held item). Not hashed,
  may be stale: `body_valid(w, link)` before use.
- `Joint_Ref` (new): `{index1, generation}` like `Body_Ref`. Found by RTTI for checks, **not hashed**: a joint's
  effect shows in its bodies one tick later, which sync-test and desync checks still catch.
- `check_refs(w, s)`: every `Body_Ref` and `Joint_Ref` in the block is valid (tests run it after every restore).

## Bindings added to `unified:box3d`

Joints (motor, mover, pogo, distance, weld, filter; create, destroy, `IsValid`, `GetBodyA/B`, the motor/mover/pogo
setters and getters), `World_CastRay` with a callback, `World_OverlapAABB`, `World_GetContactEvents` (hit events),
shape defs with `enableHitEvents`, `Body_SetTransform`, `Body_SetAngularVelocity`, `Body_GetType`,
`Body_GetMass`, `Body_ApplyLinearImpulse`, `Body_SetGravityScale`, `Body_GetWorldPointVelocity`,
`Shape_GetBody`, `Shape_IsSensor`. Only what a game uses gets bound; each binding gets a test.

## Queries and events

Games step and query only through here, never `b3World_Step` or `b3World_CastRay*` directly (body and shape
creation still use Box3D's defs).

```odin
step(w, dt, substeps)
ray_first(w, origin, translation, q) -> (Ray_Hit, bool)                     // b3World_CastRayClosest, filtered only
ray_closest(w, from, to, filter, ignore: Body_Link = {}) -> (Hit, bool)   // skips `ignore` and sensors
overlap_aabb(w, lo, hi, filter, out: ^[dynamic]Body_Link)                  // sorted by body index
hit_events(w, out: ^[dynamic]Hit_Event)   // after the step: {body_a, body_b, point, normal, approach_speed}, in Box3D's order
```

Hit events are read in the tick that stepped, so a re-simulation regenerates them; nothing about them is kept.

## Mover: the dynamic character

A port of Box3D's reference dynamic mover (the sample says to vendor it). A rotation-locked dynamic capsule; a
mover joint drives it to a target horizontal velocity with a force cap; a pogo joint (spring) holds it above the
ground found by ray probes (one centre ray, plus 8 skirt rays from a fixed direction table when the centre misses).
Ground and air follow a classic accelerate/friction model. Standing on a kinematic body attaches the mover joint to
it, so platforms carry the mover sideways; the pogo carries it up and down.

```odin
Mover :: struct {                 // in the block, plain data
	body:                  Body_Ref,
	move_joint, pogo:      Joint_Ref,
	ground:                Body_Link, // what the pogo stands on (zero: air)
	velocity:              [3]f32,    // relative to the ground body
	pogo_impulse, pogo_velocity, time_sliding: f32,
	coyote, jump_buffer, jump_ticks: u16,
	flags:                 Mover_Flags, // on_ground, walkable, jumping, limp
}
Mover_Def :: struct {capsule, density, filter, max_speed, accelerate, friction, air_steer, jump_speed,
                     gravity_scale, max_ground_force, max_air_force, pogo_rest, pogo_hertz, pogo_damping,
                     coyote_s, jump_buffer_s, platform_material} // constants in game code, not in the block
mover_create(w, ^Mover, ^Mover_Def, pos)      mover_destroy(w, ^Mover)
mover_update(w, ^Mover, ^Mover_Def, move: [2]f32, jump_pressed: bool, speed_scale: f32)   // before the step
mover_launch(w, ^Mover)             // an outside impulse lifts it (pads, hits): no pogo pull-down until it lands
mover_set_limp(w, ^Mover, bool)     // no drive, no pogo (held, stunned)
mover_teleport(w, ^Mover, pos)      // respawn
```

Each mover's joints attach to one static anchor body that `physics.create` makes. Joints are created and destroyed
as the ground changes, inside rollback windows; the fork's snapshot covers them.

## Kinematic paths

```odin
Path :: struct {points: [16][3]f32, seconds: [16]f32, wait_s: [16]f32, count: u8, mode: enum u8 {Ping_Pong, Loop, Once},
               ease: enum u8 {Linear, Smooth}}          // level data, outside the block
path_duration_ticks(^Path, tick_hz) -> u32
path_sample(^Path, phase_tick, tick_hz) -> [3]f32      // pure; smoothstep is 3t² − 2t³
drive_kinematic(w, Body_Ref, target: [3]f32, dt)       // velocity = (target − position) / dt: no drift, exact on waits
```

The game keeps each platform's runtime state (`running`, `phase_tick`) in its block. Yaw-only rotation, if a game
needs it, comes later as a unit-vector path.

## 2D

Decided with the developer 2026-11-10 (Box3D locked to a plane); API pending review. A 2D game uses the same
world, refs, rollback and queries; its bodies are Box3D bodies locked to a plane, so there is no second engine.

Convention: the sim's 2D plane is XY with Godot's 2D axes (x right, y down, z into the screen), in metres; bodies
live at z = 0. A 2D rotation is about +Z, positive turns +x toward +y (Godot's `Node2D.rotation`,
`view.quat_angle2d`), held as a unit vector `(cos a, sin a)` so the sim needs no trig. Gravity is the world's
(`Settings.gravity`: zero for top-down, `{0, g, 0}` for a side view, y down).

```odin
body_def_2d(type, pos: [2]f32, rot: [2]f32 = {1, 0}) -> b3.BodyDef   // z = 0, locks linear Z, angular X and Y
quat_2d(rot: [2]f32) -> [4]f32        // any non-zero direction (normalised; zero: identity) -> about +Z, w ≥ 0
rot_2d(q: [4]f32) -> [2]f32           // (w² − z², 2wz)
pose_2d(w, Body_Ref) -> (pos: [2]f32, rot: [2]f32)
velocity_2d(w, Body_Ref) -> (linear: [2]f32, angular: f32)
set_velocity_2d(w, Body_Ref, linear: [2]f32, angular: f32)
apply_impulse_2d(w, Body_Ref, j: [2]f32)   // at the centre of mass; a force F over a tick is F · dt
circle_2d(body, ^ShapeDef, radius, center: [2]f32 = {}) -> ShapeId          // a sphere at z = 0
box_2d(body, ^ShapeDef, half: [2]f32, depth) -> ShapeId                    // centred on the plane
polygon_2d(body, ^ShapeDef, points: [][2]f32, depth) -> (ShapeId, bool)    // convex hull of 3..32 points, extruded
```

Rays are `ray_closest`/`ray_first` with z = 0. The half angle comes from `√((1 + c)/2)` when c ≥ 0, else from
`√((1 − c)/2)`, so neither branch divides by a small number near ±180°.

How it holds: Box3D zeroes locked velocity components right before each substep's position update (and in the
continuous-collision time-of-impact pose), so with z, quaternion x and y starting at zero they stay exactly zero
(±0): tested bit-exact. Box and hull contacts (points at z = ±depth/2, solved with full 3D inertia) leave off-plane
velocity after the relax iterations; the fork zeroes the locked components again when the step ends (#87), so the
reported v.z, ω.x and ω.y are exactly zero too (tested).

Portable images and hulls: Box3D's image names hull geometry by its index in the world's registry, which a fresh
world fills from its tick-0 save. A late joiner can load an image only if every hull in it already existed somewhere
in the world at tick 0 (rocks that split into shapes from a fixed set, all present at tick 0); an image with a
hull made later is refused (`Extra_Rejected`) and the world is left as it was. Open: how games with generated
geometry (arbitrary split shapes) late-join.

Tests: the plane (positions and reported velocities) stays exact for 10 s of 42 mixed bodies (circles, boxes,
hulls) hitting each other and static walls under impulses and angular velocity, two of them near 60 m/s
(continuous collision keeps them in); circles don't sink into each other or more than 0.15 m into walls; rotation round trips, near ±180° included; shape masses,
ray hits and poses; a top-down game (ships turning and thrusting, ray-cast shots splitting rocks, respawns) sync-
tests in 8-tick windows with 0 mismatches, resumes bit-exact from a portable image, and has a pinned golden trace;
an image with a hull made after tick 0 is refused.

## Tests (`tests/physics`)

- Every new binding; `check_refs` after restore.
- Joints under save/restore: create and destroy motor, mover and pogo joints inside an 8-tick window, sync-test
  with 0 mismatches; a portable image with joints loads in a fresh world and continues bit-exact.
- Mover: stands still on flat ground (no drift over 10 s), climbs a 0.3 m step, slides off a steep slope, jumps to
  the expected height, rides a horizontal and a vertical platform for a full cycle without slipping off, is pushed
  by a thrown box, stands on another mover.
- Paths: sampling at segment ends and waits is exact; a kinematic body follows a path with no drift over 10 cycles.
- Cross-platform: a golden trace of a mover scene (riding a platform for a whole cycle, walking over a step and
  jumping, pushed by a heavy box), hashed every 128 ticks through the block and the `Extra`'s hash; the values are
  pinned in the test and must match on every platform. An intended change updates them in the same commit.
- Bench: mover update cost per character; save/restore with 4 movers and 4 hold joints.
