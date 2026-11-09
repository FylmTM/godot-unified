# `unified:physics`: characters, joints, kinematic paths

Signed off by the developer 2026-11-09. Extends the physics plug-in in `spec/sim.md` with what every co-op
physics game needs. First user: `spec/friendslop.md`. Everything stays deterministic: f32, `+ − × ÷ sqrt`, fixed
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

```odin
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
mover_launch(^Mover)                // an outside impulse lifts it (pads, hits): no pogo pull-down until it lands
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

## Tests (`tests/physics`)

- Every new binding; `check_refs` after restore.
- Joints under save/restore: create and destroy motor, mover and pogo joints inside an 8-tick window, sync-test
  with 0 mismatches; a portable image with joints loads in a fresh world and continues bit-exact.
- Mover: stands still on flat ground (no drift over 10 s), climbs a 0.3 m step, slides off a steep slope, jumps to
  the expected height, rides a horizontal and a vertical platform for a full cycle without slipping off, is pushed
  by a thrown box, stands on another mover.
- Paths: sampling at segment ends and waits is exact; a kinematic body follows a path with no drift over 10 cycles.
- Cross-arch: a mover-and-joints trace from macOS ARM64 matches under Rosetta (x86_64) and in CI (Linux, Windows).
- Bench: mover update cost per character; save/restore with 4 movers and 4 hold joints.
