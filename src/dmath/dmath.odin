// Deterministic f32 helpers for game code: only `+ − × ÷` and hardware sqrt (IEEE-exact on every
// platform), each operation written out so nothing depends on vector codegen or FMA contraction.
// No transcendentals yet; when a game needs sin/cos/atan2 they land here as fixed polynomials.
package dmath

import "base:intrinsics"

Vec2 :: [2]f32
Vec3 :: [3]f32

// The hardware square root: IEEE 754 rounds it exactly, so it gives the same bits on every platform. The one
// sqrt sim code uses.
sqrt :: #force_inline proc "contextless" (x: f32) -> f32 {
	return intrinsics.sqrt(x)
}

// The length of a 2D vector, with the sum written out so it rounds the same on every platform.
length2 :: #force_inline proc "contextless" (vec: Vec2) -> f32 {
	return sqrt(vec.x * vec.x + vec.y * vec.y)
}

// The length of a 3D vector, with the sum written out so it rounds the same on every platform.
length3 :: #force_inline proc "contextless" (vec: Vec3) -> f32 {
	return sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
}

// The squared distance between two 2D points; range checks compare it to a squared radius to skip the sqrt.
dist_sq2 :: #force_inline proc "contextless" (a, b: Vec2) -> f32 {
	dx := a.x - b.x
	dy := a.y - b.y
	return dx * dx + dy * dy
}

// v / |v|, or zero when |v| <= eps.
normalize2 :: proc "contextless" (vec: Vec2, eps: f32 = 0.0001) -> Vec2 {
	length := length2(vec)
	if length <= eps {
		return {}
	}
	return {vec.x / length, vec.y / length}
}

// v / |v|, or zero when |v| <= eps (the 3D form of normalize2).
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

// Linear interpolation from a (t = 0) to b (t = 1), as a + (b - a) * t with no fused multiply-add.
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
