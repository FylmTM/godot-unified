// Kinematic paths (src/physics/README.md, Kinematic paths): a platform's pose as a pure function of its phase tick, and
// the drive that makes a kinematic body follow it without drift.
package physics

import box3d "box3d:bindings"
import "unified:dmath"
import "unified:sim"

MAX_PATH_POINTS :: 16

// How a path runs through its points.
Path_Mode :: enum u8 {
	Ping_Pong, // 0 → n-1 → 0 → ...
	Loop, // 0 → n-1, then back to 0 along seconds[n-1], and again
	Once, // 0 → n-1, then stays there
}

// How a path moves along each leg between two points.
Path_Ease :: enum u8 {
	Linear,
	Smooth, // dmath.smoothstep on every leg: 3t² − 2t³
	Curve, // Path.curve on every leg: progress through the leg (0..1) to how far along it (dmath.curve_sample)
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
	curve:   dmath.Curve, // ease .Curve's (a level marker's Curve: level.prop_curve)
}


// One leg of the cycle: wait at `from`, then travel to `to`.
@(private)
Leg :: struct {
	from, to:     int,
	wait, travel: u32,
}

@(private)
path_leg :: proc(path: ^Path, leg_index: int, tick_hz: int) -> (leg: Leg, ok: bool) {
	count := int(path.count)
	switch path.mode {
	case .Once:
		if leg_index >= count - 1 do return
		leg = {
			leg_index,
			leg_index + 1,
			sim.ticks(path.wait_s[leg_index], tick_hz),
			sim.ticks(path.seconds[leg_index], tick_hz),
		}
	case .Loop:
		if leg_index >= count do return
		leg = {
			leg_index,
			(leg_index + 1) % count,
			sim.ticks(path.wait_s[leg_index], tick_hz),
			sim.ticks(path.seconds[leg_index], tick_hz),
		}
	case .Ping_Pong:
		if leg_index >= 2 * (count - 1) do return
		if leg_index < count - 1 {
			leg = {
				leg_index,
				leg_index + 1,
				sim.ticks(path.wait_s[leg_index], tick_hz),
				sim.ticks(path.seconds[leg_index], tick_hz),
			}
		} else {
			i := 2 * (count - 1) - leg_index // n-1 down to 1
			leg = {i, i - 1, sim.ticks(path.wait_s[i], tick_hz), sim.ticks(path.seconds[i - 1], tick_hz)}
		}
	}
	return leg, true
}

// Ticks in one cycle (Once: until it arrives).
path_duration_ticks :: proc(path: ^Path, tick_hz: int) -> u32 {
	total: u32
	for k := 0;; k += 1 {
		leg := path_leg(path, k, tick_hz) or_break
		total += leg.wait + leg.travel
	}
	return total
}

// The position at `phase_tick` ticks into the path (cycles repeat; Once holds the last point).
// Exact at the points: a wait returns the point itself.
path_sample :: proc(path: ^Path, phase_tick: u32, tick_hz: int) -> [3]f32 {
	count := int(path.count)
	if count == 0 do return {}
	if count == 1 do return path.points[0]
	total := path_duration_ticks(path, tick_hz)
	if total == 0 do return path.points[0]
	tick := phase_tick
	if path.mode == .Once {
		if tick >= total do return path.points[count - 1]
	} else {
		tick %= total
	}
	for k := 0;; k += 1 {
		leg := path_leg(path, k, tick_hz) or_break
		if tick < leg.wait do return path.points[leg.from]
		tick -= leg.wait
		if tick < leg.travel {
			progress := f32(tick) / f32(leg.travel)
			switch path.ease {
			case .Linear:
			case .Smooth:
				progress = dmath.smoothstep(0, 1, progress)
			case .Curve:
				progress = dmath.curve_sample(path.curve, progress)
			}
			a := path.points[leg.from]
			b := path.points[leg.to]
			return {a.x + (b.x - a.x) * progress, a.y + (b.y - a.y) * progress, a.z + (b.z - a.z) * progress}
		}
		tick -= leg.travel
	}
	return path.points[count - 1]
}

// Sets a kinematic body's velocity so the next step lands it on `target`, measured from where it
// is now: no drift, and exactly still during waits.
drive_kinematic :: proc(world: ^World, ref: Body_Ref, target: [3]f32) {
	id := body_id(world, ref)
	pos := transmute([3]f32)box3d.Body_GetPosition(id)
	hz := f32(world.tick_hz)
	box3d.Body_SetLinearVelocity(
		id,
		transmute(box3d.Vec3)[3]f32{(target.x - pos.x) * hz, (target.y - pos.y) * hz, (target.z - pos.z) * hz},
	)
	box3d.Body_SetAngularVelocity(id, transmute(box3d.Vec3)[3]f32{})
}
