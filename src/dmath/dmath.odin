// Deterministic f32 helpers for game code: only `+ − × ÷` and hardware sqrt (IEEE-exact on every
// platform). Odin never fuses a multiply and an add (tests/dmath's canary), in scalar or array arithmetic.
// Angles, exp and curves are fixed polynomials in angle.odin and curve.odin.
package dmath

import "base:intrinsics"

// The hardware square root: IEEE 754 rounds it exactly, so it gives the same bits on every platform. The one
// sqrt sim code uses.
sqrt :: #force_inline proc "contextless" (x: f32) -> f32 {
	return intrinsics.sqrt(x)
}

// The smaller of two numbers: `a` when it is below `b`, else `b` (a tie, -0 against +0, or a NaN `a` gives `b`). A
// compare and a select, so the same bits on every platform: the builtin `min` on floats lowers to an instruction
// free to return either zero on a tie, and x64 and arm64, debug and release builds, and even two inlined calls of
// one build pick differently. The lint bans the builtin in tick code; integers come here too (the lint can't see
// types, and it costs nothing).
min :: #force_inline proc "contextless" (a, b: $T) -> T where intrinsics.type_is_numeric(T) {
	return a if a < b else b
}

// The larger of two numbers: `a` when it is above `b`, else `b` (a tie or a NaN `a` gives `b`). As `min`.
max :: #force_inline proc "contextless" (a, b: $T) -> T where intrinsics.type_is_numeric(T) {
	return a if a > b else b
}

// `x` limited to [lo, hi]: lo when x is below it, hi when above, else x (a NaN x stays NaN). As `min`; lo <= hi.
clamp :: #force_inline proc "contextless" (x, lo, hi: $T) -> T where intrinsics.type_is_numeric(T) {
	return lo if x < lo else (hi if hi < x else x)
}

// A vector's length, 2D or 3D.
length :: proc {
	length2,
	length3,
}

length2 :: #force_inline proc "contextless" (vec: [2]f32) -> f32 {
	return sqrt(vec.x * vec.x + vec.y * vec.y)
}

length3 :: #force_inline proc "contextless" (vec: [3]f32) -> f32 {
	return sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
}

// A vector's squared length, 2D or 3D (x² + y² (+ z²), in that order): compare it to a squared bound to skip the sqrt.
length_sq :: proc {
	length_sq2,
	length_sq3,
}

length_sq2 :: #force_inline proc "contextless" (vec: [2]f32) -> f32 {
	return vec.x * vec.x + vec.y * vec.y
}

length_sq3 :: #force_inline proc "contextless" (vec: [3]f32) -> f32 {
	return vec.x * vec.x + vec.y * vec.y + vec.z * vec.z
}

// The squared distance between two points, 2D or 3D (length_sq(a - b)): range checks compare it to a squared radius.
dist_sq :: proc {
	dist_sq2,
	dist_sq3,
}

dist_sq2 :: #force_inline proc "contextless" (a, b: [2]f32) -> f32 {
	dx := a.x - b.x
	dy := a.y - b.y
	return dx * dx + dy * dy
}

dist_sq3 :: #force_inline proc "contextless" (a, b: [3]f32) -> f32 {
	dx := a.x - b.x
	dy := a.y - b.y
	dz := a.z - b.z
	return dx * dx + dy * dy + dz * dz
}

// The dot product a · b, 2D or 3D (a.x * b.x + a.y * b.y (+ a.z * b.z), in that order).
dot :: proc {
	dot2,
	dot3,
}

dot2 :: #force_inline proc "contextless" (a, b: [2]f32) -> f32 {
	return a.x * b.x + a.y * b.y
}

dot3 :: #force_inline proc "contextless" (a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

// The 2D cross product a.x * b.y - a.y * b.x: the sine of the angle from a to b times both lengths (positive: b is
// counter-clockwise of a in a y-up plane, clockwise in Godot's y-down 2D).
cross2 :: #force_inline proc "contextless" (a, b: [2]f32) -> f32 {
	return a.x * b.y - a.y * b.x
}

// A vector scaled to length 1 (2D or 3D; zero when |v| <= eps).
normalize :: proc {
	normalize2,
	normalize3,
}

normalize2 :: proc "contextless" (vec: [2]f32, eps: f32 = 0.0001) -> [2]f32 {
	length := length2(vec)
	if length <= eps {
		return {}
	}
	return {vec.x / length, vec.y / length}
}

normalize3 :: proc "contextless" (vec: [3]f32, eps: f32 = 0.0001) -> [3]f32 {
	length := length3(vec)
	if length <= eps {
		return {}
	}
	return {vec.x / length, vec.y / length, vec.z / length}
}

// A vector scaled down to length `max_len` when it is longer, 2D or 3D.
clamp_length :: proc {
	clamp_length2,
	clamp_length3,
}

clamp_length2 :: proc "contextless" (vec: [2]f32, max_len: f32) -> [2]f32 {
	length_sq := vec.x * vec.x + vec.y * vec.y
	if length_sq <= max_len * max_len {
		return vec
	}
	scale := max_len / sqrt(length_sq)
	return {vec.x * scale, vec.y * scale}
}

clamp_length3 :: proc "contextless" (vec: [3]f32, max_len: f32) -> [3]f32 {
	length_sq := vec.x * vec.x + vec.y * vec.y + vec.z * vec.z
	if length_sq <= max_len * max_len {
		return vec
	}
	scale := max_len / sqrt(length_sq)
	return {vec.x * scale, vec.y * scale, vec.z * scale}
}

// The rotation about +Y that turns +Z toward a unit floor direction `facing` (x, z), as a unit quaternion (x, y, z,
// w), sqrt only, so a tick may use it (a character's facing; the 3D counterpart of physics.quat_2d). Accurate to about
// 1e-7 at every facing. `facing` is unit length (dmath.normalize) or zero (normalize's result for none): the identity.
quat_yaw :: proc "contextless" (facing: [2]f32) -> [4]f32 {
	if facing == {} do return {0, 0, 0, 1} // -0 compares equal to 0
	// For the angle θ from +Z (cos θ = facing.y, sin θ = facing.x), c and s the half angle's: (1 + cos θ, |sin θ|) =
	// 2c·(c, |s|) and (|sin θ|, 1 − cos θ) = 2|s|·(c, |s|). Their sum is (c, |s|) times 2(c + |s|) >= 2, and every term
	// in it is >= 0: no cancellation anywhere, so normalizing it is exact to rounding; s's sign goes on afterwards. (The
	// half angle from the cosine alone, sqrt((1 + cos θ) / 2), loses most of its bits facing near -Z.)
	cos_part, sin_part := (1 + facing.y) + abs(facing.x), (1 - facing.y) + abs(facing.x)
	length := sqrt(cos_part * cos_part + sin_part * sin_part)
	cos_half, sin_half := cos_part / length, sin_part / length
	if facing.x < 0 do sin_half = 0 - sin_half
	return {0, sin_half, 0, cos_half}
}

// Rotates vec by the unit quaternion quat (x, y, z, w), u = (x, y, z): vec + 2w(u×vec) + 2u×(u×vec), each term
// written out.
quat_rotate :: proc "contextless" (quat: [4]f32, vec: [3]f32) -> [3]f32 {
	quat_vec := [3]f32{quat.x, quat.y, quat.z}
	cross := [3]f32 {
		2 * (quat_vec.y * vec.z - quat_vec.z * vec.y),
		2 * (quat_vec.z * vec.x - quat_vec.x * vec.z),
		2 * (quat_vec.x * vec.y - quat_vec.y * vec.x),
	}
	cross_cross := [3]f32 {
		quat_vec.y * cross.z - quat_vec.z * cross.y,
		quat_vec.z * cross.x - quat_vec.x * cross.z,
		quat_vec.x * cross.y - quat_vec.y * cross.x,
	}
	return {
		vec.x + quat.w * cross.x + cross_cross.x,
		vec.y + quat.w * cross.y + cross_cross.y,
		vec.z + quat.w * cross.z + cross_cross.z,
	}
}


// x truncated toward zero and clamped to [lo, hi]; NaN gives lo. Clamping happens on the f32, so
// the conversion never sees a value outside the integer range (out-of-range and NaN conversions
// differ between x86 and ARM).
to_i32_clamped :: proc "contextless" (x: f32, lo, hi: i32) -> i32 {
	if !(x > f32(lo)) {
		return lo // also NaN
	}
	if x >= f32(hi) {
		return hi
	}
	return i32(x)
}

// The 8 compass directions k·45° as unit vectors {cos, sin}, exact table values: angle_vec(k / 8) gives the same bits.
@(rodata)
DIR8 := [8][2]f32 {
	{1, 0},
	{0.70710677, 0.70710677},
	{0, 1},
	{-0.70710677, 0.70710677},
	{-1, 0},
	{-0.70710677, -0.70710677},
	{0, -1},
	{0.70710677, -0.70710677},
}
