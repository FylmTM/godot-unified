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

dot2 :: #force_inline proc "contextless" (a, b: Vec2) -> f32 {
	return a.x * b.x + a.y * b.y
}

dot3 :: #force_inline proc "contextless" (a, b: Vec3) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

length2 :: #force_inline proc "contextless" (v: Vec2) -> f32 {
	return sqrt(v.x * v.x + v.y * v.y)
}

length3 :: #force_inline proc "contextless" (v: Vec3) -> f32 {
	return sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

dist_sq2 :: #force_inline proc "contextless" (a, b: Vec2) -> f32 {
	dx := a.x - b.x
	dy := a.y - b.y
	return dx * dx + dy * dy
}

// v / |v|, or zero when |v| <= eps.
normalize2 :: proc "contextless" (v: Vec2, eps: f32 = 0.0001) -> Vec2 {
	l := length2(v)
	if l <= eps {
		return {}
	}
	return {v.x / l, v.y / l}
}

normalize3 :: proc "contextless" (v: Vec3, eps: f32 = 0.0001) -> Vec3 {
	l := length3(v)
	if l <= eps {
		return {}
	}
	return {v.x / l, v.y / l, v.z / l}
}

// v scaled down to length `max_len` when it is longer.
clamp_length2 :: proc "contextless" (v: Vec2, max_len: f32) -> Vec2 {
	s2 := v.x * v.x + v.y * v.y
	if s2 <= max_len * max_len {
		return v
	}
	k := max_len / sqrt(s2)
	return {v.x * k, v.y * k}
}

lerp :: #force_inline proc "contextless" (a, b, t: f32) -> f32 {
	return a + (b - a) * t
}

// The 8 compass directions k·45°, as exact table values (no trig).
DIR8_C := [8]f32{1, 0.70710677, 0, -0.70710677, -1, -0.70710677, 0, 0.70710677}
DIR8_S := [8]f32{0, 0.70710677, 1, 0.70710677, 0, -0.70710677, -1, -0.70710677}
