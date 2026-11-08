package view

import "core:math"

Pose :: struct {
	pos: [3]f32,
	rot: [4]f32, // unit quaternion (x, y, z, w)
}

IDENTITY :: [4]f32{0, 0, 0, 1}

Smoothing :: struct {
	// Time constant of the error decay: after `tau_s` a correction has shrunk to 1/e (37%), after 3 tau to 5%.
	// 0 disables smoothing (corrections snap).
	tau_s:         f32,
	// A correction or a tick-to-tick move longer than this (metres) snaps instead of smoothing/interpolating.
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

track_reset :: proc(t: ^Track) {
	t^ = {}
}

// Records the sim pose at `tick`. Pushing a tick that is already in the history (a re-simulation after a
// rollback) overwrites it; the difference goes into the error offset, so the display doesn't jump.
track_push :: proc(t: ^Track, tick: u32, pose: Pose, s := SMOOTHING_DEFAULT) {
	pose := pose
	pose.rot = qnormalize(pose.rot)
	for i in 0 ..< t.n {
		smp := &t.hist[(t.head - 1 - u32(i)) & 3]
		if smp.tick != tick do continue
		d := smp.pose.pos - pose.pos
		if s.tau_s > 0 && t.has_out {
			if length(d) > s.teleport_dist {
				t.err_pos, t.err_rot = {}, IDENTITY
			} else {
				t.err_pos += d
				t.err_rot = qnormalize(qmul(err_rot_or_identity(t), qmul(smp.pose.rot, qconj(pose.rot))))
			}
		}
		smp.pose = pose
		// Newer samples were predicted from the old one; drop them (the sim republishes them).
		t.head -= u32(i)
		t.n -= i
		return
	}
	if t.n > 0 && tick < t.hist[(t.head - 1) & 3].tick {
		// Older than the newest without being in the history: a rollback past it; start over from here.
		t.n = 0
	}
	t.hist[t.head & 3] = {tick, pose}
	t.head += 1
	t.n = min(t.n + 1, len(t.hist))
}

@(private)
err_rot_or_identity :: proc(t: ^Track) -> [4]f32 {
	return t.err_rot == {} ? IDENTITY : t.err_rot
}

// The pose of a sample at `tick`, if the history has it.
track_at :: proc(t: ^Track, tick: u32) -> (Pose, bool) {
	for i in 0 ..< t.n {
		smp := &t.hist[(t.head - 1 - u32(i)) & 3]
		if smp.tick == tick do return smp.pose, true
	}
	return {}, false
}

// The pose to display: between ticks `tick - 1` and `tick` at `alpha`, plus the decaying correction error.
// `dt_s` is the render frame's duration (drives the decay).
track_sample :: proc(t: ^Track, tick: u32, alpha: f32, dt_s: f32, s := SMOOTHING_DEFAULT) -> Pose {
	cur, ok := track_at(t, tick)
	if !ok {
		if t.n == 0 do return t.out
		cur = t.hist[(t.head - 1) & 3].pose // newest we have
	}
	base := cur
	if prev, has_prev := track_at(t, tick - 1); has_prev && ok {
		if length(cur.pos - prev.pos) <= s.teleport_dist {
			base.pos = prev.pos + (cur.pos - prev.pos) * alpha
			base.rot = nlerp(prev.rot, cur.rot, alpha)
		}
	}
	if s.tau_s > 0 {
		k := math.exp(-max(dt_s, 0) / s.tau_s)
		t.err_pos *= k
		t.err_rot = nlerp(IDENTITY, err_rot_or_identity(t), k)
		if length(t.err_pos) < 1e-4 do t.err_pos = {}
	} else {
		t.err_pos, t.err_rot = {}, IDENTITY
	}
	out := Pose{base.pos + t.err_pos, qnormalize(qmul(err_rot_or_identity(t), base.rot))}
	t.out = out
	t.has_out = true
	return out
}

// ---- small vector and quaternion helpers (render side)

length :: proc(v: [3]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

lerp3 :: #force_inline proc(a, b: [3]f32, t: f32) -> [3]f32 {
	return a + (b - a) * t
}

qconj :: proc(q: [4]f32) -> [4]f32 {
	return {-q.x, -q.y, -q.z, q.w}
}

qmul :: proc(a, b: [4]f32) -> [4]f32 {
	return {
		a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
		a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
		a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
		a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
	}
}

qnormalize :: proc(q: [4]f32) -> [4]f32 {
	n := q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
	if n < 1e-12 do return IDENTITY
	return q * (1 / math.sqrt(n))
}

// Normalized lerp along the shorter arc.
nlerp :: proc(a, b: [4]f32, t: f32) -> [4]f32 {
	b := b
	if a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w < 0 do b = -b
	return qnormalize(a + (b - a) * t)
}

// Rotation about +Y by `yaw` radians (Godot's up axis).
quat_yaw :: proc(yaw: f32) -> [4]f32 {
	return {0, math.sin(yaw * 0.5), 0, math.cos(yaw * 0.5)}
}

// The yaw (radians about +Y) of a rotation.
yaw_of :: proc(q: [4]f32) -> f32 {
	return math.atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.x * q.x))
}
