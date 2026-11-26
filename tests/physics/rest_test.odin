// src/physics/README.md, Character: a character put to rest (physics.character_rest) and woken (physics.character_wake).
// What a rest keeps and drops, that it costs a step nothing, how other bodies and queries meet a resting character, and
// that a rest and a wake roll back, re-simulate and resume from a snapshot bit-exactly.
package test_physics

import box3d "box3d:bindings"
import "core:testing"

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// A character on the ground, stood still long enough to settle on its pogo.
settled :: proc(pos: [3]f32) -> Solo {
	scene := solo(pos)
	run(&scene, 128)
	return scene
}

// A rest: kinematic, asleep, no joints, deaf to its input and exactly still. A wake: a dynamic character that never
// sleeps, with its mass and its drive joint back, which stands where it rested and walks and jumps like a twin that
// never rested.
@(test)
character_rest_and_wake_round_trip :: proc(t: ^testing.T) {
	scene := settled({0, 1.5, 0})
	defer physics.destroy(scene.world)
	twin := settled({0, 1.5, 0})
	defer physics.destroy(twin.world)
	world, character := scene.world, &scene.character
	mass := physics.body_mass(world, character.body)
	standing := physics.body_position(world, character.body)
	testing.expect(t, physics.character_grounded(character))

	physics.character_rest(world, character)
	testing.expect(t, physics.character_resting(character))
	testing.expect_value(t, physics.body_type(world, character.body), physics.Body_Type.Kinematic)
	testing.expect(t, !physics.body_is_awake(world, character.body))
	testing.expect(t, character.move_joint == {} && character.pogo == {})
	testing.expect_value(t, physics.body_linear_velocity(world, character.body), [3]f32{})
	rested := character^
	physics.character_rest(world, character) // a second rest does nothing
	testing.expect_value(t, character^, rested)
	for i in 0 ..< 128 {
		jumped := physics.character_update(world, character, character_def(), {1, 0}, i % 8 == 0, 1)
		testing.expect(t, !jumped)
		steps(world, 1)
	}
	run(&twin, 128) // the twin stands meanwhile
	testing.expect_value(t, physics.body_position(world, character.body), standing)
	testing.expect(t, !physics.body_is_awake(world, character.body))
	testing.expect(t, character.move_joint == {} && character.pogo == {})

	physics.character_wake(world, character, character_def())
	testing.expect(t, !physics.character_resting(character))
	testing.expect_value(t, physics.body_type(world, character.body), physics.Body_Type.Dynamic)
	testing.expect(t, physics.body_is_awake(world, character.body))
	testing.expect(t, !physics.body_is_sleep_enabled(world, character.body))
	testing.expect_value(t, physics.body_mass(world, character.body), mass)
	testing.expect(t, physics.joint_valid(world, character.move_joint))
	testing.expect(t, physics.joint_body_a(world, character.move_joint) == physics.world_anchor(world))
	woken := character^
	physics.character_wake(world, character, character_def()) // a second wake does nothing
	testing.expect_value(t, character^, woken)

	// Long enough that a body allowed to sleep would have: it stands where it rested, awake, on its pogo.
	run(&scene, 128)
	run(&twin, 128)
	pos := physics.body_position(world, character.body)
	testing.expectf(t, near(pos, standing, 0.01), "stands at %v after its wake, rested at %v", pos, standing)
	testing.expect(t, physics.body_is_awake(world, character.body))
	testing.expect(t, physics.character_grounded(character) && physics.joint_valid(world, character.pogo))
	// Then it walks and jumps as the twin does.
	worst: f32 = 0
	for i in 0 ..< 160 {
		move := i < 64 ? [2]f32{1, 0} : [2]f32{0, 1}
		jumped := physics.character_update(world, character, character_def(), move, i == 70, 1)
		twin_jumped := physics.character_update(twin.world, &twin.character, character_def(), move, i == 70, 1)
		testing.expect_value(t, jumped, twin_jumped)
		steps(world, 1)
		steps(twin.world, 1)
		delta := physics.body_position(world, character.body) - physics.body_position(twin.world, twin.character.body)
		worst = max(worst, abs(delta.x), abs(delta.y), abs(delta.z))
	}
	testing.expectf(t, worst < 0.02, "the woken character strays %v m from its twin", worst)
	testing.expect(t, physics.character_grounded(character))
}

// A character rested in the air stays there (it doesn't fall), and falls and lands once woken. Limp across a rest:
// kept, so the wake's drive has no force; teleported while resting, it rests at the new spot.
@(test)
a_resting_character_stays_put :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ground(world)
	character: physics.Character
	physics.character_create(world, &character, character_def(), {0, 5, 0})
	steps(world, 8) // falling
	physics.character_rest(world, &character)
	testing.expect_value(t, physics.body_linear_velocity(world, character.body), [3]f32{})
	aloft := physics.body_position(world, character.body)
	steps(world, 64)
	testing.expect_value(t, physics.body_position(world, character.body), aloft)

	physics.character_teleport(world, &character, {3, 4, 3})
	testing.expect(t, physics.character_resting(&character))
	steps(world, 64)
	testing.expect_value(t, physics.body_position(world, character.body), [3]f32{3, 4, 3})
	testing.expect(t, !physics.body_is_awake(world, character.body))

	physics.character_set_limp(world, &character, true)
	physics.character_wake(world, &character, character_def())
	testing.expect(t, .Limp in character.flags)
	testing.expect_value(t, physics.mover_joint_max_velocity_force(world, character.move_joint), 0)
	physics.character_set_limp(world, &character, false)
	for _ in 0 ..< 128 {
		physics.character_update(world, &character, character_def(), {}, false, 1)
		steps(world, 1)
	}
	pos := physics.body_position(world, character.body)
	testing.expectf(t, pos.y > 1.1 && pos.y < 1.6 && abs(pos.x - 3) < 0.01, "landed at %v", pos)
	testing.expect(t, physics.character_grounded(&character))
}

// A rest forgets the motion it was in: a jump pressed just before it (buffered) doesn't fire after the wake, and the
// woken body starts from a standstill with its drive's full force.
@(test)
a_rest_forgets_its_motion :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ground(world)
	def := character_def()
	character: physics.Character
	physics.character_create(world, &character, def, {0, 1.3, 0})
	// Its first update: no coyote time yet, so the press is buffered; then it finds the ground.
	testing.expect(t, !physics.character_update(world, &character, def, {}, true, 1))
	steps(world, 1)
	physics.character_rest(world, &character)
	steps(world, 64)
	physics.character_wake(world, &character, def)
	testing.expect_value(t, physics.mover_joint_max_velocity_force(world, character.move_joint), def.max_ground_force)
	testing.expect_value(t, physics.body_linear_velocity(world, character.body), [3]f32{})
	for _ in 0 ..< 64 {
		testing.expect(t, !physics.character_update(world, &character, def, {}, false, 1))
		steps(world, 1)
	}
	testing.expect(t, physics.character_grounded(&character))
}

RESTING_CROWD :: 16

// What resting characters cost a step: nothing awake, no joint, no contact, so a world of them steps as its statics
// alone do (`uni bench`'s physics row times it).
@(test)
resting_characters_cost_a_step_nothing :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ground(world)
	crowd: [RESTING_CROWD]physics.Character
	for &character, i in crowd {
		physics.character_create(world, &character, character_def(), {f32(i % 4) * 2, 1.5, f32(i / 4) * 2})
	}
	for _ in 0 ..< 128 {
		for &character in crowd do physics.character_update(world, &character, character_def(), {}, false, 1)
		steps(world, 1)
	}
	testing.expect_value(t, box3d.World_GetAwakeBodyCount(world.id), RESTING_CROWD)
	testing.expect_value(t, box3d.World_GetCounters(world.id).jointCount, 2 * RESTING_CROWD)
	for &character in crowd do physics.character_rest(world, &character)
	testing.expect_value(t, box3d.World_GetAwakeBodyCount(world.id), 0) // asleep from the rest on
	for _ in 0 ..< 64 {
		for &character in crowd do physics.character_update(world, &character, character_def(), {}, false, 1)
		steps(world, 1)
	}
	counters := box3d.World_GetCounters(world.id)
	testing.expect_value(t, box3d.World_GetAwakeBodyCount(world.id), 0)
	testing.expect_value(t, counters.jointCount, 0)
	testing.expect_value(t, counters.contactCount, 0)
}

// A resting character is a wall to a walker and to a thrown box (neither moves it), the walker's touch keeps it awake
// and it sleeps again once the walker leaves, and a ray, a shot rewound and a ray sideways find it.
@(test)
a_resting_character_blocks_and_is_hit :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ground(world)
	def := character_def()
	sleeper, walker: physics.Character
	physics.character_create(world, &sleeper, def, {0, 1.5, 0})
	physics.character_create(world, &walker, def, {-3, 1.5, 0})
	for _ in 0 ..< 128 {
		physics.character_update(world, &sleeper, def, {}, false, 1)
		physics.character_update(world, &walker, def, {}, false, 1)
		steps(world, 1)
	}
	physics.character_rest(world, &sleeper)
	resting := physics.body_position(world, sleeper.body)

	touched := false
	for _ in 0 ..< 192 {
		physics.character_update(world, &walker, def, {1, 0}, false, 1)
		steps(world, 1)
		walker_x := physics.body_position(world, walker.body).x
		testing.expectf(
			t,
			walker_x < resting.x - 2 * def.radius + 0.05,
			"the walker is through the sleeper: x %v",
			walker_x,
		)
		touched ||= physics.body_is_awake(world, sleeper.body)
	}
	testing.expect(t, touched) // the walker's touch woke it in Box3D
	testing.expect_value(t, physics.body_position(world, sleeper.body), resting)
	testing.expectf(
		t,
		abs(physics.body_linear_velocity(world, walker.body).x) < 0.1,
		"the walker isn't stopped: %v",
		physics.body_linear_velocity(world, walker.body),
	)

	down, found := physics.world_cast_ray_closest(world, resting + {0, 3, 0}, {0, -4, 0})
	testing.expect(t, found && down.body == physics.link(sleeper.body))
	shot, shot_found := physics.world_cast_ray_closest_rewound(world, resting + {0, 3, 0}, {0, -4, 0}, 2.0 / HZ)
	testing.expect(t, shot_found && shot.body == physics.link(sleeper.body) && shot.point == down.point)
	walker_pos := physics.body_position(world, walker.body)
	side, side_found := physics.world_cast_ray_closest(
		world,
		walker_pos,
		{4, 0, 0},
		ignore = physics.link(walker.body),
	)
	testing.expect(t, side_found && side.body == physics.link(sleeper.body))

	for _ in 0 ..< 128 {
		physics.character_update(world, &walker, def, {-1, 0}, false, 1)
		steps(world, 1)
	}
	testing.expect(t, !physics.body_is_awake(world, sleeper.body)) // asleep again once they parted

	thrown, _ := box(world, {-3, 1.4, 0}, {0.3, 0.3, 0.3}, .Dynamic, category = CAT_BOX, density = 400)
	physics.body_set_linear_velocity(world, thrown, {14, 0, 0})
	steps(world, 64)
	testing.expect_value(t, physics.body_position(world, sleeper.body), resting)
	testing.expect(t, physics.body_position(world, thrown).x < resting.x) // it bounced off
}

// ---- a rest and a wake under rollback: a game whose sleeper rests and wakes twice while a walker runs into it

REST_TICKS :: [4]u32{40, 100, 150, 200} // rest, wake, rest, wake

Rest_State :: struct {
	sleeper: physics.Character,
	walker:  physics.Character,
	players: sim.Players(u32, sim.No_Profile, Rig_Input, 2),
}

Rest_Game :: sim.Game(
	Rest_State,
	Rig_Input,
	Rig_World,
	Library_Events,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	2,
)

REST_GAME := Rest_Game {
	name = "rest",
	version = "1",
	tick_hz = HZ,
	world_create = proc(_: u64, _: []sim.Level_File, _: sim.No_Setup) -> ^Rig_World {
		rig_world := new(Rig_World)
		rig_world.phys = new_world()
		ground(rig_world.phys)
		return rig_world
	},
	world_destroy = RIG.world_destroy,
	extra = proc(rig_world: ^Rig_World) -> sim.Extra {return physics.extra(rig_world.phys, Rest_State)},
	init = proc(t: ^sim.Tick(Rest_Game)) {
		physics.character_create(t.world.phys, &t.state.sleeper, character_def(), {0, 1.5, 0})
		physics.character_create(t.world.phys, &t.state.walker, character_def(), {-3, 1.5, 0.2})
	},
	tick = proc(t: ^sim.Tick(Rest_Game)) {
		world := t.world.phys
		switch t.number {
		case REST_TICKS[0], REST_TICKS[2]:
			physics.character_rest(world, &t.state.sleeper)
		case REST_TICKS[1], REST_TICKS[3]:
			physics.character_wake(world, &t.state.sleeper, character_def())
		}
		// The walker runs at the sleeper for a second and away for half of one, jumping now and then.
		gap := physics.body_position(world, t.state.sleeper.body) - physics.body_position(world, t.state.walker.body)
		length := dmath.sqrt(gap.x * gap.x + gap.z * gap.z)
		move := [2]f32{gap.x / length, gap.z / length}
		if (t.number / 32) % 3 == 2 do move = -move
		physics.character_update(world, &t.state.sleeper, character_def(), {}, false, 1)
		physics.character_update(world, &t.state.walker, character_def(), move, t.number % 61 == 0, 1)
		physics.step(world)
	},
}

// The forward ticks on which the walker pressed against the resting sleeper.
rest_touches: int

rest_inputs :: proc(tick: u32) -> sim.Inputs(Rest_Game) {
	return {}
}

// Every rest and wake is re-simulated (the sync-test rolls back SYNC_WINDOW ticks after every tick) and must give the
// same checksums; check_refs passes after every restore, a snapshot taken while it rests resumes bit-exactly across its
// second wake, and the run really rested and woke it, and the walker really ran into it while it rested.
@(test)
a_rest_and_a_wake_roll_back :: proc(t: ^testing.T) {
	ticks := REST_TICKS
	rest_touches = 0
	synctest_and_resume(t, &REST_GAME, 1, ticks[3] - 20, rest_inputs, each = proc(t: ^testing.T, simulation: ^sim.Sim(Rest_Game)) {
			ticks := REST_TICKS
			sleeper := &simulation.state.sleeper
			resting := (simulation.tick >= ticks[0] && simulation.tick < ticks[1]) || simulation.tick >= ticks[2]
			testing.expectf(t, physics.character_resting(sleeper) == resting, "tick %d: resting %v", simulation.tick, physics.character_resting(sleeper))
			type := physics.body_type(simulation.world.phys, sleeper.body)
			testing.expectf(t, (type == .Kinematic) == resting, "tick %d: a %v body", simulation.tick, type)
			gap := physics.body_position(simulation.world.phys, simulation.state.walker.body) - physics.body_position(simulation.world.phys, sleeper.body)
			if resting && gap.x * gap.x + gap.z * gap.z < 0.65 * 0.65 do rest_touches += 1
		})
	testing.expectf(t, rest_touches > 10, "the walker touched the resting sleeper on %d ticks", rest_touches)
}
