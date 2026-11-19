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
- **Transcendentals are ours** (below): never `core:math`'s, whose bits are each platform's libm.
- **An Input holds no floats** (`sim.wire_violation`): the client quantizes with `axis_i8`, `dir2`, `dir3`, and the
  decoders give a defined value for any bits another machine sends.

## Transcendentals

sin, cos, atan2 and exp are fixed polynomials of `+ − ×` in Horner order, with their range reductions, and nothing
else: no table, no libm, no instruction a CPU may implement its own way. Each coefficient is written as an exact f32,
so the compiler's constant conversion cannot differ by host. `tests/dmath` pins the results' bits over a fixed
sweep of inputs on every CI platform, checks them against a twin that rounds once per operation (a failure there
means the compiler fused or reordered something, not that the polynomial changed), and bounds their error.

- **Angles are turns:** 1 is a full circle, a quarter turn is exactly 0.25. Reducing a turn to (-0.5, 0.5] is a
  subtraction of its whole part, exact in f32, where radians would need an inexact multiply by 1/2π and a multi-word
  reduction for large angles. Box3D takes radians: multiply by `TAU` at that call.
- **The eighths are exact.** `angle_vec(k / 8)` is `DIR8[k]` bit for bit, quarter turns give exact 0, 1 and -1 (with
  +0, as in `DIR8`), and `atan2_turns` is exact on the axes and diagonals, so code that mixes the table and angles
  agrees at those directions.
- **Every input has a defined, finite answer.** A NaN or an infinity gives the value each declaration names, and
  `exp` neither overflows nor returns a subnormal: a result can always go into the block.
- **An angle in the block is wrapped when it is advanced** (`wrap_angle`), so it never grows past where an f32 keeps
  its fraction.
- **Curves are sampled at bake time.** A designer curve reaches the sim as evenly spaced samples (`Curve`), looked up linearly:
  the sim never evaluates the editor's cubic. A per-tick motion driven by a curve adds `curve_delta` rather than
  setting the curve's value, so it composes with whatever else moves the same thing.
