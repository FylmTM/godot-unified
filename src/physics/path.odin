// Kinematic paths (src/physics/SPEC.md): a platform's pose as a pure function of its phase tick, and the
// drive that makes a kinematic body follow it without drift.
package physics

import b3 "../box3d"

MAX_PATH_POINTS :: 16

Path_Mode :: enum u8 {
	Ping_Pong, // 0 → n-1 → 0 → ...
	Loop, // 0 → n-1, then back to 0 along seconds[n-1], and again
	Once, // 0 → n-1, then stays there
}

Path_Ease :: enum u8 {
	Linear,
	Smooth, // smoothstep 3t² − 2t³ on every leg
}

// Level data (outside the block). Point i waits wait_s[i] when reached, then travels to the next
// point in seconds[i] (Ping_Pong's way back uses the same leg times). Times round to whole ticks.
Path :: struct {
	points:  [MAX_PATH_POINTS][3]f32,
	seconds: [MAX_PATH_POINTS]f32,
	wait_s:  [MAX_PATH_POINTS]f32,
	count:   u8,
	mode:    Path_Mode,
	ease:    Path_Ease,
}

@(private)
ticks_of :: #force_inline proc(seconds: f32, tick_hz: int) -> u32 {
	return u32(seconds * f32(tick_hz) + 0.5)
}

// One leg of the cycle: wait at `from`, then travel to `to`.
@(private)
Leg :: struct {
	from, to:     int,
	wait, travel: u32,
}

@(private)
path_leg :: proc(p: ^Path, k: int, tick_hz: int) -> (leg: Leg, ok: bool) {
	n := int(p.count)
	switch p.mode {
	case .Once:
		if k >= n - 1 do return
		leg = {k, k + 1, ticks_of(p.wait_s[k], tick_hz), ticks_of(p.seconds[k], tick_hz)}
	case .Loop:
		if k >= n do return
		leg = {k, (k + 1) % n, ticks_of(p.wait_s[k], tick_hz), ticks_of(p.seconds[k], tick_hz)}
	case .Ping_Pong:
		if k >= 2 * (n - 1) do return
		if k < n - 1 {
			leg = {k, k + 1, ticks_of(p.wait_s[k], tick_hz), ticks_of(p.seconds[k], tick_hz)}
		} else {
			i := 2 * (n - 1) - k // n-1 down to 1
			leg = {i, i - 1, ticks_of(p.wait_s[i], tick_hz), ticks_of(p.seconds[i - 1], tick_hz)}
		}
	}
	return leg, true
}

// Ticks in one cycle (Once: until it arrives).
path_duration_ticks :: proc(p: ^Path, tick_hz: int) -> u32 {
	total: u32
	for k := 0;; k += 1 {
		leg := path_leg(p, k, tick_hz) or_break
		total += leg.wait + leg.travel
	}
	return total
}

// The position at `phase_tick` ticks into the path (cycles repeat; Once holds the last point).
// Exact at the points: a wait returns the point itself.
path_sample :: proc(p: ^Path, phase_tick: u32, tick_hz: int) -> [3]f32 {
	n := int(p.count)
	if n == 0 do return {}
	if n == 1 do return p.points[0]
	total := path_duration_ticks(p, tick_hz)
	if total == 0 do return p.points[0]
	t := phase_tick
	if p.mode == .Once {
		if t >= total do return p.points[n - 1]
	} else {
		t %= total
	}
	for k := 0;; k += 1 {
		leg := path_leg(p, k, tick_hz) or_break
		if t < leg.wait do return p.points[leg.from]
		t -= leg.wait
		if t < leg.travel {
			u := f32(t) / f32(leg.travel)
			if p.ease == .Smooth do u = u * u * (3 - 2 * u)
			a := p.points[leg.from]
			b := p.points[leg.to]
			return {a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u}
		}
		t -= leg.travel
	}
	return p.points[n - 1]
}

// Sets a kinematic body's velocity so the next step lands it on `target`, measured from where it
// is now: no drift, and exactly still during waits. `tick_hz` is the step rate.
drive_kinematic :: proc(w: ^World, r: Body_Ref, target: [3]f32, tick_hz: int) {
	id := body_id(w, r)
	p := b3.Body_GetPosition(id)
	hz := f32(tick_hz)
	b3.Body_SetLinearVelocity(id, {(target.x - p.x) * hz, (target.y - p.y) * hz, (target.z - p.z) * hz})
	b3.Body_SetAngularVelocity(id, {})
}
