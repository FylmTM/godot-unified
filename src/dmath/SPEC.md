# `unified:dmath`: deterministic f32 math

Status: signed off 2026-11-18 (#331)

The arithmetic tick code uses, identical on every CPU: f32 only, hardware `+ − × ÷` and `sqrt` (IEEE-exact), never
fused into a multiply-add.

## API

```odin
sqrt(x)                                   // hardware, IEEE-exact
min(a, b) / max(a, b) / clamp(x, lo, hi)  // compare and select, any number type: the same zero on a ±0 tie everywhere
// vectors are [2]f32 / [3]f32; each group takes either (its members: the name plus 2 or 3)
length(v)  length_sq(v)                   // length_sq: no sqrt, compare against r * r
dist_sq(a, b)                             // squared distance
dot(a, b)                                 // components summed in order: x, y (, z)
cross2(a, b)                              // a.x * b.y - a.y * b.x
normalize(v, eps)                         // zero when |v| <= eps
clamp_length(v, max_len)
quat_rotate(quat, v)                      // v turned by the unit quaternion (x, y, z, w)
quat_yaw(facing: [2]f32) -> [4]f32        // about +Y, turning +Z toward the unit floor direction (x, z): sqrt only
to_i32_clamped(x, lo, hi)                 // clamp the f32, then convert; NaN gives lo
DIR8                                      // [8][2]f32: the 8 compass directions, exact table values (@(rodata))
// input encodings (input.odin): the client quantizes, the sim decodes any bits safely
axis_i8(x) / axis(i8)                     // −1..1 <-> −127..127 (NaN: 0; −128 reads as −1)
stick(x, y: i8) -> [2]f32                 // two axes, the length clamped to 1
Dir2 (u16) / dir2(v) / dir2_vec(d)        // a 2D direction in 2 bytes; 0: none
Dir3 ({u, v: u16}) / dir3(v) / dir3_vec(d) // a 3D direction in 4 bytes (octahedral); {}: none
```

## How it works

- **No fused multiply-add, and vector expressions are fine.** A fused `a * b + c` rounds once instead of twice, so it
  would differ between CPUs. Odin emits a plain multiply and a plain add and never lets LLVM fuse them, for scalars
  and array arithmetic alike, on every target, so `position += direction * (SPEED * DT)` on `[2]f32` computes the
  same bits as x and y written out. The lint bans `fused_mul_add`, `matrix` and `core:math`; `tests/dmath`'s canary
  fails with the reason if a compiler upgrade or flag starts fusing.
- **`min`, `max`, `clamp` are dmath's.** Odin's builtins on floats lower to instructions free to return either zero
  when -0 meets +0: x64 and arm64, debug and release builds, even two inlined calls of one build differ, and a
  `max(dot(v, n), 0)` stores another block. dmath's compare and select (`a if a < b else b`; a tie or a NaN first
  operand gives the second), for integers too, since the lint can't see types: it bans the builtins with two or more
  arguments in tick code (`max(u16)`, a type's bound, stays). `tests/dmath`'s canary pins the ties.
- **No NaN reaches the state block.** A NaN made at run time has each platform's bits (`ffc00000` on x64, `7fc00000`
  on arm64), so a NaN in the block gives peers on different CPUs different checksums. Guard every division and
  `sqrt` whose operand can be 0/0 or negative (`normalize` has its `eps`). The sync-test fails on a NaN in the block
  with its field and tick (`sim.find_nan`); `tests/dmath` pins the bits per platform.
- **Float to int:** x86 and ARM convert out-of-range floats differently, so a conversion that can be out of range
  goes through `to_i32_clamped` (a convention: the lint can't see types).
- **No transcendentals.** Fixed tables (`DIR8`) and unit vectors stand in for angles (physics keeps a 2D rotation as
  `(cos a, sin a)`). When a game needs sin, cos or atan2, they land here as fixed polynomials with tests pinning
  their bits.
- **An Input holds no floats** (`sim.wire_violation`): the client quantizes with `axis_i8`, `dir2`, `dir3`, and the
  decoders give a defined value for any bits another machine sends.
