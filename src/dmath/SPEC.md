# `unified:dmath`: deterministic f32 math

Reviewed with the developer in the #6 sitting (2026-11-14); signed off when this version merges (moved here from
`src/sim/SPEC.md`).

The arithmetic tick code uses, identical on every CPU: f32 only, hardware `+ − × ÷` and `sqrt` (IEEE-exact), each
operation written out per component so nothing depends on vector codegen or fused multiply-add contraction. Tests:
`tests/dmath`.

## API

```odin
Vec2 :: [2]f32    Vec3 :: [3]f32
sqrt(x)                                   // hardware, IEEE-exact
length2(v) / length3(v)
dist_sq2(a, b)                            // squared distance: compare against r * r, no sqrt
normalize2(v, eps) / normalize3(v, eps)   // zero when |v| <= eps
clamp_length2(v, max_len)
lerp(a, b, t)
to_i32_clamped(x, lo, hi)                 // clamp the f32, then convert; NaN gives lo
DIR8_C, DIR8_S                            // the exact 8-direction table (@(rodata))
```

## How it works

- **No vector expressions.** `position += direction * speed * dt` on `[2]f32` may compile to fused multiply-add on
  one CPU and not another, which rounds differently. Game code writes x and y out (`position.x += direction.x *
  SPEED * DT`), as `dmath` does internally.
- **Float to int:** x86 and ARM convert out-of-range floats differently, so a conversion that can be out of range
  goes through `to_i32_clamped`. The lint can't see types; it is a convention (`src/lint/SPEC.md`).
- **No transcendentals yet.** When a game needs sin, cos or atan2, they land here as fixed polynomials, with tests
  pinning their bits. Until then, fixed tables (`DIR8_C/S`) and unit vectors stand in for angles (physics keeps a 2D
  rotation as `(cos a, sin a)`).

## Open

- The first transcendental, when a game needs one.
