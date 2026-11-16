// src/physics/SPEC.md, "2D": bodies locked to the plane z = 0. The plane stays exact under contacts,
// impulses and continuous collision; 2D rotations convert to quaternions without trig; a top-down
// game (ships, rocks that split, walls, ray-cast bullets) rolls back and resumes from a portable image.
package test_physics

import "core:testing"

import "unified:b3"
import "unified:dmath"
import "unified:physics"
import "unified:sim"

CAT_SHIP :: u64(1 << 4)
CAT_ROCK :: u64(1 << 5)

DEPTH_2D :: f32(1) // z thickness of boxes and rock hulls
ARENA :: [2]f32{12, 8} // inner half extents of the walled arena

// Four static walls 0.5 m thick whose inner faces are at ±half.
arena_walls :: proc(world: ^physics.World, half: [2]f32) {
	HALF_THICK :: f32(0.25)
	walls := [4][2][2]f32 {
		{{0, -half.y - HALF_THICK}, {half.x + 2 * HALF_THICK, HALF_THICK}},
		{{0, half.y + HALF_THICK}, {half.x + 2 * HALF_THICK, HALF_THICK}},
		{{-half.x - HALF_THICK, 0}, {HALF_THICK, half.y}},
		{{half.x + HALF_THICK, 0}, {HALF_THICK, half.y}},
	}
	for wall in walls {
		body_def := physics.body_def_2d(.Static_Body, wall[0])
		id := b3.create_body(world.id, &body_def)
		shape_def := b3.default_shape_def()
		shape_def.filter.category_bits = CAT_STATIC
		physics.box_2d(id, &shape_def, wall[1], DEPTH_2D)
	}
}

// An irregular heptagon of radius about 1; rock sizes 1..3 scale it.
ROCK_POINTS := [7][2]f32{{1, 0}, {0.62, 0.78}, {-0.2, 0.95}, {-0.9, 0.45}, {-0.85, -0.5}, {-0.15, -1}, {0.7, -0.68}}
ROCK_RADIUS := [5]f32{0, 0.5, 0.9, 1.5, 0.7} // by size; 4 is never at tick 0 (portable_image_carries_new_hulls)

rock_body :: proc(world: ^physics.World, pos, rot, vel: [2]f32, ang: f32, size: u32) -> physics.Body_Ref {
	body_def := physics.body_def_2d(.Dynamic_Body, pos, rot)
	body_def.linear_velocity = {vel.x, vel.y, 0}
	body_def.angular_velocity = {0, 0, ang}
	id := b3.create_body(world.id, &body_def)
	shape_def := b3.default_shape_def()
	shape_def.filter.category_bits = CAT_ROCK
	scaled: [len(ROCK_POINTS)][2]f32
	for point, i in ROCK_POINTS {
		scaled[i] = point * ROCK_RADIUS[size]
	}
	_, ok := physics.polygon_2d(id, &shape_def, scaled[:], DEPTH_2D)
	assert(ok)
	return physics.ref_of(id)
}

circle_body :: proc(
	world: ^physics.World,
	pos, vel: [2]f32,
	radius: f32,
	cat := CAT_SHIP,
	restitution: f32 = 0,
) -> physics.Body_Ref {
	body_def := physics.body_def_2d(.Dynamic_Body, pos)
	body_def.linear_velocity = {vel.x, vel.y, 0}
	id := b3.create_body(world.id, &body_def)
	shape_def := b3.default_shape_def()
	shape_def.filter.category_bits = cat
	shape_def.base_material.restitution = restitution
	physics.circle_2d(id, &shape_def, radius)
	return physics.ref_of(id)
}

zero_g :: proc(workers: i32 = 1) -> ^physics.World {
	return physics.create({gravity = [3]f32{0, 0, 0}, workers = workers})
}

// Whether a dynamic body sits exactly on the plane: z, and the quaternion's x and y, are zero (±0).
on_plane :: proc(world: ^physics.World, ref: physics.Body_Ref) -> bool {
	id := physics.body_id(world, ref)
	body_pos := b3.body_get_position(id)
	body_rot := b3.body_get_rotation(id)
	return body_pos.z == 0 && body_rot.x == 0 && body_rot.y == 0
}

// Whether a body's velocity stays in the plane: v.z, ω.x and ω.y are zero (±0) after a step (#87).
in_plane_velocity :: proc(world: ^physics.World, ref: physics.Body_Ref) -> bool {
	id := physics.body_id(world, ref)
	vel := b3.body_get_linear_velocity(id)
	ang_vel := b3.body_get_angular_velocity(id)
	return vel.z == 0 && ang_vel.x == 0 && ang_vel.y == 0
}

@(test)
plane_2d_stays_exact :: proc(t: ^testing.T) {
	world := zero_g()
	defer physics.destroy(world)
	arena_walls(world, ARENA)
	rng := sim.rng_seed(7)
	rnd :: proc(generator: ^sim.Rng, lo, hi: f32) -> f32 {return lo + (hi - lo) * sim.rng_f32(generator)}

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
	for grid_y in 0 ..< 5 {
		for grid_x in 0 ..< 8 {
			pos := [2]f32{f32(grid_x) * 2.5 - 8.75, f32(grid_y) * 2.5 - 5}
			vel := [2]f32{rnd(&rng, -8, 8), rnd(&rng, -8, 8)}
			ang := rnd(&rng, -6, 6)
			rot := [2]f32{rnd(&rng, -1, 1), rnd(&rng, -1, 1)}
			kind := Kind((grid_x + grid_y) % 3)
			item := Item {
				kind = kind,
			}
			switch kind {
			case .Circle:
				item.radius = rnd(&rng, 0.3, 0.7)
				item.body = circle_body(world, pos, vel, item.radius, restitution = 0.5)
			case .Box:
				body_def := physics.body_def_2d(.Dynamic_Body, pos, rot)
				body_def.linear_velocity = {vel.x, vel.y, 0}
				id := b3.create_body(world.id, &body_def)
				shape_def := b3.default_shape_def()
				physics.box_2d(id, &shape_def, {rnd(&rng, 0.3, 0.8), rnd(&rng, 0.2, 0.6)}, DEPTH_2D)
				item.body = physics.ref_of(id)
			case .Rock:
				item.body = rock_body(world, pos, rot, vel, ang, 1 + u32(grid_x % 3))
			}
			physics.set_velocity_2d(world, item.body, vel, ang)
			append(&items, item)
		}
	}
	// Two fast circles at the walls: 60 m/s is about 0.94 m a tick against 0.5 m walls, so only
	// continuous collision keeps them in.
	fast := [2]physics.Body_Ref {
		circle_body(world, {0, 6.8}, {60, 0}, 0.25, restitution = 0.8),
		circle_body(world, {0, -6.8}, {-45, 33}, 0.25, restitution = 0.8),
	}
	for fast_circle in fast {
		append(&items, Item{fast_circle, .Circle, 0.25})
	}

	off_plane, off_velocity, escaped := 0, 0, 0
	sink: f32
	bounced := false
	for tick in 1 ..= 640 { 	// 10 s
		if tick % 16 == 0 {
			item := items[(tick / 16) % len(items)]
			physics.apply_impulse_2d(
				world,
				item.body,
				{rnd(&rng, -1, 1), rnd(&rng, -1, 1)} * 6 * physics.mass(world, item.body),
			)
		}
		if tick % 40 == 0 {
			item := items[(tick / 40 * 7) % len(items)]
			lin, _ := physics.velocity_2d(world, item.body)
			physics.set_velocity_2d(world, item.body, lin, rnd(&rng, -10, 10))
		}
		step(world)
		for item in items {
			if !on_plane(world, item.body) do off_plane += 1
			if !in_plane_velocity(world, item.body) do off_velocity += 1
			pos, _ := physics.pose_2d(world, item.body)
			if abs(pos.x) >= ARENA.x || abs(pos.y) >= ARENA.y do escaped += 1
			if item.radius > 0 do sink = max(sink, abs(pos.x) + item.radius - ARENA.x, abs(pos.y) + item.radius - ARENA.y)
		}
		vel, _ := physics.velocity_2d(world, fast[0])
		bounced ||= vel.x < -1
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
	for first, i in items {
		if first.kind != .Circle do continue
		for second in items[i + 1:] {
			if second.kind != .Circle do continue
			pos_first, _ := physics.pose_2d(world, first.body)
			pos_second, _ := physics.pose_2d(world, second.body)
			delta := pos_first - pos_second
			worst = max(worst, first.radius + second.radius - dmath.sqrt(delta.x * delta.x + delta.y * delta.y))
		}
	}
	testing.expectf(t, worst < 0.05, "circles overlap by %v m", worst)
}

// Unit vectors without trig: (1 − t², 2t) / (1 + t²) turns by 2·atan(t), so t → ±∞ approaches ±180°.
unit_of :: proc(t: f32) -> [2]f32 {
	denom := 1 + t * t
	return {(1 - t * t) / denom, 2 * t / denom}
}

@(test)
rot_2d_round_trips :: proc(t: ^testing.T) {
	params := [?]f32{0, 1e-4, -1e-4, 0.1, -0.3, 0.5, 1, -1, 2, -3, 10, -10, 100, -100, 1e3, -1e3, 1e4, -1e4}
	worst_rot, worst_quat, worst_norm: f32
	for param in params {
		rot := unit_of(param)
		quat := physics.quat_2d(rot)
		testing.expectf(t, quat.x == 0 && quat.y == 0 && quat.w >= 0, "quat_2d(%v) = %v", rot, quat)
		worst_norm = max(worst_norm, abs(quat.z * quat.z + quat.w * quat.w - 1))
		back := physics.rot_2d(quat)
		worst_rot = max(worst_rot, abs(back.x - rot.x), abs(back.y - rot.y))
		again := physics.quat_2d(back)
		worst_quat = max(worst_quat, abs(again.z - quat.z), abs(again.w - quat.w))
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
	quarter := physics.quat_2d({0, 3})
	testing.expectf(
		t,
		abs(quarter.z - quarter.w) < 1e-7 && abs(quarter.w - 0.70710678) < 1e-6,
		"quat_2d((0, 3)) = %v",
		quarter,
	)
	// The convention: a positive turn takes +x toward +y (Godot's Node2D.rotation).
	turned := dmath.quat_rotate(quarter, {1, 0, 0})
	testing.expectf(
		t,
		abs(turned.x) < 1e-6 && abs(turned.y - 1) < 1e-6 && turned.z == 0,
		"+x turned 90° is %v",
		turned,
	)
}

@(test)
shapes_and_rays_2d :: proc(t: ^testing.T) {
	world := zero_g()
	defer physics.destroy(world)
	shape_def := b3.default_shape_def()
	shape_def.density = 2
	// A circle at the origin, a box at x = 5, a triangle at x = 10 turned 90°.
	circle_body_def := physics.body_def_2d(.Dynamic_Body, {0, 0})
	circle := b3.create_body(world.id, &circle_body_def)
	physics.circle_2d(circle, &shape_def, 1)
	box_body_def := physics.body_def_2d(.Dynamic_Body, {5, 0})
	box_body := b3.create_body(world.id, &box_body_def)
	physics.box_2d(box_body, &shape_def, {1, 0.5}, 0.4)
	tri_body_def := physics.body_def_2d(.Dynamic_Body, {10, 0}, {0, 1})
	tri := b3.create_body(world.id, &tri_body_def)
	_, ok := physics.polygon_2d(tri, &shape_def, {{-1, -1}, {1, -1}, {0, 1}}, 2)
	testing.expect(t, ok)
	testing.expectf(
		t,
		abs(b3.body_get_mass(box_body) - 2 * 2 * 1 * 0.4) < 1e-4,
		"box mass %v",
		b3.body_get_mass(box_body),
	)
	testing.expectf(t, abs(b3.body_get_mass(tri) - 2 * 2 * 2) < 1e-3, "prism mass %v", b3.body_get_mass(tri))
	pos, rot := physics.pose_2d(world, physics.ref_of(tri))
	testing.expectf(t, pos == {10, 0} && abs(rot.x) < 1e-6 && abs(rot.y - 1) < 1e-6, "pose %v %v", pos, rot)

	// Bullets: rays in the plane (z = 0) through ray_closest.
	hit, found := physics.ray_closest(world, {-5, 0.2, 0}, {20, 0, 0})
	testing.expect(t, found && hit.body == physics.link_of(circle))
	testing.expectf(t, hit.point.z == 0 && abs(hit.normal.z) < 1e-6 && hit.normal.x < -0.97, "circle hit %v", hit)
	hit, found = physics.ray_closest(world, {2, 0.2, 0}, {20, 0, 0})
	testing.expect(t, found && hit.body == physics.link_of(box_body))
	testing.expectf(t, abs(hit.point.x - 4) < 1e-4 && hit.normal.x < -0.999, "box hit %v", hit)
	// The triangle turned 90°: its apex (0, 1) points to −x, at x = 9; its base is at x = 11.
	hit, found = physics.ray_closest(world, {7, 0, 0}, {20, 0, 0})
	testing.expect(t, found && hit.body == physics.link_of(tri))
	testing.expectf(t, abs(hit.point.x - 9) < 1e-4, "triangle apex hit %v", hit)
	hit, found = physics.ray_closest(world, {20, 0.5, 0}, {-20, 0, 0})
	testing.expectf(t, found && abs(hit.point.x - 11) < 1e-4 && hit.normal.x > 0.999, "triangle base hit %v", hit)

	// Velocities and impulses in the plane.
	physics.set_velocity_2d(world, physics.ref_of(circle), {1, 2}, 3)
	lin, ang := physics.velocity_2d(world, physics.ref_of(circle))
	testing.expect(t, lin == {1, 2} && ang == 3)
	mass := b3.body_get_mass(circle)
	physics.apply_impulse_2d(world, physics.ref_of(circle), {mass, -mass})
	lin, _ = physics.velocity_2d(world, physics.ref_of(circle))
	testing.expectf(t, abs(lin.x - 2) < 1e-5 && abs(lin.y - 1) < 1e-5, "after the impulse %v", lin)

	// polygon_2d refuses what has no area or too many points.
	_, ok = physics.polygon_2d(tri, &shape_def, {{0, 0}, {1, 0}}, 1)
	testing.expect(t, !ok)
	_, ok = physics.polygon_2d(tri, &shape_def, {{0, 0}, {1, 0}, {2, 0}}, 1)
	testing.expect(t, !ok, "collinear points made a hull")
	many: [physics.POLYGON_2D_MAX + 1][2]f32
	_, ok = physics.polygon_2d(tri, &shape_def, many[:], 1)
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
	ships:   [2]Ship,
	rocks:   [24]Rock,
	rng:     sim.Rng,
	splits:  u32,
	spawns:  u32,
	players: sim.Players(u32, Field_Input, 2), // every sim's State has one; the ships read their slot's input directly
}

// The library's join and leave: listed in every game's event union.
Library_Events :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}

Field_Input :: struct {
	turn:   i8,
	thrust: u8, // 0 or 1 (an Input holds no bools: sim.wire_violation)
	fire:   u8,
	_pad:   u8,
}

Field_World :: struct {
	phys:   ^physics.World,
	extras: [1]sim.Extra,
}

Field_Game :: sim.Game(Field, Field_Input, Field_World, Library_Events, sim.No_Commands, 2)
Field_Inputs :: sim.Inputs(Field_Input, 2)
Field_Tick :: sim.Tick(Field, Field_Input, Field_World, Library_Events, sim.No_Commands, 2)

FIELD := Field_Game {
	name = "field",
	version = "1",
	tick_hz = HZ,
	world_create = proc(seed: u64, _: []u8) -> ^Field_World {return field_world_create(1)},
	world_destroy = proc(field_world: ^Field_World) {
		physics.destroy(field_world.phys)
		free(field_world)
	},
	extras = proc(field_world: ^Field_World) -> []sim.Extra {return field_world.extras[:]},
	init = proc(t: ^Field_Tick) {
		world := t.world.phys
		t.state.rng = sim.rng_seed(t.seed)
		t.state.ships[0].body = circle_body(world, {-4, 0}, {}, 0.5)
		t.state.ships[1].body = circle_body(world, {4, 0}, {}, 0.5)
		physics.teleport(world, t.state.ships[1].body, {4, 0, 0}, physics.quat_2d({-1, 0}))
		// Every rock size is in the world at tick 0, so a late joiner's registry has every hull.
		for size, i in ([?]u32{3, 3, 3, 3, 2, 2, 1, 1}) {
			rock_add(
				t.state,
				world,
				{f32(i % 4) * 5 - 7.5, f32(i / 4) * 10 - 5},
				{1, 0},
				{f32(i % 4) - 1.5, f32(i / 4) * 2 - 1},
				0.5,
				size,
			)
		}
	},
	tick = field_tick,
}

field_world_create :: proc(workers: i32) -> ^Field_World {
	field_world := new(Field_World)
	field_world.phys = zero_g(workers)
	arena_walls(field_world.phys, ARENA)
	field_world.extras[0] = physics.extra(field_world.phys, Field)
	return field_world
}

// The field with its world stepped on 4 workers: every checksum must match the 1-worker field's.
field_on_4_workers :: proc() -> Field_Game {
	game := FIELD
	game.world_create = proc(seed: u64, _: []u8) -> ^Field_World {return field_world_create(4)}
	return game
}

field_tick :: proc(tick: ^Field_Tick) {
	state := tick.state
	world := tick.world.phys
	for &ship, player in state.ships {
		player_input := tick.inputs.input[player]
		pos, rot := physics.pose_2d(world, ship.body)
		lin, _ := physics.velocity_2d(world, ship.body)
		turn := f32(player_input.turn) * (4.0 / 127)
		if player_input.turn == 0 {
			// No steering: the ship turns toward the first rock (aim assist), by the sign of the
			// cross product of its heading and the direction to the rock.
			for rock in state.rocks {
				if rock.size == 0 do continue
				rock_pos, _ := physics.pose_2d(world, rock.body)
				to_rock := rock_pos - pos
				turn = rot.x * to_rock.y - rot.y * to_rock.x > 0 ? 5 : -5
				break
			}
		}
		physics.set_velocity_2d(world, ship.body, lin, turn)
		if player_input.thrust != 0 {
			physics.apply_impulse_2d(world, ship.body, rot * (10 * DT * physics.mass(world, ship.body)))
		}
		if ship.cooldown > 0 do ship.cooldown -= 1
		if player_input.fire != 0 && ship.cooldown == 0 {
			ship.cooldown = 6
			nose := pos + rot * 0.5
			hit, ok := physics.ray_closest(
				world,
				{nose.x, nose.y, 0},
				{rot.x * 30, rot.y * 30, 0},
				{mask = CAT_ROCK | CAT_STATIC},
				physics.link(ship.body),
			)
			if ok {
				for &rock in state.rocks {
					if rock.size != 0 && physics.link(rock.body) == hit.body {
						rock_split(state, world, &rock, rot)
						ship.kills += 1
						break
					}
				}
			}
		}
	}
	// Fewer than six rocks: a big one drifts in from a corner.
	live := 0
	for rock in state.rocks do live += int(rock.size != 0)
	if live < 6 {
		corner := [2]f32{f32(sim.rng_below(&state.rng, 2)) * 2 - 1, f32(sim.rng_below(&state.rng, 2)) * 2 - 1}
		rock_add(state, world, corner * (ARENA - 2), {1, 0}, -corner * 2, 1, 3)
		state.spawns += 1
	}
	step(world)
}

rock_add :: proc(state: ^Field, world: ^physics.World, pos, rot, vel: [2]f32, ang: f32, size: u32) {
	for &rock in state.rocks {
		if rock.size == 0 {
			rock = {rock_body(world, pos, rot, vel, ang, size), size}
			return
		}
	}
}

// Destroys the rock; a big or medium one leaves two smaller ones flying apart across the shot.
rock_split :: proc(state: ^Field, world: ^physics.World, rock: ^Rock, shot: [2]f32) {
	pos, rot := physics.pose_2d(world, rock.body)
	lin, ang := physics.velocity_2d(world, rock.body)
	size := rock.size
	physics.destroy_body(world, &rock.body)
	rock^ = {}
	state.splits += 1
	if size == 1 do return
	side := [2]f32{-shot.y, shot.x}
	offset := side * ROCK_RADIUS[size - 1]
	rock_add(state, world, pos + offset, rot, lin + side * 2, ang + 1, size - 1)
	rock_add(state, world, pos - offset, rot, lin - side * 2, ang - 1, size - 1)
}

field_inputs :: proc(tick: u32) -> Field_Inputs {
	inputs := Field_Inputs {
		present = {0, 1},
	}
	for i in 0 ..< 2 {
		hash := u32(i + 1) * 0x9E3779B1 ~ (tick / 10) * 0x85EBCA77
		hash ~= hash >> 15
		hash *= 0x2C1B3C6D
		hash ~= hash >> 12
		inputs.input[i] = {
			turn   = (hash >> 4) % 3 == 0 ? i8(hash % 255) - 127 : 0,
			thrust = u8((hash >> 8) % 3 != 0),
			fire   = u8((hash >> 12) % 2 == 0),
		}
	}
	return inputs
}

FIELD_TICKS :: 640

// The field sync-tested on 1 and on 4 workers: the same checksums on every tick.
@(test)
field_synctest_and_resume :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.plain_violation(type_info_of(Field)), "")
	one_worker := field_synctest(t, &FIELD)
	field_4 := field_on_4_workers()
	four_workers := field_synctest(t, &field_4)
	testing.expect(t, four_workers == one_worker, "the field on 4 workers: checksums differ from 1 worker's")
}

// Rolls back WINDOW ticks after every tick and re-simulates (the plane must hold), then resumes a second session from
// a portable snapshot. Returns the forward checksums.
field_synctest :: proc(t: ^testing.T, game: ^Field_Game) -> (forward: [FIELD_TICKS + 1]u64) {
	TICKS :: FIELD_TICKS
	WINDOW :: 8
	session := sim.create(game, 3)
	defer sim.destroy(session)
	mismatches, off_plane := 0, 0
	for tick in u32(1) ..= TICKS {
		inputs := field_inputs(tick)
		sim.step(session, &inputs)
		forward[tick] = sim.checksum(session)
		if tick < WINDOW do continue
		testing.expect(t, sim.restore(session, tick - WINDOW))
		testing.expect(t, physics.check_refs(session.world.phys, &session.state))
		for replay_tick in tick - WINDOW + 1 ..= tick {
			replay_inputs := field_inputs(replay_tick)
			sim.step(session, &replay_inputs)
			if sim.checksum(session) != forward[replay_tick] do mismatches += 1
		}
		for ship in session.state.ships do off_plane += int(!on_plane(session.world.phys, ship.body))
		for rock in session.state.rocks do off_plane += int(rock.size != 0 && !on_plane(session.world.phys, rock.body))
	}
	testing.expect_value(t, mismatches, 0)
	testing.expect_value(t, off_plane, 0)
	// Rocks really were split, shot to dust and respawned inside the rollback windows.
	testing.expectf(
		t,
		session.state.splits > 20 && session.state.spawns > 2,
		"splits %d, spawns %d",
		session.state.splits,
		session.state.spawns,
	)

	// A portable snapshot loads into a fresh world and continues bit-exactly.
	snap := sim.snapshot_encode(session, TICKS)
	defer delete(snap)
	session2, err := sim.from_snapshot(game, snap)
	testing.expect_value(t, err, sim.Snap_Error.None)
	if session2 == nil do return
	defer sim.destroy(session2)
	for tick in u32(TICKS + 1) ..= TICKS + 64 {
		inputs := field_inputs(tick)
		inputs2 := inputs
		sim.step(session, &inputs)
		sim.step(session2, &inputs2)
		testing.expect_value(t, sim.checksum(session2), sim.checksum(session))
	}
	return
}

// The image carries the geometry its shapes use (#86): a hull first made after tick 0 reaches a
// late joiner, which then runs on identically, deep checksums included.
@(test)
portable_image_carries_new_hulls :: proc(t: ^testing.T) {
	session := sim.create(&FIELD, 3)
	defer sim.destroy(session)
	for tick in u32(1) ..= 20 {
		inputs := field_inputs(tick)
		sim.step(session, &inputs)
		if tick == 10 do rock_add(&session.state, session.world.phys, {0, -5}, {1, 0}, {}, 0, 4)
	}
	snap := sim.snapshot_encode(session, 20)
	defer delete(snap)
	session2, err := sim.from_snapshot(&FIELD, snap)
	testing.expect_value(t, err, sim.Snap_Error.None)
	if session2 == nil do return
	defer sim.destroy(session2)
	for tick in u32(21) ..= 100 {
		inputs := field_inputs(tick)
		sim.step(session, &inputs)
		sim.step(session2, &inputs)
		testing.expect_value(t, sim.checksum(session2), sim.checksum(session))
	}

	// A damaged image is refused and leaves the world as it was (it would otherwise be half-written).
	session3 := sim.create(&FIELD, 3)
	defer sim.destroy(session3)
	before := sim.checksum(session3)
	image := session.extras[0].image(session.extras[0].data, sim.ring_slot(session, 100))
	testing.expect(t, !session3.extras[0].load(session3.extras[0].data, image[:len(image) / 2]))
	testing.expect_value(t, sim.checksum(session3), before)
	inputs := field_inputs(1)
	sim.step(session3, &inputs)
}

// The field's golden trace: plane-locked bodies, polygon hulls, splits and rays pinned on every
// platform. A change to src/physics, Box3D or the build flags that alters any of these fails here;
// if it is intended, update the values in the same commit.
GOLDEN_FIELD := [4]u64{0x5cf611baeb5122c2, 0x20c635ed9c43d217, 0x594a6dae44aeb81f, 0x898aec436f289c5}

// On 1 and on 4 workers: the same values.
@(test)
field_golden_trace :: proc(t: ^testing.T) {
	field_golden(t, &FIELD)
	field_4 := field_on_4_workers()
	field_golden(t, &field_4)
}

field_golden :: proc(t: ^testing.T, game: ^Field_Game) {
	session := sim.create(game, 5)
	defer sim.destroy(session)
	got: [len(GOLDEN_FIELD)]u64
	for tick in u32(1) ..= 512 {
		inputs := field_inputs(tick)
		sim.step(session, &inputs)
		if tick % 128 == 0 do got[tick / 128 - 1] = sim.checksum(session)
	}
	testing.expectf(t, session.state.splits > 10, "only %d splits", session.state.splits)
	testing.expectf(
		t,
		got == GOLDEN_FIELD,
		"2D golden trace changed (on %d workers): %x (pinned %x). If the change to src/physics, Box3D or the build flags is intended, update GOLDEN_FIELD in tests/physics/plane2d_test.odin in the same commit",
		session.world.phys.workers,
		got,
		GOLDEN_FIELD,
	)
}
