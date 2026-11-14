// src/physics/SPEC.md: the dynamic mover, joints under rollback, queries, hit events and kinematic paths.
// The rig is a small game run through the real harness (sim.create/step/restore/checksum), so joint
// churn, platforms and hit events are checked the way a game uses them.
package test_physics

import "core:testing"

import "unified:b3"
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
	world: ^physics.World,
	pos, half: [3]f32,
	type: b3.Body_Type = .Static_Body,
	rot := [4]f32{0, 0, 0, 1},
	cat := CAT_STATIC,
	density: f32 = 1,
	hit := false,
) -> b3.Body_Id {
	body_def := b3.default_body_def()
	body_def.type = type
	body_def.position = {pos.x, pos.y, pos.z}
	body_def.rotation = rot
	if type == .Kinematic_Body do body_def.enable_sleep = false
	id := b3.create_body(world.id, &body_def)
	shape_def := b3.default_shape_def()
	shape_def.density = density
	shape_def.filter.category_bits = cat
	shape_def.enable_hit_events = hit
	hull := b3.make_box_hull(half.x, half.y, half.z)
	b3.create_hull_shape(id, &shape_def, &hull.base)
	return id
}

ground :: proc(world: ^physics.World) {
	box(world, {0, -0.5, 0}, {30, 0.5, 30})
}

new_world :: proc() -> ^physics.World {
	return physics.create({anchor = true})
}

step :: proc(world: ^physics.World) {
	physics.step(world, DT, 4)
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
Rig_Tick :: sim.Tick(Rig, Rig_Input, Rig_World, 2)

RIG := Rig_Game {
	name = "rig",
	version = "1",
	tick_hz = HZ,
	world_create = proc(seed: u64, _: []u8) -> ^Rig_World {
		rig_world := new(Rig_World)
		rig_world.phys = physics.create({anchor = true, hit_threshold = 1})
		ground(rig_world.phys)
		box(rig_world.phys, {-4, 0.15, 0}, {1, 0.15, 1}) // a step
		rig_world.extras[0] = physics.extra(rig_world.phys, Rig)
		return rig_world
	},
	world_destroy = proc(rig_world: ^Rig_World) {
		physics.destroy(rig_world.phys)
		delete(rig_world.scratch)
		free(rig_world)
	},
	extras = proc(rig_world: ^Rig_World) -> []sim.Extra {return rig_world.extras[:]},
	init = proc(state: ^Rig, rig_world: ^Rig_World, seed: u64) {
		world := rig_world.phys
		for &mover, i in state.movers {
			physics.mover_create(world, &mover, &MOVER, {f32(i) * 2, 1.2, 0})
		}
		for &box_ref, i in state.boxes {
			state.boxes[i] = physics.ref_of(
				box(world, {f32(i) - 1.5, 0.5, 2}, {0.3, 0.3, 0.3}, .Dynamic_Body, cat = CAT_BOX, hit = true),
			)
			_ = box_ref
		}
		state.platform = physics.ref_of(
			box(world, RIG_PATH.points[0], {1.5, 0.25, 1.5}, .Kinematic_Body, cat = CAT_PLATFORM),
		)
	},
	tick = rig_tick,
}

rig_tick :: proc(game: ^Rig_Tick) {
	state, rig_world, tick := game.state, game.world, game.number
	world := rig_world.phys
	physics.drive_kinematic(world, state.platform, physics.path_sample(&RIG_PATH, tick, HZ), HZ)
	for &mover, player in state.movers {
		player_input := game.inputs.input[player]
		move := [2]f32{f32(player_input.mx) / 127, f32(player_input.mz) / 127}
		if physics.mover_update(world, &mover, &MOVER, move, bool(player_input.jump && !state.prev[player]), 1, DT) {
			state.jumps += 1
		}
		state.prev[player] = player_input.jump
	}
	// Mover 0 grabs box (tick / 40) % 4 for 25 ticks of every 40: a motor joint created and
	// destroyed inside rollback windows.
	phase := tick % 40
	if phase == 5 && state.hold == {} {
		box_ref := state.boxes[(tick / 40) % 4]
		joint_def := b3.default_motor_joint_def()
		joint_def.base.body_id_a = physics.body_id(world, state.movers[0].body)
		joint_def.base.body_id_b = physics.body_id(world, box_ref)
		joint_def.base.local_frame_a = {{0, 0.3, 0.9}, {0, 0, 0, 1}}
		joint_def.linear_hertz = 6
		joint_def.linear_damping_ratio = 1
		joint_def.max_spring_force = 400
		joint_def.angular_hertz = 4
		joint_def.angular_damping_ratio = 1
		joint_def.max_spring_torque = 50
		state.hold = physics.joint_ref_of(b3.create_motor_joint(world.id, &joint_def))
		state.held = (tick / 40) % 4 + 1
	} else if phase == 30 && state.hold != {} {
		physics.destroy_joint(world, &state.hold)
		// throw it at mover 1
		box_ref := state.boxes[state.held - 1]
		box_pos := physics.position(world, box_ref)
		target_pos := physics.position(world, state.movers[1].body)
		physics.impulse(world, box_ref, {(target_pos.x - box_pos.x) * 2, 3, (target_pos.z - box_pos.z) * 2})
		state.held = {}
	}
	step(world)
	clear(&rig_world.scratch)
	physics.hit_events(world, &rig_world.scratch)
	state.hits += u32(len(rig_world.scratch))
}

rig_input :: proc(player: int, tick: u32) -> Rig_Input {
	hash := u32(player + 1) * 0x85EBCA77 ~ (tick / 12) * 0xC2B2AE3D
	hash ~= hash >> 15
	hash *= 0x2C1B3C6D
	hash ~= hash >> 12
	return {mx = i8(hash % 255) - 127, mz = i8((hash >> 8) % 255) - 127, jump = b8((hash >> 16) % 4 == 0)}
}

rig_inputs :: proc(tick: u32) -> Rig_Inputs {
	inputs := Rig_Inputs {
		present = {0, 1},
	}
	for i in 0 ..< 2 {
		inputs.input[i] = rig_input(i, tick)
	}
	return inputs
}

@(test)
rig_synctest_with_joints :: proc(t: ^testing.T) {
	TICKS :: 640
	WINDOW :: 8
	session := sim.create(&RIG, 1)
	defer sim.destroy(session)
	forward: [TICKS + 1]u64
	mismatches := 0
	for tick in u32(1) ..= TICKS {
		inputs := rig_inputs(tick)
		sim.step(session, &inputs)
		forward[tick] = sim.checksum(session)
		if tick < WINDOW do continue
		testing.expect(t, sim.restore(session, tick - WINDOW))
		testing.expect(t, physics.check_refs(session.world.phys, &session.state))
		for replay_tick in tick - WINDOW + 1 ..= tick {
			replay_inputs := rig_inputs(replay_tick)
			sim.step(session, &replay_inputs)
			if sim.checksum(session) != forward[replay_tick] do mismatches += 1
		}
	}
	testing.expect_value(t, mismatches, 0)
	// The rig really did what it is for.
	testing.expect(t, session.state.jumps > 5)
	testing.expect(t, session.state.hits > 0)

	// A portable snapshot loads into a fresh world and continues bit-exactly.
	snap := sim.snapshot_encode(session, TICKS)
	defer delete(snap)
	session2, err := sim.from_snapshot(&RIG, snap)
	testing.expect_value(t, err, sim.Snap_Error.None)
	if session2 == nil do return
	defer sim.destroy(session2)
	for tick in u32(TICKS + 1) ..= TICKS + 64 {
		inputs := rig_inputs(tick)
		inputs2 := inputs
		sim.step(session, &inputs)
		sim.step(session2, &inputs2)
		testing.expect_value(t, sim.checksum(session2), sim.checksum(session))
	}
}

// ---- mover behaviour

Solo :: struct {
	world: ^physics.World,
	mover: physics.Mover,
}

solo :: proc(pos: [3]f32) -> Solo {
	scene := Solo {
		world = new_world(),
	}
	ground(scene.world)
	physics.mover_create(scene.world, &scene.mover, &MOVER, pos)
	return scene
}

run :: proc(scene: ^Solo, ticks: int, move := [2]f32{}, jump_at := -1) -> (peak: f32) {
	peak = -1e9
	for i in 0 ..< ticks {
		physics.mover_update(scene.world, &scene.mover, &MOVER, move, i == jump_at, 1, DT)
		step(scene.world)
		peak = max(peak, physics.position(scene.world, scene.mover.body).y)
	}
	return
}

@(test)
mover_stands_still :: proc(t: ^testing.T) {
	scene := solo({0, 1.5, 0})
	defer physics.destroy(scene.world)
	run(&scene, 128)
	testing.expect(t, physics.mover_grounded(&scene.mover))
	pos_before := physics.position(scene.world, scene.mover.body)
	run(&scene, 640)
	pos_after := physics.position(scene.world, scene.mover.body)
	testing.expectf(
		t,
		abs(pos_after.x - pos_before.x) + abs(pos_after.y - pos_before.y) + abs(pos_after.z - pos_before.z) < 1e-3,
		"drifted %v -> %v",
		pos_before,
		pos_after,
	)
	// The pogo holds the capsule's bottom about pogo_rest above the floor.
	testing.expectf(t, pos_after.y > 1.1 && pos_after.y < 1.6, "height %v", pos_after.y)
}

@(test)
mover_walks_and_jumps :: proc(t: ^testing.T) {
	scene := solo({0, 1.5, 0})
	defer physics.destroy(scene.world)
	run(&scene, 64)
	run(&scene, 64, {1, 0})
	vel := physics.velocity(scene.world, scene.mover.body)
	testing.expectf(t, vel.x > 5.5 && vel.x < 6.1, "walk speed %v", vel.x)
	y0 := physics.position(scene.world, scene.mover.body).y
	peak := run(&scene, 96, {}, 2)
	// v²/2g with gravity scale 1.5: 1.66 m (the pogo adds a little at take-off).
	testing.expectf(t, peak - y0 > 1.3 && peak - y0 < 2.2, "jump height %v", peak - y0)
	run(&scene, 64)
	testing.expect(t, physics.mover_grounded(&scene.mover))
}

@(test)
mover_climbs_a_step :: proc(t: ^testing.T) {
	scene := solo({0, 1.5, 0})
	defer physics.destroy(scene.world)
	box(scene.world, {6, 0.15, 0}, {4, 0.15, 2}) // a 0.3 m step at x = 2
	run(&scene, 64)
	y0 := physics.position(scene.world, scene.mover.body).y
	run(&scene, 40, {1, 0})
	run(&scene, 64)
	pos := physics.position(scene.world, scene.mover.body)
	testing.expectf(t, pos.x > 2.5 && pos.y - y0 > 0.25, "on the step: %v (from y %v)", pos, y0)
}

@(test)
mover_slides_off_a_steep_slope :: proc(t: ^testing.T) {
	scene := solo({0, 3, 0})
	defer physics.destroy(scene.world)
	// 50° about z: (0, 0, sin 25°, cos 25°)
	box(scene.world, {0, 1, 0}, {3, 0.2, 2}, rot = {0, 0, 0.42261826, 0.90630779})
	run(&scene, 192)
	pos := physics.position(scene.world, scene.mover.body)
	testing.expectf(t, pos.x > 1 || pos.x < -1, "still on the slope at %v", pos)
}

@(test)
mover_rides_platforms :: proc(t: ^testing.T) {
	scene := solo({0, 1.6, 6})
	defer physics.destroy(scene.world)
	plat := physics.ref_of(box(scene.world, RIG_PATH.points[0], {1.5, 0.25, 1.5}, .Kinematic_Body, cat = CAT_PLATFORM))
	cycle := int(physics.path_duration_ticks(&RIG_PATH, HZ))
	worst: f32 = 0
	for i in 0 ..< 2 * cycle {
		physics.drive_kinematic(scene.world, plat, physics.path_sample(&RIG_PATH, u32(i + 1), HZ), HZ)
		physics.mover_update(scene.world, &scene.mover, &MOVER, {}, false, 1, DT)
		step(scene.world)
		if i > 32 {
			plat_pos := physics.position(scene.world, plat)
			mover_pos := physics.position(scene.world, scene.mover.body)
			gap := max(abs(mover_pos.x - plat_pos.x), abs(mover_pos.z - plat_pos.z))
			worst = max(worst, gap)
			testing.expectf(
				t,
				mover_pos.y > plat_pos.y + 0.5,
				"fell off at tick %d: mover %v, platform %v",
				i,
				mover_pos,
				plat_pos,
			)
			if mover_pos.y <= plat_pos.y + 0.5 do return
		}
	}
	testing.expectf(t, worst < 0.6, "slipped %v m on the platform", worst)
}

@(test)
mover_is_pushed_and_stands_on_another :: proc(t: ^testing.T) {
	scene := solo({0, 1.5, 0})
	defer physics.destroy(scene.world)
	run(&scene, 64)
	x0 := physics.position(scene.world, scene.mover.body).x
	// A heavy box (86 kg, about the mover's mass) at 14 m/s: the drive's force cap gives way.
	thrown := physics.ref_of(
		box(scene.world, {-3, 1.4, 0}, {0.3, 0.3, 0.3}, .Dynamic_Body, cat = CAT_BOX, density = 400),
	)
	physics.set_velocity(scene.world, thrown, {14, 0, 0})
	run(&scene, 64)
	pushed := physics.position(scene.world, scene.mover.body).x - x0
	testing.expectf(t, pushed > 0.1, "pushed only %v m", pushed)

	top: physics.Mover
	physics.mover_create(
		scene.world,
		&top,
		&MOVER,
		physics.position(scene.world, scene.mover.body) + [3]f32{0, 2.2, 0},
	)
	for _ in 0 ..< 160 {
		physics.mover_update(scene.world, &scene.mover, &MOVER, {}, false, 1, DT)
		physics.mover_update(scene.world, &top, &MOVER, {}, false, 1, DT)
		step(scene.world)
	}
	lo := physics.position(scene.world, scene.mover.body)
	hi := physics.position(scene.world, top.body)
	testing.expectf(t, hi.y - lo.y > 1.3, "not standing on the other mover: %v over %v", hi, lo)
	testing.expect(t, top.ground == physics.link(scene.mover.body))
}

@(test)
mover_limp_and_teleport :: proc(t: ^testing.T) {
	scene := solo({0, 1.5, 0})
	defer physics.destroy(scene.world)
	run(&scene, 64)
	physics.mover_set_limp(scene.world, &scene.mover, true)
	testing.expect(t, scene.mover.pogo == {})
	run(&scene, 64, {1, 0}, 3) // input is ignored while limp
	testing.expect(t, abs(physics.position(scene.world, scene.mover.body).x) < 0.01)
	physics.mover_set_limp(scene.world, &scene.mover, false)
	physics.mover_teleport(scene.world, &scene.mover, {5, 2, 5})
	run(&scene, 96)
	pos := physics.position(scene.world, scene.mover.body)
	testing.expectf(t, abs(pos.x - 5) < 0.01 && abs(pos.z - 5) < 0.01, "teleported to %v", pos)
	testing.expect(t, physics.mover_grounded(&scene.mover))
}

// ---- queries, events, refs

@(test)
queries_and_hit_events :: proc(t: ^testing.T) {
	world := physics.create({anchor = true, hit_threshold = 1})
	defer physics.destroy(world)
	ground(world)
	faller := box(world, {0, 2, 0}, {0.5, 0.5, 0.5}, .Dynamic_Body, cat = CAT_BOX, hit = true)
	side_box := box(world, {3, 0.5, 0}, {0.5, 0.5, 0.5}, .Dynamic_Body, cat = CAT_BOX)
	// A ray from inside `a` skips it when told to, and finds the ground under it.
	hit, ok := physics.ray_closest(world, {0, 2, 0}, {0, -5, 0}, {}, physics.link_of(faller))
	testing.expect(t, ok && abs(hit.point.y) < 1e-4 && hit.normal.y > 0.99)
	hit, ok = physics.ray_closest(world, {0, 2, 0}, {0, -5, 0})
	testing.expect(t, ok && hit.body == physics.link_of(faller))
	// ray_first (b3World_CastRayClosest): the closest hit, filtered by category.
	hit, ok = physics.ray_first(world, {0, 5, 0}, {0, -8, 0})
	testing.expect(t, ok && hit.body == physics.link_of(faller) && abs(hit.point.y - 2.5) < 1e-4)
	hit, ok = physics.ray_first(world, {0, 5, 0}, {0, -8, 0}, {mask = CAT_STATIC})
	testing.expect(t, ok && abs(hit.point.y) < 1e-4)
	_, ok = physics.ray_first(world, {0, 10, 0}, {0, 1, 0})
	testing.expect(t, !ok)
	// Overlaps come back sorted by body index, once each.
	got: [dynamic]physics.Body_Link
	defer delete(got)
	physics.overlap_aabb(world, {-5, 0.2, -1}, {5, 3, 1}, &got, {mask = CAT_BOX})
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 do testing.expect(t, got[0].index1 < got[1].index1 && got[1] == physics.link_of(side_box))
	// `a` falls onto the ground: one hit event at ~6 m/s.
	events: [dynamic]physics.Hit_Event
	defer delete(events)
	for _ in 0 ..< 64 {
		step(world)
		physics.hit_events(world, &events)
	}
	testing.expect(t, len(events) >= 1)
	if len(events) >= 1 do testing.expect(t, events[0].speed > 3)
	// check_refs: stale refs are caught.
	Two :: struct {
		body:  physics.Body_Ref,
		joint: physics.Joint_Ref,
	}
	two := Two {
		body = physics.ref_of(side_box),
	}
	_ = physics.extra(world, Two)
	testing.expect(t, physics.check_refs(world, &two))
	b3.destroy_body(side_box)
	testing.expect(t, !physics.check_refs(world, &two))
}

// ---- paths

@(test)
paths_sample_exactly :: proc(t: ^testing.T) {
	path := RIG_PATH
	// 0.25 s wait at 0, 1.5 s to 1, 0.25 s wait, 1 s to 2, 0.5 s wait, 1 s back to 1, 0.25 s wait, 1.5 s to 0.
	testing.expect_value(
		t,
		physics.path_duration_ticks(&path, HZ),
		u32((0.25 + 1.5 + 0.25 + 1 + 0.5 + 1 + 0.25 + 1.5) * HZ),
	)
	testing.expect(t, physics.path_sample(&path, 0, HZ) == path.points[0])
	testing.expect(t, physics.path_sample(&path, 16, HZ) == path.points[0]) // end of the wait
	testing.expect(t, physics.path_sample(&path, 16 + 96, HZ) == path.points[1]) // arrived
	testing.expect(t, physics.path_sample(&path, 16 + 96 + 16 + 64, HZ) == path.points[2])
	mid := physics.path_sample(&path, 16 + 48, HZ) // halfway along the first leg, smoothstep(0.5) = 0.5
	testing.expect_value(t, mid, [3]f32{3, 0.25, 6})
	total := physics.path_duration_ticks(&path, HZ)
	testing.expect(t, physics.path_sample(&path, total, HZ) == path.points[0]) // the cycle repeats
	once := path
	once.mode = .Once
	testing.expect(t, physics.path_sample(&once, 100000, HZ) == path.points[2])
	loop := path
	loop.mode = .Loop
	loop.seconds[2] = 2
	testing.expect_value(t, physics.path_duration_ticks(&loop, HZ), u32((0.25 + 1.5 + 0.25 + 1 + 0.5 + 2) * HZ))
}

@(test)
kinematic_drive_does_not_drift :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	path := RIG_PATH
	plat := physics.ref_of(box(world, path.points[0], {1, 0.25, 1}, .Kinematic_Body, cat = CAT_PLATFORM))
	cycle := physics.path_duration_ticks(&path, HZ)
	worst: f32 = 0
	for i in u32(1) ..= 10 * cycle {
		target := physics.path_sample(&path, i, HZ)
		physics.drive_kinematic(world, plat, target, HZ)
		step(world)
		plat_pos := physics.position(world, plat)
		worst = max(worst, abs(plat_pos.x - target.x), abs(plat_pos.y - target.y), abs(plat_pos.z - target.z))
	}
	testing.expectf(t, worst < 1e-4, "kinematic body is %v m off its path", worst)
}
