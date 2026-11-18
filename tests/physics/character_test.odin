// src/physics/SPEC.md: the dynamic character, joints under rollback, queries, hit events and kinematic paths.
// The rig is a small game run through the real harness (sim.create/step/restore/checksum), so joint
// churn, platforms and hit events are checked the way a game uses them.
package test_physics

import "core:slice"
import "core:testing"

import "unified:physics"
import "unified:sim"

// The sample's defaults with the category, material and events the tests check.
character_def :: proc() -> physics.Character_Def {
	def := physics.CHARACTER_DEFAULT
	def.category = CAT_CHARACTER
	def.material = 7
	def.hit_events = true
	return def
}

// ---- world building

ground :: proc(world: ^physics.World) {
	box(world, {0, -0.5, 0}, {30, 0.5, 30})
}

new_world :: proc(workers: i32 = 1) -> ^physics.World {
	return physics.create({tick_hz = HZ, workers = workers})
}


// ---- the rig: two characters, boxes, a platform on a path, a hold joint that comes and goes

Rig_Input :: struct {
	mx, mz: i8,
	jump:   u8, // 0 or 1 (an Input holds no bools: sim.wire_violation)
	_pad:   u8,
}

Rig :: struct {
	characters: [2]physics.Character,
	boxes:      [4]physics.Body_Ref,
	platform:   physics.Body_Ref,
	hold:       physics.Motor_Joint_Ref,
	held:       u32, // box index + 1 (0: none)
	hits:       u32,
	jumps:      u32,
	prev:       [2]b8,
	_pad:       u16,
	players:    sim.Players(u32, Rig_Input, 2), // every sim's State has one; the characters read their slot's input directly
}

Rig_World :: struct {
	phys:    ^physics.World,
	scratch: [dynamic]physics.Contact_Event,
}

RIG_PATH := physics.Path {
	points = {0 = {0, 0.25, 6}, 1 = {6, 0.25, 6}, 2 = {6, 3, 6}},
	seconds = {0 = 1.5, 1 = 1},
	wait_s = {0 = 0.25, 1 = 0.25, 2 = 0.5},
	count = 3,
	mode = .Ping_Pong,
	ease = .Smooth,
}

Rig_Game :: sim.Game(Rig, Rig_Input, Rig_World, Library_Events, sim.No_Commands, 2)
Rig_Inputs :: sim.Inputs(Rig_Game)
Rig_Tick :: sim.Tick(Rig_Game)

RIG := Rig_Game {
	name = "rig",
	version = "1",
	tick_hz = HZ,
	world_create = proc(seed: u64, _: []u8) -> ^Rig_World {return rig_world_create(1)},
	world_destroy = proc(rig_world: ^Rig_World) {
		physics.destroy(rig_world.phys)
		delete(rig_world.scratch)
		free(rig_world)
	},
	extra = proc(rig_world: ^Rig_World) -> sim.Extra {return physics.extra(rig_world.phys, Rig)},
	init = proc(t: ^Rig_Tick) {
		world := t.world.phys
		for &character, i in t.state.characters {
			physics.character_create(world, &character, character_def(), {f32(i) * 2, 1.2, 0})
		}
		for &box_ref, i in t.state.boxes {
			t.state.boxes[i], _ = box(
				world,
				{f32(i) - 1.5, 0.5, 2},
				{0.3, 0.3, 0.3},
				.Dynamic,
				category = CAT_BOX,
				hit = true,
			)
			_ = box_ref
		}
		t.state.platform, _ = box(world, RIG_PATH.points[0], {1.5, 0.25, 1.5}, .Kinematic, category = CAT_PLATFORM)
	},
	tick = rig_tick,
}

rig_world_create :: proc(workers: i32) -> ^Rig_World {
	rig_world := new(Rig_World)
	rig_world.phys = physics.create({
			tick_hz             = HZ,
			hit_event_threshold = 1,
			workers             = workers,
		})
	ground(rig_world.phys)
	box(rig_world.phys, {-4, 0.15, 0}, {1, 0.15, 1}) // a step
	return rig_world
}

// The rig with its world stepped on 4 workers: every checksum must match the 1-worker rig's.
rig_on_4_workers :: proc() -> Rig_Game {
	game := RIG
	game.world_create = proc(seed: u64, _: []u8) -> ^Rig_World {return rig_world_create(4)}
	return game
}

rig_tick :: proc(tick: ^Rig_Tick) {
	state, rig_world, number := tick.state, tick.world, tick.number
	world := rig_world.phys
	physics.drive_kinematic(world, state.platform, physics.path_sample(&RIG_PATH, number, HZ))
	for &character, player in state.characters {
		player_input := tick.inputs.input[player]
		move := [2]f32{f32(player_input.mx) / 127, f32(player_input.mz) / 127}
		if physics.character_update(
			world,
			&character,
			character_def(),
			move,
			player_input.jump != 0 && !state.prev[player],
			1,
		) {
			state.jumps += 1
		}
		state.prev[player] = b8(player_input.jump != 0)
	}
	// Character 0 grabs box (number / 40) % 4 for 25 ticks of every 40: a motor joint created and
	// destroyed inside rollback windows.
	phase := number % 40
	if phase == 5 && state.hold == {} {
		box_ref := state.boxes[(number / 40) % 4]
		joint_def := physics.default_motor_joint_def()
		joint_def.base.local_frame_a = {{0, 0.3, 0.9}, {0, 0, 0, 1}}
		joint_def.linear_hertz = 6
		joint_def.linear_damping_ratio = 1
		joint_def.max_spring_force = 400
		joint_def.angular_hertz = 4
		joint_def.angular_damping_ratio = 1
		joint_def.max_spring_torque = 50
		state.hold = physics.create_motor_joint(
			world,
			physics.link(state.characters[0].body),
			physics.link(box_ref),
			joint_def,
		)
		state.held = (number / 40) % 4 + 1
	} else if phase == 30 && state.hold != {} {
		physics.destroy_joint(world, &state.hold)
		// throw it at character 1
		box_ref := state.boxes[state.held - 1]
		box_pos := physics.body_position(world, box_ref)
		target_pos := physics.body_position(world, state.characters[1].body)
		physics.body_apply_linear_impulse_to_center(
			world,
			box_ref,
			{(target_pos.x - box_pos.x) * 2, 3, (target_pos.z - box_pos.z) * 2},
		)
		state.held = {}
	}
	steps(world, 1)
	physics.world_contact_events(world, &rig_world.scratch)
	for event in rig_world.scratch do state.hits += u32(event.kind == .Hit)
}

rig_input :: proc(player: int, tick: u32) -> Rig_Input {
	hash := u32(player + 1) * 0x85EBCA77 ~ (tick / 12) * 0xC2B2AE3D
	hash ~= hash >> 15
	hash *= 0x2C1B3C6D
	hash ~= hash >> 12
	return {
		mx   = i8(hash % 255) - 127,
		mz   = i8((hash >> 8) % 255) - 127,
		jump = u8((hash >> 16) % 4 == 0),
	}
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

RIG_TICKS :: 640

// The rig sync-tested on 1 and on 4 workers (synctest_and_resume): the same checksums on every tick.
@(test)
rig_synctest_with_joints :: proc(t: ^testing.T) {
	one_worker := synctest_and_resume(t, &RIG, 1, RIG_TICKS, rig_inputs, after = rig_did_its_job)
	rig_4 := rig_on_4_workers()
	four_workers := synctest_and_resume(t, &rig_4, 1, RIG_TICKS, rig_inputs)
	testing.expect(t, slice.equal(four_workers, one_worker), "the rig on 4 workers: checksums differ from 1 worker's")
}

// What each tick's save copies (the block, the world's arena snapshot of its slot and its body table), and that the
// rig really did what it is for.
rig_did_its_job :: proc(t: ^testing.T, session: ^sim.Sim(Rig_Game)) {
	slot := sim.ring_slot(session, session.tick)
	world_bytes := session.world.phys.ring[slot].size
	table_bytes := len(session.world.phys.body_ring[slot]) * size_of(physics.Body_Entry)
	testing.expect(t, world_bytes > 0 && table_bytes > 0)
	testing.expect_value(t, sim.save_size(session), size_of(Rig) + world_bytes + table_bytes)
	testing.expect(t, session.state.jumps > 5)
	testing.expect(t, session.state.hits > 0)
}

// ---- character behaviour

Solo :: struct {
	world:     ^physics.World,
	character: physics.Character,
}

solo :: proc(pos: [3]f32) -> Solo {
	scene := Solo {
		world = new_world(),
	}
	ground(scene.world)
	physics.character_create(scene.world, &scene.character, character_def(), pos)
	return scene
}

run :: proc(scene: ^Solo, ticks: int, move := [2]f32{}, jump_at := -1) -> (peak: f32) {
	peak = -1e9
	for i in 0 ..< ticks {
		physics.character_update(scene.world, &scene.character, character_def(), move, i == jump_at, 1)
		steps(scene.world, 1)
		peak = max(peak, physics.body_position(scene.world, scene.character.body).y)
	}
	return
}

@(test)
character_stands_still :: proc(t: ^testing.T) {
	scene := solo({0, 1.5, 0})
	defer physics.destroy(scene.world)
	run(&scene, 128)
	testing.expect(t, physics.character_grounded(&scene.character))
	pos_before := physics.body_position(scene.world, scene.character.body)
	run(&scene, 640)
	pos_after := physics.body_position(scene.world, scene.character.body)
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
character_walks_and_jumps :: proc(t: ^testing.T) {
	scene := solo({0, 1.5, 0})
	defer physics.destroy(scene.world)
	run(&scene, 64)
	run(&scene, 64, {1, 0})
	vel := physics.body_linear_velocity(scene.world, scene.character.body)
	testing.expectf(t, vel.x > 5.5 && vel.x < 6.1, "walk speed %v", vel.x)
	y0 := physics.body_position(scene.world, scene.character.body).y
	peak := run(&scene, 96, {}, 2)
	// v²/2g with gravity scale 1.5: 1.66 m (the pogo adds a little at take-off).
	testing.expectf(t, peak - y0 > 1.3 && peak - y0 < 2.2, "jump height %v", peak - y0)
	run(&scene, 64)
	testing.expect(t, physics.character_grounded(&scene.character))
}

@(test)
character_climbs_a_step :: proc(t: ^testing.T) {
	scene := solo({0, 1.5, 0})
	defer physics.destroy(scene.world)
	box(scene.world, {6, 0.15, 0}, {4, 0.15, 2}) // a 0.3 m step at x = 2
	run(&scene, 64)
	y0 := physics.body_position(scene.world, scene.character.body).y
	run(&scene, 40, {1, 0})
	run(&scene, 64)
	pos := physics.body_position(scene.world, scene.character.body)
	testing.expectf(t, pos.x > 2.5 && pos.y - y0 > 0.25, "on the step: %v (from y %v)", pos, y0)
}

@(test)
character_slides_off_a_steep_slope :: proc(t: ^testing.T) {
	scene := solo({0, 3, 0})
	defer physics.destroy(scene.world)
	// 50° about z: (0, 0, sin 25°, cos 25°)
	box(scene.world, {0, 1, 0}, {3, 0.2, 2}, rot = {0, 0, 0.42261826, 0.90630779})
	run(&scene, 192)
	pos := physics.body_position(scene.world, scene.character.body)
	testing.expectf(t, pos.x > 1 || pos.x < -1, "still on the slope at %v", pos)
}

@(test)
character_rides_platforms :: proc(t: ^testing.T) {
	scene := solo({0, 1.6, 6})
	defer physics.destroy(scene.world)
	plat, _ := box(scene.world, RIG_PATH.points[0], {1.5, 0.25, 1.5}, .Kinematic, category = CAT_PLATFORM)
	cycle := int(physics.path_duration_ticks(&RIG_PATH, HZ))
	worst: f32 = 0
	for i in 0 ..< 2 * cycle {
		physics.drive_kinematic(scene.world, plat, physics.path_sample(&RIG_PATH, u32(i + 1), HZ))
		physics.character_update(scene.world, &scene.character, character_def(), {}, false, 1)
		steps(scene.world, 1)
		if i > 32 {
			plat_pos := physics.body_position(scene.world, plat)
			character_pos := physics.body_position(scene.world, scene.character.body)
			gap := max(abs(character_pos.x - plat_pos.x), abs(character_pos.z - plat_pos.z))
			worst = max(worst, gap)
			testing.expectf(
				t,
				character_pos.y > plat_pos.y + 0.5,
				"fell off at tick %d: character %v, platform %v",
				i,
				character_pos,
				plat_pos,
			)
			if character_pos.y <= plat_pos.y + 0.5 do return
		}
	}
	testing.expectf(t, worst < 0.6, "slipped %v m on the platform", worst)
}

@(test)
character_is_pushed_and_stands_on_another :: proc(t: ^testing.T) {
	scene := solo({0, 1.5, 0})
	defer physics.destroy(scene.world)
	run(&scene, 64)
	x0 := physics.body_position(scene.world, scene.character.body).x
	// A heavy box (86 kg, about the character's mass) at 14 m/s: the drive's force cap gives way.
	thrown, _ := box(scene.world, {-3, 1.4, 0}, {0.3, 0.3, 0.3}, .Dynamic, category = CAT_BOX, density = 400)
	physics.body_set_linear_velocity(scene.world, thrown, {14, 0, 0})
	run(&scene, 64)
	pushed := physics.body_position(scene.world, scene.character.body).x - x0
	testing.expectf(t, pushed > 0.1, "pushed only %v m", pushed)

	top: physics.Character
	physics.character_create(
		scene.world,
		&top,
		character_def(),
		physics.body_position(scene.world, scene.character.body) + [3]f32{0, 2.2, 0},
	)
	for _ in 0 ..< 160 {
		physics.character_update(scene.world, &scene.character, character_def(), {}, false, 1)
		physics.character_update(scene.world, &top, character_def(), {}, false, 1)
		steps(scene.world, 1)
	}
	lo := physics.body_position(scene.world, scene.character.body)
	hi := physics.body_position(scene.world, top.body)
	testing.expectf(t, hi.y - lo.y > 1.3, "not standing on the other character: %v over %v", hi, lo)
	testing.expect(t, top.ground == physics.link(scene.character.body))
}

@(test)
character_limp_and_teleport :: proc(t: ^testing.T) {
	scene := solo({0, 1.5, 0})
	defer physics.destroy(scene.world)
	run(&scene, 64)
	physics.character_set_limp(scene.world, &scene.character, true)
	testing.expect(t, scene.character.pogo == {})
	run(&scene, 64, {1, 0}, 3) // input is ignored while limp
	testing.expect(t, abs(physics.body_position(scene.world, scene.character.body).x) < 0.01)
	physics.character_set_limp(scene.world, &scene.character, false)
	physics.character_teleport(scene.world, &scene.character, {5, 2, 5})
	run(&scene, 96)
	pos := physics.body_position(scene.world, scene.character.body)
	testing.expectf(t, abs(pos.x - 5) < 0.01 && abs(pos.z - 5) < 0.01, "teleported to %v", pos)
	testing.expect(t, physics.character_grounded(&scene.character))
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
	plat, _ := box(world, path.points[0], {1, 0.25, 1}, .Kinematic, category = CAT_PLATFORM)
	cycle := physics.path_duration_ticks(&path, HZ)
	worst: f32 = 0
	for i in u32(1) ..= 10 * cycle {
		target := physics.path_sample(&path, i, HZ)
		physics.drive_kinematic(world, plat, target)
		steps(world, 1)
		plat_pos := physics.body_position(world, plat)
		worst = max(worst, abs(plat_pos.x - target.x), abs(plat_pos.y - target.y), abs(plat_pos.z - target.z))
	}
	testing.expectf(t, worst < 1e-4, "kinematic body is %v m off its path", worst)
}
