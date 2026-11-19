# `unified:dmath`: deterministic f32 math

The arithmetic tick code uses, identical on every CPU: f32 only, hardware `+ − × ÷` and `sqrt` (IEEE-exact), never
fused into a multiply-add. Vectors are `[2]f32` and `[3]f32`, and the input encodings (`input.odin`) are how a client
puts analog values into an Input. A leaf package: every tick package and every game's sim may import it, and host
code (`godot`, `devui`) may too, since nothing there feeds the sim. The lint (`src/lint/README.md`) enforces the rules
below where a token scan can.

## How it works

- **No fused multiply-add, and vector expressions are fine.** A fused `a * b + c` rounds once instead of twice, so it
  would differ between CPUs. Odin emits a plain multiply and a plain add and never lets LLVM fuse them, for scalars
  and array arithmetic alike, on every target, so `position += direction * (SPEED * DT)` on `[2]f32` computes the
  same bits as x and y written out. The lint bans `fused_mul_add`, `matrix` and `core:math`; `tests/dmath`'s canary
  fails with the reason if a compiler upgrade or flag starts fusing.
- **`min`, `max`, `clamp` are dmath's.** Odin's builtins on floats lower to instructions free to return either zero
  when -0 meets +0: x64 and arm64, debug and release builds, even two inlined calls of one build differ, and a
  `max(dot(v, n), 0)` stores another block. dmath's are a compare and a select, for integers too, since the lint
  can't see types: it bans the builtins with two or more arguments in tick code (`max(u16)`, a type's bound, stays).
  `tests/dmath`'s canary pins the ties.
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
