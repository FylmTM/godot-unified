// src/physics/SPEC.md, "2D": bodies locked to the plane z = 0. The plane stays exact under contacts,
// impulses and continuous collision; 2D rotations convert to quaternions without trig; a top-down
// game (ships, rocks that split, walls, ray-cast bullets) rolls back and resumes from a portable image.
package test_physics

import "core:testing"

import b3 "unified:box3d_port"
import "unified:dmath"
import "unified:physics"
import "unified:sim"

CAT_SHIP :: u64(1 << 4)
CAT_ROCK :: u64(1 << 5)

DEPTH_2D :: f32(1) // z thickness of boxes and rock hulls
ARENA :: [2]f32{12, 8} // inner half extents of the walled arena

// Four static walls 0.5 m thick whose inner faces are at ±half.
arena_walls :: proc(w: ^physics.World, half: [2]f32) {
	T :: f32(0.25)
	walls := [4][2][2]f32 {
		{{0, -half.y - T}, {half.x + 2 * T, T}},
		{{0, half.y + T}, {half.x + 2 * T, T}},
		{{-half.x - T, 0}, {T, half.y}},
		{{half.x + T, 0}, {T, half.y}},
	}
	for wall in walls {
		bd := physics.body_def_2d(.staticBody, wall[0])
		id := b3.CreateBody(w.id, &bd)
		sd := b3.DefaultShapeDef()
		sd.filter.categoryBits = CAT_STATIC
		physics.box_2d(id, &sd, wall[1], DEPTH_2D)
	}
}

// An irregular heptagon of radius about 1; rock sizes 1..3 scale it.
ROCK_POINTS := [7][2]f32{{1, 0}, {0.62, 0.78}, {-0.2, 0.95}, {-0.9, 0.45}, {-0.85, -0.5}, {-0.15, -1}, {0.7, -0.68}}
ROCK_RADIUS := [5]f32{0, 0.5, 0.9, 1.5, 0.7} // by size; 4 is never at tick 0 (portable_image_carries_new_hulls)

rock_body :: proc(w: ^physics.World, pos, rot, vel: [2]f32, ang: f32, size: u32) -> physics.Body_Ref {
	bd := physics.body_def_2d(.dynamicBody, pos, rot)
	bd.linearVelocity = {vel.x, vel.y, 0}
	bd.angularVelocity = {0, 0, ang}
	id := b3.CreateBody(w.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.filter.categoryBits = CAT_ROCK
	pts: [len(ROCK_POINTS)][2]f32
	for p, i in ROCK_POINTS {
		pts[i] = p * ROCK_RADIUS[size]
	}
	_, ok := physics.polygon_2d(id, &sd, pts[:], DEPTH_2D)
	assert(ok)
	return physics.ref_of(id)
}

circle_body :: proc(
	w: ^physics.World,
	pos, vel: [2]f32,
	radius: f32,
	cat := CAT_SHIP,
	restitution: f32 = 0,
) -> physics.Body_Ref {
	bd := physics.body_def_2d(.dynamicBody, pos)
	bd.linearVelocity = {vel.x, vel.y, 0}
	id := b3.CreateBody(w.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.filter.categoryBits = cat
	sd.baseMaterial.restitution = restitution
	physics.circle_2d(id, &sd, radius)
	return physics.ref_of(id)
}

zero_g :: proc() -> ^physics.World {
	return physics.create({gravity = [3]f32{0, 0, 0}})
}

// Whether a dynamic body sits exactly on the plane: z, and the quaternion's x and y, are zero (±0).
on_plane :: proc(w: ^physics.World, r: physics.Body_Ref) -> bool {
	id := physics.body_id(w, r)
	p := b3.Body_GetPosition(id)
	q := b3.Body_GetRotation(id)
	return p.z == 0 && q.v.x == 0 && q.v.y == 0
}

// Whether a body's velocity stays in the plane: v.z, ω.x and ω.y are zero (±0) after a step (#87).
in_plane_velocity :: proc(w: ^physics.World, r: physics.Body_Ref) -> bool {
	id := physics.body_id(w, r)
	v := b3.Body_GetLinearVelocity(id)
	a := b3.Body_GetAngularVelocity(id)
	return v.z == 0 && a.x == 0 && a.y == 0
}

@(test)
plane_2d_stays_exact :: proc(t: ^testing.T) {
	w := zero_g()
	defer physics.destroy(w)
	arena_walls(w, ARENA)
	rng := sim.rng_seed(7)
	rnd :: proc(r: ^sim.Rng, lo, hi: f32) -> f32 {return lo + (hi - lo) * sim.rng_f32(r)}

	Kind :: enum {
		Circle,
		Box,
		Rock,
	}
	Item :: struct {
		body:   physics.Body_Ref,
		kind:   Kind,
		radius: f32,
	}
	items := make([dynamic]Item, context.temp_allocator)
	// A 8 × 5 grid of mixed bodies, 2.5 m apart, moving and spinning.
	for gy in 0 ..< 5 {
		for gx in 0 ..< 8 {
			pos := [2]f32{f32(gx) * 2.5 - 8.75, f32(gy) * 2.5 - 5}
			vel := [2]f32{rnd(&rng, -8, 8), rnd(&rng, -8, 8)}
			ang := rnd(&rng, -6, 6)
			rot := [2]f32{rnd(&rng, -1, 1), rnd(&rng, -1, 1)}
			kind := Kind((gx + gy) % 3)
			it := Item {
				kind = kind,
			}
			switch kind {
			case .Circle:
				it.radius = rnd(&rng, 0.3, 0.7)
				it.body = circle_body(w, pos, vel, it.radius, restitution = 0.5)
			case .Box:
				bd := physics.body_def_2d(.dynamicBody, pos, rot)
				bd.linearVelocity = {vel.x, vel.y, 0}
				id := b3.CreateBody(w.id, &bd)
				sd := b3.DefaultShapeDef()
				physics.box_2d(id, &sd, {rnd(&rng, 0.3, 0.8), rnd(&rng, 0.2, 0.6)}, DEPTH_2D)
				it.body = physics.ref_of(id)
			case .Rock:
				it.body = rock_body(w, pos, rot, vel, ang, 1 + u32(gx % 3))
			}
			physics.set_velocity_2d(w, it.body, vel, ang)
			append(&items, it)
		}
	}
	// Two fast circles at the walls: 60 m/s is about 0.94 m a tick against 0.5 m walls, so only
	// continuous collision keeps them in.
	fast := [2]physics.Body_Ref {
		circle_body(w, {0, 6.8}, {60, 0}, 0.25, restitution = 0.8),
		circle_body(w, {0, -6.8}, {-45, 33}, 0.25, restitution = 0.8),
	}
	for f in fast {
		append(&items, Item{f, .Circle, 0.25})
	}

	off_plane, off_velocity, escaped := 0, 0, 0
	sink: f32
	bounced := false
	for tk in 1 ..= 640 { 	// 10 s
		if tk % 16 == 0 {
			it := items[(tk / 16) % len(items)]
			physics.apply_impulse_2d(w, it.body, {rnd(&rng, -1, 1), rnd(&rng, -1, 1)} * 6 * physics.mass(w, it.body))
		}
		if tk % 40 == 0 {
			it := items[(tk / 40 * 7) % len(items)]
			lin, _ := physics.velocity_2d(w, it.body)
			physics.set_velocity_2d(w, it.body, lin, rnd(&rng, -10, 10))
		}
		step(w)
		for it in items {
			if !on_plane(w, it.body) do off_plane += 1
			if !in_plane_velocity(w, it.body) do off_velocity += 1
			p, _ := physics.pose_2d(w, it.body)
			if abs(p.x) >= ARENA.x || abs(p.y) >= ARENA.y do escaped += 1
			if it.radius > 0 do sink = max(sink, abs(p.x) + it.radius - ARENA.x, abs(p.y) + it.radius - ARENA.y)
		}
		v, _ := physics.velocity_2d(w, fast[0])
		bounced ||= v.x < -1
	}
	testing.expectf(t, off_plane == 0, "%d body-ticks left the plane (z or quaternion x/y not zero)", off_plane)
	// Boxes and hulls too: their contact points sit at z = ±depth/2 and are solved in 3D (#87).
	testing.expectf(
		t,
		off_velocity == 0,
		"%d body-ticks reported off-plane velocity (v.z, ω.x or ω.y)",
		off_velocity,
	)
	testing.expectf(t, escaped == 0, "%d body-ticks outside the walls", escaped)
	// Contacts are soft: a hard hit sinks a circle into a wall for a tick or two, never through it.
	testing.expectf(t, sink < 0.15, "a circle sank %v m into a wall", sink)
	testing.expect(t, bounced, "the fast circle never bounced off the wall")
	// Circles don't sink into each other.
	worst: f32 = 0
	for a, i in items {
		if a.kind != .Circle do continue
		for b in items[i + 1:] {
			if b.kind != .Circle do continue
			pa, _ := physics.pose_2d(w, a.body)
			pb, _ := physics.pose_2d(w, b.body)
			d := pa - pb
			worst = max(worst, a.radius + b.radius - dmath.sqrt(d.x * d.x + d.y * d.y))
		}
	}
	testing.expectf(t, worst < 0.05, "circles overlap by %v m", worst)
}

// Unit vectors without trig: (1 − t², 2t) / (1 + t²) turns by 2·atan(t), so t → ±∞ approaches ±180°.
unit_of :: proc(t: f32) -> [2]f32 {
	d := 1 + t * t
	return {(1 - t * t) / d, 2 * t / d}
}

@(test)
rot_2d_round_trips :: proc(t: ^testing.T) {
	ts := [?]f32{0, 1e-4, -1e-4, 0.1, -0.3, 0.5, 1, -1, 2, -3, 10, -10, 100, -100, 1e3, -1e3, 1e4, -1e4}
	worst_rot, worst_quat, worst_norm: f32
	for tt in ts {
		r := unit_of(tt)
		q := physics.quat_2d(r)
		testing.expectf(t, q.x == 0 && q.y == 0 && q.w >= 0, "quat_2d(%v) = %v", r, q)
		worst_norm = max(worst_norm, abs(q.z * q.z + q.w * q.w - 1))
		back := physics.rot_2d(q)
		worst_rot = max(worst_rot, abs(back.x - r.x), abs(back.y - r.y))
		again := physics.quat_2d(back)
		worst_quat = max(worst_quat, abs(again.z - q.z), abs(again.w - q.w))
	}
	testing.expectf(t, worst_norm < 1e-6, "quaternion off unit by %v", worst_norm)
	testing.expectf(t, worst_rot < 1e-6, "rot -> quat -> rot off by %v", worst_rot)
	testing.expectf(t, worst_quat < 1e-6, "quat -> rot -> quat off by %v", worst_quat)
	// Exactly 180°, both signs of zero: about +Z, never a division by zero.
	testing.expect_value(t, physics.quat_2d({-1, 0}), [4]f32{0, 0, 1, 0})
	testing.expect_value(t, physics.quat_2d({-1, -0.0}), [4]f32{0, 0, 1, -0.0})
	// Any non-zero direction is normalised; zero is no rotation.
	testing.expect_value(t, physics.quat_2d({}), [4]f32{0, 0, 0, 1})
	testing.expect_value(t, physics.quat_2d({5, 0}), [4]f32{0, 0, 0, 1})
	d := physics.quat_2d({0, 3})
	testing.expectf(t, abs(d.z - d.w) < 1e-7 && abs(d.w - 0.70710678) < 1e-6, "quat_2d((0, 3)) = %v", d)
	// The convention: a positive turn takes +x toward +y (Godot's Node2D.rotation).
	x := physics.rotate(d, {1, 0, 0})
	testing.expectf(t, abs(x.x) < 1e-6 && abs(x.y - 1) < 1e-6 && x.z == 0, "+x turned 90° is %v", x)
}

@(test)
shapes_and_rays_2d :: proc(t: ^testing.T) {
	w := zero_g()
	defer physics.destroy(w)
	sd := b3.DefaultShapeDef()
	sd.density = 2
	// A circle at the origin, a box at x = 5, a triangle at x = 10 turned 90°.
	cbd := physics.body_def_2d(.dynamicBody, {0, 0})
	c := b3.CreateBody(w.id, &cbd)
	physics.circle_2d(c, &sd, 1)
	bbd := physics.body_def_2d(.dynamicBody, {5, 0})
	b := b3.CreateBody(w.id, &bbd)
	physics.box_2d(b, &sd, {1, 0.5}, 0.4)
	tbd := physics.body_def_2d(.dynamicBody, {10, 0}, {0, 1})
	tri := b3.CreateBody(w.id, &tbd)
	_, ok := physics.polygon_2d(tri, &sd, {{-1, -1}, {1, -1}, {0, 1}}, 2)
	testing.expect(t, ok)
	testing.expectf(t, abs(b3.Body_GetMass(b) - 2 * 2 * 1 * 0.4) < 1e-4, "box mass %v", b3.Body_GetMass(b))
	testing.expectf(t, abs(b3.Body_GetMass(tri) - 2 * 2 * 2) < 1e-3, "prism mass %v", b3.Body_GetMass(tri))
	pos, rot := physics.pose_2d(w, physics.ref_of(tri))
	testing.expectf(t, pos == {10, 0} && abs(rot.x) < 1e-6 && abs(rot.y - 1) < 1e-6, "pose %v %v", pos, rot)

	// Bullets: rays in the plane (z = 0) through ray_closest.
	h, hit := physics.ray_closest(w, {-5, 0.2, 0}, {20, 0, 0})
	testing.expect(t, hit && h.body == physics.link_of(c))
	testing.expectf(t, h.point.z == 0 && abs(h.normal.z) < 1e-6 && h.normal.x < -0.97, "circle hit %v", h)
	h, hit = physics.ray_closest(w, {2, 0.2, 0}, {20, 0, 0})
	testing.expect(t, hit && h.body == physics.link_of(b))
	testing.expectf(t, abs(h.point.x - 4) < 1e-4 && h.normal.x < -0.999, "box hit %v", h)
	// The triangle turned 90°: its apex (0, 1) points to −x, at x = 9; its base is at x = 11.
	h, hit = physics.ray_closest(w, {7, 0, 0}, {20, 0, 0})
	testing.expect(t, hit && h.body == physics.link_of(tri))
	testing.expectf(t, abs(h.point.x - 9) < 1e-4, "triangle apex hit %v", h)
	h, hit = physics.ray_closest(w, {20, 0.5, 0}, {-20, 0, 0})
	testing.expectf(t, hit && abs(h.point.x - 11) < 1e-4 && h.normal.x > 0.999, "triangle base hit %v", h)

	// Velocities and impulses in the plane.
	physics.set_velocity_2d(w, physics.ref_of(c), {1, 2}, 3)
	lin, ang := physics.velocity_2d(w, physics.ref_of(c))
	testing.expect(t, lin == {1, 2} && ang == 3)
	m := b3.Body_GetMass(c)
	physics.apply_impulse_2d(w, physics.ref_of(c), {m, -m})
	lin, _ = physics.velocity_2d(w, physics.ref_of(c))
	testing.expectf(t, abs(lin.x - 2) < 1e-5 && abs(lin.y - 1) < 1e-5, "after the impulse %v", lin)

	// polygon_2d refuses what has no area or too many points.
	_, ok = physics.polygon_2d(tri, &sd, {{0, 0}, {1, 0}}, 1)
	testing.expect(t, !ok)
	_, ok = physics.polygon_2d(tri, &sd, {{0, 0}, {1, 0}, {2, 0}}, 1)
	testing.expect(t, !ok, "collinear points made a hull")
	many: [physics.POLYGON_2D_MAX + 1][2]f32
	_, ok = physics.polygon_2d(tri, &sd, many[:], 1)
	testing.expect(t, !ok)
}

// ---- a small top-down co-op game: two ships turn, thrust and shoot rocks that split

Ship :: struct {
	body:     physics.Body_Ref,
	cooldown: u32,
	kills:    u32,
}

Rock :: struct {
	body: physics.Body_Ref,
	size: u32, // 0: no rock
}

Field :: struct {
	ships:  [2]Ship,
	rocks:  [24]Rock,
	rng:    sim.Rng,
	splits: u32,
	spawns: u32,
}

Field_Input :: struct {
	turn:   i8,
	thrust: b8,
	fire:   b8,
	_pad:   u8,
}

Field_World :: struct {
	phys:   ^physics.World,
	extras: [1]sim.Extra,
}

Field_Game :: sim.Game(Field, Field_Input, Field_World, 2)
Field_Inputs :: sim.Inputs(Field_Input, 2)

FIELD := Field_Game {
	name = "field",
	version = "1",
	tick_hz = HZ,
	world_create = proc(seed: u64, _: []u8) -> ^Field_World {
		fw := new(Field_World)
		fw.phys = zero_g()
		arena_walls(fw.phys, ARENA)
		fw.extras[0] = physics.extra(fw.phys, Field)
		return fw
	},
	world_destroy = proc(fw: ^Field_World) {
		physics.destroy(fw.phys)
		free(fw)
	},
	extras = proc(fw: ^Field_World) -> []sim.Extra {return fw.extras[:]},
	init = proc(s: ^Field, fw: ^Field_World, seed: u64) {
		w := fw.phys
		s.rng = sim.rng_seed(seed)
		s.ships[0].body = circle_body(w, {-4, 0}, {}, 0.5)
		s.ships[1].body = circle_body(w, {4, 0}, {}, 0.5)
		physics.teleport(w, s.ships[1].body, {4, 0, 0}, physics.quat_2d({-1, 0}))
		// Every rock size is in the world at tick 0, so a late joiner's registry has every hull.
		for size, i in ([?]u32{3, 3, 3, 3, 2, 2, 1, 1}) {
			rock_add(
				s,
				w,
				{f32(i % 4) * 5 - 7.5, f32(i / 4) * 10 - 5},
				{1, 0},
				{f32(i % 4) - 1.5, f32(i / 4) * 2 - 1},
				0.5,
				size,
			)
		}
	},
	tick = proc(s: ^Field, fw: ^Field_World, t: u32, inputs: ^Field_Inputs, events: ^[dynamic]sim.Event) {
		w := fw.phys
		for &sh, i in s.ships {
			in_ := inputs.input[i]
			pos, rot := physics.pose_2d(w, sh.body)
			lin, _ := physics.velocity_2d(w, sh.body)
			turn := f32(in_.turn) * (4.0 / 127)
			if in_.turn == 0 {
				// No steering: the ship turns toward the first rock (aim assist), by the sign of the
				// cross product of its heading and the direction to the rock.
				for r in s.rocks {
					if r.size == 0 do continue
					rp, _ := physics.pose_2d(w, r.body)
					d := rp - pos
					turn = rot.x * d.y - rot.y * d.x > 0 ? 5 : -5
					break
				}
			}
			physics.set_velocity_2d(w, sh.body, lin, turn)
			if in_.thrust {
				physics.apply_impulse_2d(w, sh.body, rot * (10 * DT * physics.mass(w, sh.body)))
			}
			if sh.cooldown > 0 do sh.cooldown -= 1
			if in_.fire && sh.cooldown == 0 {
				sh.cooldown = 6
				nose := pos + rot * 0.5
				hit, ok := physics.ray_closest(
					w,
					{nose.x, nose.y, 0},
					{rot.x * 30, rot.y * 30, 0},
					{mask = CAT_ROCK | CAT_STATIC},
					physics.link(sh.body),
				)
				if ok {
					for &r in s.rocks {
						if r.size != 0 && physics.link(r.body) == hit.body {
							rock_split(s, w, &r, rot)
							sh.kills += 1
							break
						}
					}
				}
			}
		}
		// Fewer than six rocks: a big one drifts in from a corner.
		live := 0
		for r in s.rocks do live += int(r.size != 0)
		if live < 6 {
			c := [2]f32{f32(sim.rng_below(&s.rng, 2)) * 2 - 1, f32(sim.rng_below(&s.rng, 2)) * 2 - 1}
			rock_add(s, w, c * (ARENA - 2), {1, 0}, -c * 2, 1, 3)
			s.spawns += 1
		}
		step(w)
	},
}

rock_add :: proc(s: ^Field, w: ^physics.World, pos, rot, vel: [2]f32, ang: f32, size: u32) {
	for &r in s.rocks {
		if r.size == 0 {
			r = {rock_body(w, pos, rot, vel, ang, size), size}
			return
		}
	}
}

// Destroys the rock; a big or medium one leaves two smaller ones flying apart across the shot.
rock_split :: proc(s: ^Field, w: ^physics.World, r: ^Rock, shot: [2]f32) {
	pos, rot := physics.pose_2d(w, r.body)
	lin, ang := physics.velocity_2d(w, r.body)
	size := r.size
	physics.destroy_body(w, &r.body)
	r^ = {}
	s.splits += 1
	if size == 1 do return
	side := [2]f32{-shot.y, shot.x}
	off := side * ROCK_RADIUS[size - 1]
	rock_add(s, w, pos + off, rot, lin + side * 2, ang + 1, size - 1)
	rock_add(s, w, pos - off, rot, lin - side * 2, ang - 1, size - 1)
}

field_inputs :: proc(t: u32) -> Field_Inputs {
	ins := Field_Inputs {
		present = {0, 1},
	}
	for i in 0 ..< 2 {
		x := u32(i + 1) * 0x9E3779B1 ~ (t / 10) * 0x85EBCA77
		x ~= x >> 15
		x *= 0x2C1B3C6D
		x ~= x >> 12
		ins.input[i] = {
			turn   = (x >> 4) % 3 == 0 ? i8(x % 255) - 127 : 0,
			thrust = b8((x >> 8) % 3 != 0),
			fire   = b8((x >> 12) % 2 == 0),
		}
	}
	return ins
}

@(test)
field_synctest_and_resume :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.plain_violation(type_info_of(Field)), "")
	TICKS :: 640
	WINDOW :: 8
	s := sim.create(&FIELD, 3)
	defer sim.destroy(s)
	forward: [TICKS + 1]u64
	mismatches, off_plane := 0, 0
	for tk in u32(1) ..= TICKS {
		ins := field_inputs(tk)
		sim.step(s, &ins)
		forward[tk] = sim.checksum(s)
		if tk < WINDOW do continue
		testing.expect(t, sim.restore(s, tk - WINDOW))
		testing.expect(t, physics.check_refs(s.world.phys, &s.state))
		for u in tk - WINDOW + 1 ..= tk {
			ins2 := field_inputs(u)
			sim.step(s, &ins2)
			if sim.checksum(s) != forward[u] do mismatches += 1
		}
		for sh in s.state.ships do off_plane += int(!on_plane(s.world.phys, sh.body))
		for r in s.state.rocks do off_plane += int(r.size != 0 && !on_plane(s.world.phys, r.body))
	}
	testing.expect_value(t, mismatches, 0)
	testing.expect_value(t, off_plane, 0)
	// Rocks really were split, shot to dust and respawned inside the rollback windows.
	testing.expectf(
		t,
		s.state.splits > 20 && s.state.spawns > 2,
		"splits %d, spawns %d",
		s.state.splits,
		s.state.spawns,
	)

	// A portable snapshot loads into a fresh world and continues bit-exactly.
	snap := sim.snapshot_encode(s, TICKS)
	defer delete(snap)
	s2, err := sim.from_snapshot(&FIELD, snap)
	testing.expect_value(t, err, sim.Snap_Error.None)
	if s2 == nil do return
	defer sim.destroy(s2)
	for tk in u32(TICKS + 1) ..= TICKS + 64 {
		a := field_inputs(tk)
		b := a
		sim.step(s, &a)
		sim.step(s2, &b)
		testing.expect_value(t, sim.checksum(s2), sim.checksum(s))
	}
}

// The image carries the geometry its shapes use (#86): a hull first made after tick 0 reaches a
// late joiner, which then runs on identically, deep checksums included.
@(test)
portable_image_carries_new_hulls :: proc(t: ^testing.T) {
	s := sim.create(&FIELD, 3)
	defer sim.destroy(s)
	for tk in u32(1) ..= 20 {
		ins := field_inputs(tk)
		sim.step(s, &ins)
		if tk == 10 do rock_add(&s.state, s.world.phys, {0, -5}, {1, 0}, {}, 0, 4)
	}
	snap := sim.snapshot_encode(s, 20)
	defer delete(snap)
	s2, err := sim.from_snapshot(&FIELD, snap)
	testing.expect_value(t, err, sim.Snap_Error.None)
	if s2 == nil do return
	defer sim.destroy(s2)
	for tk in u32(21) ..= 100 {
		ins := field_inputs(tk)
		sim.step(s, &ins)
		sim.step(s2, &ins)
		testing.expect_value(t, sim.checksum(s2), sim.checksum(s))
	}

	// A damaged image is refused and leaves the world as it was (it would otherwise be half-written).
	s3 := sim.create(&FIELD, 3)
	defer sim.destroy(s3)
	before := sim.checksum(s3)
	img := s.extras[0].image(s.extras[0].data, 100 % sim.RING)
	testing.expect(t, !s3.extras[0].load(s3.extras[0].data, img[:len(img) / 2]))
	testing.expect_value(t, sim.checksum(s3), before)
	ins := field_inputs(1)
	sim.step(s3, &ins)
}

// The field's golden trace: plane-locked bodies, polygon hulls, splits and rays pinned on every
// platform. A change to src/physics, Box3D or the build flags that alters any of these fails here;
// if it is intended, update the values in the same commit.
GOLDEN_FIELD := [4]u64{0xa3eb235bb23d2e5d, 0xf9ed32943b7f89cf, 0x3d4a2fb24df33278, 0xd15988de679f7278}

@(test)
field_golden_trace :: proc(t: ^testing.T) {
	s := sim.create(&FIELD, 5)
	defer sim.destroy(s)
	got: [len(GOLDEN_FIELD)]u64
	for tk in u32(1) ..= 512 {
		ins := field_inputs(tk)
		sim.step(s, &ins)
		if tk % 128 == 0 do got[tk / 128 - 1] = sim.checksum(s)
	}
	testing.expectf(t, s.state.splits > 10, "only %d splits", s.state.splits)
	testing.expectf(
		t,
		got == GOLDEN_FIELD,
		"2D golden trace changed: %x (pinned %x). If the change to src/physics, Box3D or the build flags is intended, update GOLDEN_FIELD in tests/physics/plane2d_test.odin in the same commit",
		got,
		GOLDEN_FIELD,
	)
}
