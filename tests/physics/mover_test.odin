// spec/physics.md: the dynamic mover, joints under rollback, queries, hit events and kinematic paths.
// The rig is a small game run through the real harness (sim.create/step/restore/checksum), so joint
// churn, platforms and hit events are checked the way a game uses them.
package test_physics

import "core:testing"

import b3 "unified:box3d"
import "unified:physics"
import "unified:sim"

HZ :: 64
DT: f32 : 1.0 / HZ

CAT_STATIC :: u64(1 << 0)
CAT_MOVER :: u64(1 << 1)
CAT_BOX :: u64(1 << 2)
CAT_PLATFORM :: u64(1 << 3)

MOVER := physics.Mover_Def {
	radius                 = 0.3,
	half_height            = 0.5,
	density                = 200,
	category               = CAT_MOVER,
	material               = 7,
	hit_events             = true,
	max_speed              = 6,
	min_speed              = 0.1,
	stop_speed             = 3,
	accelerate             = 20,
	friction               = 8,
	air_steer              = 0.25,
	jump_speed             = 7,
	gravity_scale          = 1.5,
	max_ground_force       = 6000,
	max_air_force          = 1500,
	pogo_rest              = 0.9,
	pogo_hertz             = 3,
	pogo_damping           = 0.8,
	pogo_compression_scale = 100,
	pogo_tension_scale     = 100,
	min_ground_normal_y    = 0.7,
	slide_s                = 0.2,
	coyote_s               = 0.125,
	jump_buffer_s          = 0.125,
}

// ---- world building

box :: proc(
	w: ^physics.World,
	pos, half: [3]f32,
	type: b3.BodyType = .staticBody,
	rot := b3.Quat{{0, 0, 0}, 1},
	cat := CAT_STATIC,
	density: f32 = 1,
	hit := false,
) -> b3.BodyId {
	bd := b3.DefaultBodyDef()
	bd.type = type
	bd.position = {pos.x, pos.y, pos.z}
	bd.rotation = rot
	if type == .kinematicBody do bd.enableSleep = false
	id := b3.CreateBody(w.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.density = density
	sd.filter.categoryBits = cat
	sd.enableHitEvents = hit
	h := b3.MakeBoxHull(half.x, half.y, half.z)
	b3.CreateHullShape(id, &sd, &h.base)
	return id
}

ground :: proc(w: ^physics.World) {
	box(w, {0, -0.5, 0}, {30, 0.5, 30})
}

new_world :: proc() -> ^physics.World {
	return physics.create({anchor = true})
}

step :: proc(w: ^physics.World) {
	b3.World_Step(w.id, DT, 4)
}

// ---- the rig: two movers, boxes, a platform on a path, a hold joint that comes and goes

Rig_Input :: struct {
	mx, mz: i8,
	jump:   b8,
	_pad:   u8,
}

Rig :: struct {
	movers:   [2]physics.Mover,
	boxes:    [4]physics.Body_Ref,
	platform: physics.Body_Ref,
	hold:     physics.Joint_Ref,
	held:     u32, // box index + 1 (0: none)
	hits:     u32,
	jumps:    u32,
	prev:     [2]b8,
	_pad:     u16,
}

Rig_World :: struct {
	phys:    ^physics.World,
	extras:  [1]sim.Extra,
	scratch: [dynamic]physics.Hit_Event,
}

RIG_PATH := physics.Path {
	points = {0 = {0, 0.25, 6}, 1 = {6, 0.25, 6}, 2 = {6, 3, 6}},
	seconds = {0 = 1.5, 1 = 1},
	wait_s = {0 = 0.25, 1 = 0.25, 2 = 0.5},
	count = 3,
	mode = .Ping_Pong,
	ease = .Smooth,
}

Rig_Game :: sim.Game(Rig, Rig_Input, Rig_World, 2)
Rig_Inputs :: sim.Inputs(Rig_Input, 2)

RIG := Rig_Game {
	name = "rig",
	version = "1",
	tick_hz = HZ,
	world_create = proc(seed: u64) -> ^Rig_World {
		rw := new(Rig_World)
		rw.phys = physics.create({anchor = true, hit_threshold = 1})
		ground(rw.phys)
		box(rw.phys, {-4, 0.15, 0}, {1, 0.15, 1}) // a step
		rw.extras[0] = physics.extra(rw.phys, Rig)
		return rw
	},
	world_destroy = proc(rw: ^Rig_World) {
		physics.destroy(rw.phys)
		delete(rw.scratch)
		free(rw)
	},
	extras = proc(rw: ^Rig_World) -> []sim.Extra {return rw.extras[:]},
	init = proc(s: ^Rig, rw: ^Rig_World, seed: u64) {
		w := rw.phys
		for &m, i in s.movers {
			physics.mover_create(w, &m, &MOVER, {f32(i) * 2, 1.2, 0})
		}
		for &b, i in s.boxes {
			s.boxes[i] = physics.ref_of(
				box(w, {f32(i) - 1.5, 0.5, 2}, {0.3, 0.3, 0.3}, .dynamicBody, cat = CAT_BOX, hit = true),
			)
			_ = b
		}
		s.platform = physics.ref_of(box(w, RIG_PATH.points[0], {1.5, 0.25, 1.5}, .kinematicBody, cat = CAT_PLATFORM))
	},
	tick = proc(s: ^Rig, rw: ^Rig_World, t: u32, inputs: ^Rig_Inputs, events: ^[dynamic]sim.Event) {
		w := rw.phys
		physics.drive_kinematic(w, s.platform, physics.path_sample(&RIG_PATH, t, HZ), HZ)
		for &m, i in s.movers {
			in_ := inputs.input[i]
			mv := [2]f32{f32(in_.mx) / 127, f32(in_.mz) / 127}
			if physics.mover_update(w, &m, &MOVER, mv, bool(in_.jump && !s.prev[i]), 1, DT) {
				s.jumps += 1
			}
			s.prev[i] = in_.jump
		}
		// Mover 0 grabs box (t / 40) % 4 for 25 ticks of every 40: a motor joint created and
		// destroyed inside rollback windows.
		phase := t % 40
		if phase == 5 && s.hold == {} {
			b := s.boxes[(t / 40) % 4]
			jd := b3.DefaultMotorJointDef()
			jd.base.bodyIdA = physics.body_id(w, s.movers[0].body)
			jd.base.bodyIdB = physics.body_id(w, b)
			jd.base.localFrameA = {{0, 0.3, 0.9}, {{0, 0, 0}, 1}}
			jd.linearHertz = 6
			jd.linearDampingRatio = 1
			jd.maxSpringForce = 400
			jd.angularHertz = 4
			jd.angularDampingRatio = 1
			jd.maxSpringTorque = 50
			s.hold = physics.joint_ref_of(b3.CreateMotorJoint(w.id, &jd))
			s.held = (t / 40) % 4 + 1
		} else if phase == 30 && s.hold != {} {
			physics.destroy_joint(w, &s.hold)
			// throw it at mover 1
			b := s.boxes[s.held - 1]
			p := physics.position(w, b)
			q := physics.position(w, s.movers[1].body)
			physics.impulse(w, b, {(q.x - p.x) * 2, 3, (q.z - p.z) * 2})
			s.held = {}
		}
		step(w)
		clear(&rw.scratch)
		physics.hit_events(w, &rw.scratch)
		s.hits += u32(len(rw.scratch))
	},
}

rig_input :: proc(slot: int, t: u32) -> Rig_Input {
	x := u32(slot + 1) * 0x85EBCA77 ~ (t / 12) * 0xC2B2AE3D
	x ~= x >> 15
	x *= 0x2C1B3C6D
	x ~= x >> 12
	return {mx = i8(x % 255) - 127, mz = i8((x >> 8) % 255) - 127, jump = b8((x >> 16) % 4 == 0)}
}

rig_inputs :: proc(t: u32) -> Rig_Inputs {
	ins := Rig_Inputs {
		present = {0, 1},
	}
	for i in 0 ..< 2 {
		ins.input[i] = rig_input(i, t)
	}
	return ins
}

@(test)
rig_synctest_with_joints :: proc(t: ^testing.T) {
	TICKS :: 640
	WINDOW :: 8
	s := sim.create(&RIG, 1)
	defer sim.destroy(s)
	forward: [TICKS + 1]u64
	mismatches := 0
	for tk in u32(1) ..= TICKS {
		ins := rig_inputs(tk)
		sim.step(s, &ins)
		forward[tk] = sim.checksum(s)
		if tk < WINDOW do continue
		testing.expect(t, sim.restore(s, tk - WINDOW))
		testing.expect(t, physics.check_refs(s.world.phys, &s.state))
		for u in tk - WINDOW + 1 ..= tk {
			ins2 := rig_inputs(u)
			sim.step(s, &ins2)
			if sim.checksum(s) != forward[u] do mismatches += 1
		}
	}
	testing.expect_value(t, mismatches, 0)
	// The rig really did what it is for.
	testing.expect(t, s.state.jumps > 5)
	testing.expect(t, s.state.hits > 0)

	// A portable snapshot loads into a fresh world and continues bit-exactly.
	snap := sim.snapshot_encode(s, TICKS)
	defer delete(snap)
	s2, err := sim.from_snapshot(&RIG, snap)
	testing.expect_value(t, err, sim.Snap_Error.None)
	if s2 == nil do return
	defer sim.destroy(s2)
	for tk in u32(TICKS + 1) ..= TICKS + 64 {
		a := rig_inputs(tk)
		b := a
		sim.step(s, &a)
		sim.step(s2, &b)
		testing.expect_value(t, sim.checksum(s2), sim.checksum(s))
	}
}

// ---- mover behaviour

Solo :: struct {
	w: ^physics.World,
	m: physics.Mover,
}

solo :: proc(pos: [3]f32) -> Solo {
	s := Solo {
		w = new_world(),
	}
	ground(s.w)
	physics.mover_create(s.w, &s.m, &MOVER, pos)
	return s
}

run :: proc(s: ^Solo, ticks: int, move := [2]f32{}, jump_at := -1) -> (peak: f32) {
	peak = -1e9
	for i in 0 ..< ticks {
		physics.mover_update(s.w, &s.m, &MOVER, move, i == jump_at, 1, DT)
		step(s.w)
		peak = max(peak, physics.position(s.w, s.m.body).y)
	}
	return
}

@(test)
mover_stands_still :: proc(t: ^testing.T) {
	s := solo({0, 1.5, 0})
	defer physics.destroy(s.w)
	run(&s, 128)
	testing.expect(t, physics.mover_grounded(&s.m))
	a := physics.position(s.w, s.m.body)
	run(&s, 640)
	b := physics.position(s.w, s.m.body)
	testing.expectf(t, abs(b.x - a.x) + abs(b.y - a.y) + abs(b.z - a.z) < 1e-3, "drifted %v -> %v", a, b)
	// The pogo holds the capsule's bottom about pogo_rest above the floor.
	testing.expectf(t, b.y > 1.1 && b.y < 1.6, "height %v", b.y)
}

@(test)
mover_walks_and_jumps :: proc(t: ^testing.T) {
	s := solo({0, 1.5, 0})
	defer physics.destroy(s.w)
	run(&s, 64)
	run(&s, 64, {1, 0})
	v := physics.velocity(s.w, s.m.body)
	testing.expectf(t, v.x > 5.5 && v.x < 6.1, "walk speed %v", v.x)
	y0 := physics.position(s.w, s.m.body).y
	peak := run(&s, 96, {}, 2)
	// v²/2g with gravity scale 1.5: 1.66 m (the pogo adds a little at take-off).
	testing.expectf(t, peak - y0 > 1.3 && peak - y0 < 2.2, "jump height %v", peak - y0)
	run(&s, 64)
	testing.expect(t, physics.mover_grounded(&s.m))
}

@(test)
mover_climbs_a_step :: proc(t: ^testing.T) {
	s := solo({0, 1.5, 0})
	defer physics.destroy(s.w)
	box(s.w, {6, 0.15, 0}, {4, 0.15, 2}) // a 0.3 m step at x = 2
	run(&s, 64)
	y0 := physics.position(s.w, s.m.body).y
	run(&s, 40, {1, 0})
	run(&s, 64)
	p := physics.position(s.w, s.m.body)
	testing.expectf(t, p.x > 2.5 && p.y - y0 > 0.25, "on the step: %v (from y %v)", p, y0)
}

@(test)
mover_slides_off_a_steep_slope :: proc(t: ^testing.T) {
	s := solo({0, 3, 0})
	defer physics.destroy(s.w)
	// 50° about z: (0, 0, sin 25°, cos 25°)
	box(s.w, {0, 1, 0}, {3, 0.2, 2}, rot = {{0, 0, 0.42261826}, 0.90630779})
	run(&s, 192)
	p := physics.position(s.w, s.m.body)
	testing.expectf(t, p.x > 1 || p.x < -1, "still on the slope at %v", p)
}

@(test)
mover_rides_platforms :: proc(t: ^testing.T) {
	s := solo({0, 1.6, 6})
	defer physics.destroy(s.w)
	plat := physics.ref_of(box(s.w, RIG_PATH.points[0], {1.5, 0.25, 1.5}, .kinematicBody, cat = CAT_PLATFORM))
	cycle := int(physics.path_duration_ticks(&RIG_PATH, HZ))
	worst: f32 = 0
	for i in 0 ..< 2 * cycle {
		physics.drive_kinematic(s.w, plat, physics.path_sample(&RIG_PATH, u32(i + 1), HZ), HZ)
		physics.mover_update(s.w, &s.m, &MOVER, {}, false, 1, DT)
		step(s.w)
		if i > 32 {
			pp := physics.position(s.w, plat)
			mp := physics.position(s.w, s.m.body)
			d := max(abs(mp.x - pp.x), abs(mp.z - pp.z))
			worst = max(worst, d)
			testing.expectf(t, mp.y > pp.y + 0.5, "fell off at tick %d: mover %v, platform %v", i, mp, pp)
			if mp.y <= pp.y + 0.5 do return
		}
	}
	testing.expectf(t, worst < 0.6, "slipped %v m on the platform", worst)
}

@(test)
mover_is_pushed_and_stands_on_another :: proc(t: ^testing.T) {
	s := solo({0, 1.5, 0})
	defer physics.destroy(s.w)
	run(&s, 64)
	x0 := physics.position(s.w, s.m.body).x
	// A heavy box (86 kg, about the mover's mass) at 14 m/s: the drive's force cap gives way.
	b := physics.ref_of(box(s.w, {-3, 1.4, 0}, {0.3, 0.3, 0.3}, .dynamicBody, cat = CAT_BOX, density = 400))
	physics.set_velocity(s.w, b, {14, 0, 0})
	run(&s, 64)
	pushed := physics.position(s.w, s.m.body).x - x0
	testing.expectf(t, pushed > 0.1, "pushed only %v m", pushed)

	top: physics.Mover
	physics.mover_create(s.w, &top, &MOVER, physics.position(s.w, s.m.body) + [3]f32{0, 2.2, 0})
	for _ in 0 ..< 160 {
		physics.mover_update(s.w, &s.m, &MOVER, {}, false, 1, DT)
		physics.mover_update(s.w, &top, &MOVER, {}, false, 1, DT)
		step(s.w)
	}
	lo := physics.position(s.w, s.m.body)
	hi := physics.position(s.w, top.body)
	testing.expectf(t, hi.y - lo.y > 1.3, "not standing on the other mover: %v over %v", hi, lo)
	testing.expect(t, top.ground == physics.link(s.m.body))
}

@(test)
mover_limp_and_teleport :: proc(t: ^testing.T) {
	s := solo({0, 1.5, 0})
	defer physics.destroy(s.w)
	run(&s, 64)
	physics.mover_set_limp(s.w, &s.m, true)
	testing.expect(t, s.m.pogo == {})
	run(&s, 64, {1, 0}, 3) // input is ignored while limp
	testing.expect(t, abs(physics.position(s.w, s.m.body).x) < 0.01)
	physics.mover_set_limp(s.w, &s.m, false)
	physics.mover_teleport(s.w, &s.m, {5, 2, 5})
	run(&s, 96)
	p := physics.position(s.w, s.m.body)
	testing.expectf(t, abs(p.x - 5) < 0.01 && abs(p.z - 5) < 0.01, "teleported to %v", p)
	testing.expect(t, physics.mover_grounded(&s.m))
}

// ---- queries, events, refs

@(test)
queries_and_hit_events :: proc(t: ^testing.T) {
	w := physics.create({anchor = true, hit_threshold = 1})
	defer physics.destroy(w)
	ground(w)
	a := box(w, {0, 2, 0}, {0.5, 0.5, 0.5}, .dynamicBody, cat = CAT_BOX, hit = true)
	c := box(w, {3, 0.5, 0}, {0.5, 0.5, 0.5}, .dynamicBody, cat = CAT_BOX)
	// A ray from inside `a` skips it when told to, and finds the ground under it.
	h, ok := physics.ray_closest(w, {0, 2, 0}, {0, -5, 0}, {}, physics.link_of(a))
	testing.expect(t, ok && abs(h.point.y) < 1e-4 && h.normal.y > 0.99)
	h, ok = physics.ray_closest(w, {0, 2, 0}, {0, -5, 0})
	testing.expect(t, ok && h.body == physics.link_of(a))
	// Overlaps come back sorted by body index, once each.
	got: [dynamic]physics.Body_Link
	defer delete(got)
	physics.overlap_aabb(w, {-5, 0.2, -1}, {5, 3, 1}, &got, {mask = CAT_BOX})
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 do testing.expect(t, got[0].index1 < got[1].index1 && got[1] == physics.link_of(c))
	// `a` falls onto the ground: one hit event at ~6 m/s.
	evs: [dynamic]physics.Hit_Event
	defer delete(evs)
	for _ in 0 ..< 64 {
		step(w)
		physics.hit_events(w, &evs)
	}
	testing.expect(t, len(evs) >= 1)
	if len(evs) >= 1 do testing.expect(t, evs[0].speed > 3)
	// check_refs: stale refs are caught.
	Two :: struct {
		b: physics.Body_Ref,
		j: physics.Joint_Ref,
	}
	two := Two {
		b = physics.ref_of(c),
	}
	_ = physics.extra(w, Two)
	testing.expect(t, physics.check_refs(w, &two))
	b3.DestroyBody(c)
	testing.expect(t, !physics.check_refs(w, &two))
}

// ---- paths

@(test)
paths_sample_exactly :: proc(t: ^testing.T) {
	p := RIG_PATH
	// 0.25 s wait at 0, 1.5 s to 1, 0.25 s wait, 1 s to 2, 0.5 s wait, 1 s back to 1, 0.25 s wait, 1.5 s to 0.
	testing.expect_value(
		t,
		physics.path_duration_ticks(&p, HZ),
		u32((0.25 + 1.5 + 0.25 + 1 + 0.5 + 1 + 0.25 + 1.5) * HZ),
	)
	testing.expect(t, physics.path_sample(&p, 0, HZ) == p.points[0])
	testing.expect(t, physics.path_sample(&p, 16, HZ) == p.points[0]) // end of the wait
	testing.expect(t, physics.path_sample(&p, 16 + 96, HZ) == p.points[1]) // arrived
	testing.expect(t, physics.path_sample(&p, 16 + 96 + 16 + 64, HZ) == p.points[2])
	mid := physics.path_sample(&p, 16 + 48, HZ) // halfway along the first leg, smoothstep(0.5) = 0.5
	testing.expect_value(t, mid, [3]f32{3, 0.25, 6})
	total := physics.path_duration_ticks(&p, HZ)
	testing.expect(t, physics.path_sample(&p, total, HZ) == p.points[0]) // the cycle repeats
	once := p
	once.mode = .Once
	testing.expect(t, physics.path_sample(&once, 100000, HZ) == p.points[2])
	loop := p
	loop.mode = .Loop
	loop.seconds[2] = 2
	testing.expect_value(t, physics.path_duration_ticks(&loop, HZ), u32((0.25 + 1.5 + 0.25 + 1 + 0.5 + 2) * HZ))
}

@(test)
kinematic_drive_does_not_drift :: proc(t: ^testing.T) {
	w := new_world()
	defer physics.destroy(w)
	p := RIG_PATH
	plat := physics.ref_of(box(w, p.points[0], {1, 0.25, 1}, .kinematicBody, cat = CAT_PLATFORM))
	cycle := physics.path_duration_ticks(&p, HZ)
	worst: f32 = 0
	for i in u32(1) ..= 10 * cycle {
		target := physics.path_sample(&p, i, HZ)
		physics.drive_kinematic(w, plat, target, HZ)
		step(w)
		q := physics.position(w, plat)
		worst = max(worst, abs(q.x - target.x), abs(q.y - target.y), abs(q.z - target.z))
	}
	testing.expectf(t, worst < 1e-4, "kinematic body is %v m off its path", worst)
}
