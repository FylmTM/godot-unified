# `unified:dmath`: deterministic f32 math

Status: draft, pending #331

The arithmetic tick code uses, identical on every CPU: f32 only, hardware `+ − × ÷` and `sqrt` (IEEE-exact), never
fused into a multiply-add.

## API

```odin
Vec2 :: [2]f32    Vec3 :: [3]f32
sqrt(x)                                   // hardware, IEEE-exact
length(v)                                 // 2D or 3D (length2, length3)
normalize(v, eps)                         // 2D or 3D, zero when |v| <= eps (normalize2, normalize3)
dot3(a, b)
dist_sq2(a, b)                            // squared distance: compare against r * r, no sqrt
clamp_length2(v, max_len)
quat_rotate(quat, v)                      // v turned by the unit quaternion (x, y, z, w)
to_i32_clamped(x, lo, hi)                 // clamp the f32, then convert; NaN gives lo
DIR8                                      // [8]Vec2: the 8 compass directions, exact table values (@(rodata))
// input encodings (input.odin): the client quantizes, the sim decodes any bits safely
axis_i8(x) / axis(i8)                     // −1..1 <-> −127..127 (NaN: 0; −128 reads as −1)
stick(x, y: i8) -> Vec2                   // two axes, the length clamped to 1
Dir2 (u16) / dir2(v) / dir2_vec(d)        // a 2D direction in 2 bytes; 0: none
Dir3 ({u, v: u16}) / dir3(v) / dir3_vec(d) // a 3D direction in 4 bytes (octahedral); {}: none
```

## How it works

- **No fused multiply-add, and vector expressions are fine.** A fused `a * b + c` rounds once instead of twice, so it
  would differ between CPUs. Odin emits a plain multiply and a plain add and never lets LLVM fuse them, for scalars
  and array arithmetic alike, on every target, so `position += direction * (SPEED * DT)` on `[2]f32` computes the
  same bits as x and y written out. The lint bans `fused_mul_add`, `matrix` and `core:math`; `tests/dmath`'s canary
  fails with the reason if a compiler upgrade or flag starts fusing.
- **Float to int:** x86 and ARM convert out-of-range floats differently, so a conversion that can be out of range
  goes through `to_i32_clamped` (a convention: the lint can't see types).
- **No transcendentals.** Fixed tables (`DIR8`) and unit vectors stand in for angles (physics keeps a 2D rotation as
  `(cos a, sin a)`). When a game needs sin, cos or atan2, they land here as fixed polynomials with tests pinning
  their bits.
- **An Input holds no floats** (`sim.wire_violation`): the client quantizes with `axis_i8`, `dir2`, `dir3`, and the
  decoders give a defined value for any bits another machine sends.
