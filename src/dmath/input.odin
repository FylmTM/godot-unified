// Input encodings: what a client quantizes into an Input (no floats: sim.wire_violation) and the sim decodes, with
// `+ − × ÷` and sqrt only. An input comes from another machine, so every decode accepts any bits: an axis clamps, a
// stick is at most 1 long, a direction is unit length or zero.
package dmath

// −1..1 to an i8 axis (−127..127); NaN gives 0. What a client writes.
axis_i8 :: proc "contextless" (x: f32) -> i8 {
	if !(x == x) do return 0
	return i8(to_i32_clamped(x * 127 + (0.5 if x >= 0 else -0.5), -127, 127))
}

// An i8 axis as −1..1 (−128 reads as −1).
axis :: #force_inline proc "contextless" (x: i8) -> f32 {
	return f32(x if x > -127 else -127) / 127
}

// Two i8 axes as a stick: each −1..1, the length at most 1 (a corner (127, 127) from a modified client moves no
// faster than a full stick).
stick :: proc "contextless" (x, y: i8) -> [2]f32 {
	return clamp_length2({axis(x), axis(y)}, 1)
}

// A 2D direction in 2 bytes (about 0.006° steps): a point on the diamond |x| + |y| = 1, walked around once. 0 is no
// direction (a zero Input means "none"), so a zeroed Input holds none.
Dir2 :: distinct u16

// The direction of `dir` (any length; zero, or NaN: none). Client side; plain arithmetic, so a script or bot can use
// it too.
dir2 :: proc "contextless" (dir: [2]f32) -> Dir2 {
	l1 := abs(dir.x) + abs(dir.y)
	if !(l1 > 0.000001) do return 0
	x := dir.x / l1
	along := (1 - x) / 2 // 0 at +x, 1 at −x
	s := along if dir.y >= 0 else -along // −1..1: the upper half positive
	return Dir2(to_i32_clamped(s * 32767 + (0.5 if s >= 0 else -0.5), -32767, 32767) + 32768)
}

// The unit vector a Dir2 holds ({}: none).
dir2_vec :: proc "contextless" (dir: Dir2) -> [2]f32 {
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
dir3 :: proc "contextless" (dir: [3]f32) -> Dir3 {
	l1 := abs(dir.x) + abs(dir.y) + abs(dir.z)
	if !(l1 > 0.000001) do return {}
	p := [2]f32{dir.x / l1, dir.y / l1}
	if dir.z < 0 { 	// the lower half folds out over the corners
		p = {(1 - abs(p.y)) * sign_of(p.x), (1 - abs(p.x)) * sign_of(p.y)}
	}
	return {octa_u16(p.x), octa_u16(p.y)}
}

// The unit vector a Dir3 holds ({}: none).
dir3_vec :: proc "contextless" (dir: Dir3) -> [3]f32 {
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

// Where a first-person player looks, in 4 bytes: yaw and pitch in 1/65536ths of a turn (about 0.0055° a step).
// Godot's convention, so a camera rig's `rotation` maps straight onto it: zero looks along -Z, level (a zeroed Input
// looks forward); yaw turns about +Y, counter-clockwise seen from above (toward -X); pitch turns up. Pitch is held to
// ±AIM_PITCH_LIMIT by the encoding and by every decode, so any bits another machine sends look somewhere defined, never
// straight up or down. Decoding is `sin_cos` and multiplies: the sim never needs atan2 to use an aim.
Aim :: struct {
	yaw:   u16,
	pitch: i16,
}

// The most an Aim pitches up or down, in turns: 63/256 (88.6°), short of vertical so the look always has a heading. A
// camera rig clamps its own pitch to it (`AIM_PITCH_LIMIT * TAU` radians), or near vertical its crosshair is off the
// shot.
AIM_PITCH_LIMIT :: 0.24609375

// AIM_PITCH_LIMIT in Aim steps.
@(private)
PITCH_LIMIT_STEPS :: 16128

// The Aim of a yaw and a pitch in turns, each rounded to the nearest step: any yaw, wrapped into one turn; the pitch
// clamped to ±AIM_PITCH_LIMIT. A NaN reads as 0; an infinite yaw as 0, an infinite pitch as the limit.
aim :: proc "contextless" (yaw_turns, pitch_turns: f32) -> Aim {
	yaw: f32 = 0
	if abs(yaw_turns) < WHOLE_FROM do yaw = yaw_turns - floor(yaw_turns) // [0, 1]
	pitch: f32 = 0
	if pitch_turns == pitch_turns do pitch = pitch_turns // clamped to the limit as steps, below
	return {
		yaw   = u16(to_i32_clamped(round(yaw * 65536), 0, 65536) & 0xFFFF), // a turn wraps to 0
		pitch = i16(to_i32_clamped(round(pitch * 65536), -PITCH_LIMIT_STEPS, PITCH_LIMIT_STEPS)),
	}
}

// The Aim looking along `dir` (any length; zero, or NaN: a zero Aim, looking forward). For scripts and bots: it uses
// atan2, so tick code never needs it.
aim_toward :: proc "contextless" (dir: [3]f32) -> Aim {
	if !(length_sq(dir) > 0.000000000001) do return {}
	return aim(atan2_turns(0 - dir.x, 0 - dir.z), atan2_turns(dir.y, length2(dir.xz)))
}

// The yaw in turns, [0, 1).
aim_yaw :: #force_inline proc "contextless" (look: Aim) -> f32 {
	return f32(look.yaw) / 65536
}

// The pitch in turns, within ±AIM_PITCH_LIMIT (bits past the limit read as the limit).
aim_pitch :: #force_inline proc "contextless" (look: Aim) -> f32 {
	steps := i32(look.pitch)
	if steps > PITCH_LIMIT_STEPS do steps = PITCH_LIMIT_STEPS
	if steps < -PITCH_LIMIT_STEPS do steps = -PITCH_LIMIT_STEPS
	return f32(steps) / 65536
}

// The unit vector the aim looks along: {-sin yaw · cos pitch, sin pitch, -cos yaw · cos pitch}. Level, at every
// eighth of a turn of yaw it is exactly DIR8's values, zeros +0.
aim_vec :: proc "contextless" (look: Aim) -> [3]f32 {
	sin_yaw, cos_yaw := sin_cos(aim_yaw(look))
	sin_pitch, cos_pitch := sin_cos(aim_pitch(look))
	return {0 - sin_yaw * cos_pitch, sin_pitch, 0 - cos_yaw * cos_pitch}
}

// The aim's heading on the floor (XZ), unit length whatever the pitch: `forward` is where it faces, `right` 90°
// clockwise from it seen from above. What a local stick (strafe, forward) is turned by: `right * stick.x + forward * stick.y`.
aim_flat :: proc "contextless" (look: Aim) -> (forward, right: [3]f32) {
	sin_yaw, cos_yaw := sin_cos(aim_yaw(look))
	return {0 - sin_yaw, 0, 0 - cos_yaw}, {cos_yaw, 0, 0 - sin_yaw}
}

// The aim as a unit quaternion (x, y, z, w) for anything that looks along -Z (a Camera3D, a node's forward): the yaw
// about +Y, then the pitch about the turned +X (Godot's YXZ Euler order, rotation (pitch, yaw, 0) in turns). It turns
// -Z onto `aim_vec` and +X onto `aim_flat`'s right. A model faces +Z: `aim_quat_model`.
aim_quat :: proc "contextless" (look: Aim) -> [4]f32 {
	sin_yaw, cos_yaw := sin_cos(aim_yaw(look) * 0.5)
	sin_pitch, cos_pitch := sin_cos(aim_pitch(look) * 0.5)
	return {cos_yaw * sin_pitch, sin_yaw * cos_pitch, 0 - sin_yaw * sin_pitch, cos_yaw * cos_pitch}
}

// The aim as a unit quaternion (x, y, z, w) for a model, which faces +Z (Godot's MODEL_FRONT; `quat_yaw`'s
// convention): it turns +Z onto `aim_vec` and -X (MODEL_RIGHT) onto `aim_flat`'s right. A head or a gun: level, the
// same rotation as `quat_yaw` of the forward. `aim_quat` turned a half turn about its own +Y.
aim_quat_model :: proc "contextless" (look: Aim) -> [4]f32 {
	sin_yaw, cos_yaw := sin_cos(aim_yaw(look) * 0.5)
	sin_pitch, cos_pitch := sin_cos(aim_pitch(look) * 0.5)
	return {sin_yaw * sin_pitch, cos_yaw * cos_pitch, cos_yaw * sin_pitch, 0 - sin_yaw * cos_pitch}
}
