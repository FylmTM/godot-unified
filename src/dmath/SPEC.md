# `unified:dmath`: deterministic f32 math

Status: signed off 2026-11-14 (#6).

The arithmetic tick code uses, identical on every CPU: f32 only, hardware `+ − × ÷` and `sqrt` (IEEE-exact), never
fused into a multiply-add. Tests: `tests/dmath`.

## API

```odin
Vec2 :: [2]f32    Vec3 :: [3]f32
sqrt(x)                                   // hardware, IEEE-exact
length2(v) / length3(v)
dot3(a, b)
dist_sq2(a, b)                            // squared distance: compare against r * r, no sqrt
normalize2(v, eps) / normalize3(v, eps)   // zero when |v| <= eps
clamp_length2(v, max_len)
quat_rotate(quat, v)                      // v turned by the unit quaternion (x, y, z, w)
lerp(a, b, t)
to_i32_clamped(x, lo, hi)                 // clamp the f32, then convert; NaN gives lo
DIR8_C, DIR8_S                            // the exact 8-direction table (@(rodata))
```

## How it works

- **No fused multiply-add, and vector expressions are fine** (decided 2026-11-15). A fused `a * b + c` rounds once
  instead of twice, so it would differ between CPUs. Odin emits a plain multiply and a plain add and never lets LLVM
  fuse them, for scalars and for array arithmetic alike, on every target (x64 with and without FMA3, arm64), so
  `position += direction * (SPEED * DT)` on `[2]f32` computes the same bits as x and y written out. What holds it:
  the lint bans `fused_mul_add`, `matrix` and `core:math`; `tests/dmath`'s canary fails with the reason if a
  compiler upgrade or flag starts fusing (scalar, `[2]`, `[3]`, `[4]f32`, vector times scalar); CI's reference runs
  cross-check every platform.
- **Float to int:** x86 and ARM convert out-of-range floats differently, so a conversion that can be out of range
  goes through `to_i32_clamped`. The lint can't see types; it is a convention (`src/lint/SPEC.md`).
- **No transcendentals yet.** When a game needs sin, cos or atan2, they land here as fixed polynomials, with tests
  pinning their bits. Until then, fixed tables (`DIR8_C/S`) and unit vectors stand in for angles (physics keeps a 2D
  rotation as `(cos a, sin a)`).

## Open

- The first transcendental, when a game needs one.
