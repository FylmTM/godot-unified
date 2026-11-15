// Deterministic f32 helpers for game code: only `+ − × ÷` and hardware sqrt (IEEE-exact on every
// platform), each operation written out so nothing depends on vector codegen or FMA contraction.
// No transcendentals yet; when a game needs sin/cos/atan2 they land here as fixed polynomials.
package dmath

import "base:intrinsics"

Vec2 :: [2]f32
Vec3 :: [3]f32

sqrt :: #force_inline proc "contextless" (x: f32) -> f32 {
	return intrinsics.sqrt(x)
}

length2 :: #force_inline proc "contextless" (vec: Vec2) -> f32 {
	return sqrt(vec.x * vec.x + vec.y * vec.y)
}

length3 :: #force_inline proc "contextless" (vec: Vec3) -> f32 {
	return sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
}

dist_sq2 :: #force_inline proc "contextless" (a, b: Vec2) -> f32 {
	dx := a.x - b.x
	dy := a.y - b.y
	return dx * dx + dy * dy
}

dot3 :: #force_inline proc "contextless" (a, b: Vec3) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

// v / |v|, or zero when |v| <= eps.
normalize2 :: proc "contextless" (vec: Vec2, eps: f32 = 0.0001) -> Vec2 {
	length := length2(vec)
	if length <= eps {
		return {}
	}
	return {vec.x / length, vec.y / length}
}

normalize3 :: proc "contextless" (vec: Vec3, eps: f32 = 0.0001) -> Vec3 {
	length := length3(vec)
	if length <= eps {
		return {}
	}
	return {vec.x / length, vec.y / length, vec.z / length}
}

// v scaled down to length `max_len` when it is longer.
clamp_length2 :: proc "contextless" (vec: Vec2, max_len: f32) -> Vec2 {
	length_sq := vec.x * vec.x + vec.y * vec.y
	if length_sq <= max_len * max_len {
		return vec
	}
	scale := max_len / sqrt(length_sq)
	return {vec.x * scale, vec.y * scale}
}

// Rotates vec by the unit quaternion quat (x, y, z, w), u = (x, y, z): vec + 2w(u×vec) + 2u×(u×vec), each term
// written out.
quat_rotate :: proc "contextless" (quat: [4]f32, vec: Vec3) -> Vec3 {
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

lerp :: #force_inline proc "contextless" (a, b, t: f32) -> f32 {
	return a + (b - a) * t
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

// The 8 compass directions k·45°, as exact table values (no trig).
@(rodata)
DIR8_C := [8]f32{1, 0.70710677, 0, -0.70710677, -1, -0.70710677, 0, 0.70710677}
@(rodata)
DIR8_S := [8]f32{0, 0.70710677, 1, 0.70710677, 0, -0.70710677, -1, -0.70710677}
