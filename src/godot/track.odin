package godot

import "core:math"

// A position and rotation a view is shown at.
Pose :: struct {
	pos: [3]f32,
	rot: [4]f32, // unit quaternion (x, y, z, w)
}

IDENTITY :: [4]f32{0, 0, 0, 1}

// How a view's track smooths rollback corrections: the error offset decays as exp(-dt / tau_s), and a jump longer than
// teleport_dist snaps.
Smoothing :: struct {
	// Time constant of the error decay: after `tau_s` a correction has shrunk to 1/e (37%), after 3 tau to 5%.
	// 0 disables smoothing (corrections snap).
	tau_s:         f32,
	// A correction or a tick-to-tick move longer than this (in the pushed units: unified:godot's are sim units, the
	// default suits metres) snaps instead of smoothing/interpolating.
	teleport_dist: f32,
}

SMOOTHING_DEFAULT :: Smoothing {
	tau_s         = 0.1,
	teleport_dist = 4,
}

@(private)
Sample :: struct {
	tick: u32,
	pose: Pose,
}

// A view's pose history: the sim poses of the newest ticks, plus the decaying correction offset.
Track :: struct {
	hist:    [4]Sample, // ring, newest at hist[(head - 1) & 3]
	head:    u32,
	n:       int,
	err_pos: [3]f32, // display = interpolated sim pose + error (a rollback correction being smoothed out)
	err_rot: [4]f32,
	out:     Pose, // last displayed pose
	has_out: bool,
}

// Records the sim pose at `tick`. Pushing a tick that is already in the history (a re-simulation after a
// rollback) overwrites it; the difference goes into the error offset, so the display doesn't jump.
track_push :: proc(track: ^Track, tick: u32, pose: Pose, smoothing := SMOOTHING_DEFAULT) {
	pose := pose
	pose.rot = qnormalize(pose.rot)
	for i in 0 ..< track.n {
		sample := &track.hist[(track.head - 1 - u32(i)) & 3]
		if sample.tick != tick do continue
		correction := sample.pose.pos - pose.pos
		if smoothing.tau_s > 0 && track.has_out {
			if length(correction) > smoothing.teleport_dist {
				track.err_pos, track.err_rot = {}, IDENTITY
			} else {
				track.err_pos += correction
				track.err_rot = qnormalize(qmul(err_rot_or_identity(track), qmul(sample.pose.rot, qconj(pose.rot))))
			}
		}
		sample.pose = pose
		// Newer samples were predicted from the old one; drop them (the sim republishes them).
		track.head -= u32(i)
		track.n -= i
		return
	}
	if track.n > 0 && tick < track.hist[(track.head - 1) & 3].tick {
		// Older than the newest without being in the history: a rollback past it; start over from here.
		track.n = 0
	}
	track.hist[track.head & 3] = {tick, pose}
	track.head += 1
	track.n = min(track.n + 1, len(track.hist))
}

// Records the pose at tick - 1 before a new `tick` (`prev`, has_prev false: unknown). After a rollback it is the
// corrected one: if the history has tick - 1 the difference goes into the error offset. If the history lacks tick - 1
// (the renderer skipped a frame, or the sim published several ticks at once), the last shown pose starts it instead,
// with `prev` as its correction: the display never jumps, it glides.
track_push_prev :: proc(track: ^Track, tick: u32, prev: Pose, has_prev: bool, smoothing := SMOOTHING_DEFAULT) {
	if _, known := track_at(track, tick - 1); !known && track.has_out && track.n > 0 {
		start := track.out // the error offset is in it already
		track.err_pos, track.err_rot = {}, IDENTITY
		track_push(track, tick - 1, start, smoothing)
	}
	if has_prev do track_push(track, tick - 1, prev, smoothing)
}

@(private)
err_rot_or_identity :: proc(track: ^Track) -> [4]f32 {
	return track.err_rot == {} ? IDENTITY : track.err_rot
}

// The pose of a sample at `tick`, if the history has it.
track_at :: proc(track: ^Track, tick: u32) -> (Pose, bool) {
	for i in 0 ..< track.n {
		sample := &track.hist[(track.head - 1 - u32(i)) & 3]
		if sample.tick == tick do return sample.pose, true
	}
	return {}, false
}

// The pose to display: between ticks `tick - 1` and `tick` at `alpha`, plus the decaying correction error.
// `dt_s` is the render frame's duration (drives the decay).
track_sample :: proc(track: ^Track, tick: u32, alpha: f32, dt_s: f32, smoothing := SMOOTHING_DEFAULT) -> Pose {
	return track_sample_decayed(track, tick, alpha, track_decay(dt_s, smoothing), smoothing)
}

// How much of a correction is left after a render frame of `dt_s`: the same for every view in a frame.
@(private)
track_decay :: proc(dt_s: f32, smoothing := SMOOTHING_DEFAULT) -> f32 {
	return smoothing.tau_s > 0 ? math.exp(-max(dt_s, 0) / smoothing.tau_s) : 0
}

// track_sample with the frame's track_decay computed once for all views.
@(private)
track_sample_decayed :: proc(
	track: ^Track,
	tick: u32,
	alpha: f32,
	decay: f32,
	smoothing := SMOOTHING_DEFAULT,
) -> Pose {
	current, ok := track_at(track, tick)
	if !ok {
		if track.n == 0 do return track.out
		current = track.hist[(track.head - 1) & 3].pose // newest we have
	}
	base := current
	if prev, has_prev := track_at(track, tick - 1); has_prev && ok {
		if length(current.pos - prev.pos) <= smoothing.teleport_dist {
			base.pos = prev.pos + (current.pos - prev.pos) * alpha
			base.rot = nlerp(prev.rot, current.rot, alpha)
		}
	}
	if smoothing.tau_s > 0 {
		track.err_pos *= decay
		track.err_rot = nlerp(IDENTITY, err_rot_or_identity(track), decay)
		if length(track.err_pos) < 1e-4 do track.err_pos = {}
	} else {
		track.err_pos, track.err_rot = {}, IDENTITY
	}
	out := Pose{base.pos + track.err_pos, qnormalize(qmul(err_rot_or_identity(track), base.rot))}
	track.out = out
	track.has_out = true
	return out
}

// ---- small vector and quaternion helpers (render side)

// The Euclidean length of a vector.
length :: proc(vec: [3]f32) -> f32 {
	return math.sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
}

// Linear interpolation between two positions (t 0: a, 1: b).
@(private)
lerp3 :: #force_inline proc(a, b: [3]f32, t: f32) -> [3]f32 {
	return a + (b - a) * t
}

// The conjugate of a quaternion: the inverse rotation of a unit quaternion.
@(private)
qconj :: proc(q: [4]f32) -> [4]f32 {
	return {-q.x, -q.y, -q.z, q.w}
}

// The Hamilton product: the rotation `b` followed by `a`.
qmul :: proc(a, b: [4]f32) -> [4]f32 {
	return {
		a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
		a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
		a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
		a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
	}
}

// Scales a quaternion to unit length; a near-zero one becomes the identity (the zero rotation a game leaves unset).
@(private)
qnormalize :: proc(q: [4]f32) -> [4]f32 {
	length_sq := q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
	if length_sq < 1e-12 do return IDENTITY
	return q * (1 / math.sqrt(length_sq))
}

// Normalized lerp along the shorter arc.
@(private)
nlerp :: proc(a, b: [4]f32, t: f32) -> [4]f32 {
	b := b
	if a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w < 0 do b = -b
	return qnormalize(a + (b - a) * t)
}

// The yaw (radians about +Y) of a rotation.
yaw_of :: proc(q: [4]f32) -> f32 {
	return math.atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.x * q.x))
}

// Rotation about +Z by `angle` radians: a 2D angle (Godot's Node2D.rotation: 0 = +x, positive turns +x toward +y).
quat_angle_2d :: proc(angle: f32) -> [4]f32 {
	return {0, 0, math.sin(angle * 0.5), math.cos(angle * 0.5)}
}

// The 2D angle (radians about +Z) of a rotation.
angle_2d_of :: proc(q: [4]f32) -> f32 {
	return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
}
