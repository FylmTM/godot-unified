// Input encodings: what a client quantizes into an Input (no floats: sim.wire_violation) and the sim decodes, with
// `+ − × ÷` and sqrt only. An input comes from another machine, so every decode accepts any bits: an axis clamps, a
// stick is at most 1 long, a direction is unit length or zero.
package dmath

// −1..1 to an i8 axis (−127..127); NaN gives 0. What a client writes (godot.axis_i8 is this).
axis_i8 :: proc "contextless" (x: f32) -> i8 {
	if !(x == x) do return 0
	return i8(to_i32_clamped(x * 127 + (0.5 if x >= 0 else -0.5), -127, 127))
}

// An i8 axis as −1..1 (−128 reads as −1).
axis :: #force_inline proc "contextless" (x: i8) -> f32 {
	return f32(max(x, -127)) / 127
}

// Two i8 axes as a stick: each −1..1, the length at most 1 (a corner (127, 127) from a modified client moves no
// faster than a full stick).
stick :: proc "contextless" (x, y: i8) -> Vec2 {
	return clamp_length2({axis(x), axis(y)}, 1)
}

// A 2D direction in 2 bytes (about 0.006° steps): a point on the diamond |x| + |y| = 1, walked around once. 0 is no
// direction (a zero Input means "none"), so a zeroed Input holds none.
Dir2 :: distinct u16

// The direction of `dir` (any length; zero, or NaN: none). Client side; plain arithmetic, so a script or bot can use
// it too.
dir2 :: proc "contextless" (dir: Vec2) -> Dir2 {
	l1 := abs(dir.x) + abs(dir.y)
	if !(l1 > 0.000001) do return 0
	x := dir.x / l1
	along := (1 - x) / 2 // 0 at +x, 1 at −x
	s := along if dir.y >= 0 else -along // −1..1: the upper half positive
	return Dir2(to_i32_clamped(s * 32767 + (0.5 if s >= 0 else -0.5), -32767, 32767) + 32768)
}

// The unit vector a Dir2 holds ({}: none).
dir2_vec :: proc "contextless" (dir: Dir2) -> Vec2 {
	if dir == 0 do return {}
	s := f32(i32(dir) - 32768) / 32767
	x := 1 - 2 * abs(s)
	y := (1 - abs(x)) * (1 if s >= 0 else -1)
	return normalize2({x, y}, 0)
}

// A 3D direction in 4 bytes (octahedral: about 0.005° steps). {0, 0} is no direction, so a zeroed Input holds none.
Dir3 :: struct {
	u, v: u16,
}

// The direction of `dir` (any length; zero, or NaN: none).
dir3 :: proc "contextless" (dir: Vec3) -> Dir3 {
	l1 := abs(dir.x) + abs(dir.y) + abs(dir.z)
	if !(l1 > 0.000001) do return {}
	p := Vec2{dir.x / l1, dir.y / l1}
	if dir.z < 0 { 	// the lower half folds out over the corners
		p = {(1 - abs(p.y)) * sign_of(p.x), (1 - abs(p.x)) * sign_of(p.y)}
	}
	return {octa_u16(p.x), octa_u16(p.y)}
}

// The unit vector a Dir3 holds ({}: none).
dir3_vec :: proc "contextless" (dir: Dir3) -> Vec3 {
	if dir == {} do return {}
	x := f32(i32(dir.u) - 32768) / 32767
	y := f32(i32(dir.v) - 32768) / 32767
	z := 1 - abs(x) - abs(y)
	if z < 0 {
		folded_x := (1 - abs(y)) * sign_of(x)
		folded_y := (1 - abs(x)) * sign_of(y)
		x, y = folded_x, folded_y
	}
	return normalize3({x, y, z}, 0)
}

// −1..1 to 1..65535 (0 is kept for "none").
@(private)
octa_u16 :: proc "contextless" (x: f32) -> u16 {
	return u16(to_i32_clamped(x * 32767 + (0.5 if x >= 0 else -0.5), -32767, 32767) + 32768)
}

// 1 for x >= 0, else −1 (the octahedral fold's sign: 0 counts as positive).
@(private)
sign_of :: #force_inline proc "contextless" (x: f32) -> f32 {
	return 1 if x >= 0 else -1
}
