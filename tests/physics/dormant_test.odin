// src/physics/README.md, Character: a dormant character (physics.character_set_dormant). What going dormant keeps and
// clears, that it costs a step nothing without freezing what stands on it, how other bodies, queries and sensors meet
// it, and that going dormant and waking roll back, re-simulate and resume from a snapshot bit-exactly.
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

// Dormant: kinematic, asleep, no joints, deaf to its input and exactly still. Woken: a dynamic character that never
// sleeps, with its mass back, whose next update makes its drive and pogo joints again, which stands where it lay and
// walks and jumps like a twin that never went dormant.
@(test)
character_dormant_round_trip :: proc(t: ^testing.T) {
	scene := settled({0, 1.5, 0})
	defer physics.destroy(scene.world)
	twin := settled({0, 1.5, 0})
	defer physics.destroy(twin.world)
	world, character := scene.world, &scene.character
	mass := physics.body_mass(world, character.body)
	standing := physics.body_position(world, character.body)
	testing.expect(t, physics.character_grounded(character))

	physics.character_set_dormant(world, character, true)
	testing.expect(t, physics.character_dormant(character))
	testing.expect(t, physics.character_grounded(character)) // as its last update found
	testing.expect_value(t, physics.body_type(world, character.body), physics.Body_Type.Kinematic)
	testing.expect(t, !physics.body_is_awake(world, character.body))
	testing.expect(t, character.move_joint == {} && character.pogo == {})
	dormant := character^
	physics.character_set_dormant(world, character, true) // asking again does nothing
	testing.expect_value(t, character^, dormant)
	for i in 0 ..< 128 {
		jumped := physics.character_update(world, character, character_def(), {1, 0}, i % 8 == 0, 1)
		testing.expect(t, !jumped)
		steps(world, 1)
	}
	run(&twin, 128) // the twin stands meanwhile
	testing.expect_value(t, physics.body_position(world, character.body), standing)
	testing.expect(t, !physics.body_is_awake(world, character.body))
	testing.expect(t, character.move_joint == {} && character.pogo == {})

	physics.character_set_dormant(world, character, false)
	testing.expect(t, !physics.character_dormant(character))
	testing.expect_value(t, physics.body_type(world, character.body), physics.Body_Type.Dynamic)
	testing.expect(t, physics.body_is_awake(world, character.body))
	testing.expect(t, !physics.body_is_sleep_enabled(world, character.body))
	testing.expect_value(t, physics.body_mass(world, character.body), mass)
	woken := character^
	physics.character_set_dormant(world, character, false) // asking again does nothing
	testing.expect_value(t, character^, woken)
	run(&scene, 1)
	testing.expect(t, physics.joint_valid(world, character.move_joint) && physics.joint_valid(world, character.pogo))
	testing.expect(t, physics.joint_body_a(world, character.move_joint) == physics.world_anchor(world))

	// Long enough that a body allowed to sleep would have: it stands where it lay, awake, on its pogo.
	run(&scene, 127)
	run(&twin, 128)
	pos := physics.body_position(world, character.body)
	testing.expectf(t, near(pos, standing, 0.01), "stands at %v after its wake, lay at %v", pos, standing)
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

// Made dormant in the air, it stays there (it doesn't fall); teleported, it lies at the new spot; woken, it falls and
// lands. Limp is kept across: a woken limp character has no drive until it leaves limp.
@(test)
a_dormant_character_stays_put :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ground(world)
	character: physics.Character
	physics.character_create(world, &character, character_def(), {0, 5, 0})
	steps(world, 8) // falling
	physics.character_set_limp(world, &character, true)
	physics.character_set_dormant(world, &character, true)
	testing.expect_value(t, physics.body_linear_velocity(world, character.body), [3]f32{})
	aloft := physics.body_position(world, character.body)
	steps(world, 64)
	testing.expect_value(t, physics.body_position(world, character.body), aloft)

	physics.character_teleport(world, &character, {3, 4, 3})
	testing.expect(t, physics.character_dormant(&character))
	steps(world, 64)
	testing.expect_value(t, physics.body_position(world, character.body), [3]f32{3, 4, 3})
	testing.expect(t, !physics.body_is_awake(world, character.body))

	physics.character_set_dormant(world, &character, false)
	testing.expect(t, .Limp in character.flags)
	physics.character_update(world, &character, character_def(), {1, 0}, false, 1)
	testing.expect(t, character.move_joint == {})
	physics.character_set_limp(world, &character, false)
	for _ in 0 ..< 128 {
		physics.character_update(world, &character, character_def(), {}, false, 1)
		steps(world, 1)
	}
	pos := physics.body_position(world, character.body)
	testing.expectf(t, pos.y > 1.1 && pos.y < 1.6 && abs(pos.x - 3) < 0.01, "landed at %v", pos)
	testing.expect(t, physics.character_grounded(&character))
}

// Going dormant clears the motion it was in, whichever it was: walking onto a step (drive velocity, coyote time, its
// ground and pogo warm start), mid-jump with a jump buffered (jump state) and sliding on a steep slope (slide time).
// Woken, the body is at a standstill, even after the game moved the dormant body by velocity, and a buffered jump
// doesn't fire.
@(test)
going_dormant_clears_its_motion :: proc(t: ^testing.T) {
	def := character_def()
	{
		scene := settled({0, 1.5, 0})
		defer physics.destroy(scene.world)
		box(scene.world, {6, 0.15, 0}, {4, 0.15, 2}) // a 0.3 m step at x = 2
		character := &scene.character
		for _ in 0 ..< 64 {
			physics.character_update(scene.world, character, def, {1, 0}, false, 1)
			steps(scene.world, 1)
			if character.pogo_impulse != 0 || character.pogo_velocity != 0 do break // onto the step
		}
		testing.expect(t, character.pogo_impulse != 0 || character.pogo_velocity != 0)
		testing.expect(t, character.coyote > 0 && character.velocity.x > 1 && character.ground != {})
		physics.character_set_dormant(scene.world, character, true)
		testing.expect_value(t, character.velocity, [3]f32{})
		testing.expect_value(t, character.coyote, 0)
		testing.expect(t, character.ground == {} && character.pogo_impulse == 0 && character.pogo_velocity == 0)
	}
	{
		scene := settled({0, 1.5, 0})
		defer physics.destroy(scene.world)
		character := &scene.character
		testing.expect(t, physics.character_update(scene.world, character, def, {}, true, 1))
		for _ in 0 ..< 8 {
			steps(scene.world, 1)
			physics.character_update(scene.world, character, def, {}, true, 1) // buffered: in the air
		}
		testing.expect(t, .Jumping in character.flags && character.jump_ticks > 0 && character.jump_buffer > 0)
		physics.character_set_dormant(scene.world, character, true)
		testing.expect(t, .Jumping not_in character.flags)
		testing.expect_value(t, character.jump_ticks, 0)
		testing.expect_value(t, character.jump_buffer, 0)
		// The game moves the dormant body by velocity (a kinematic body keeps it); the wake stops it.
		physics.body_set_linear_velocity(scene.world, character.body, {2, 0, 0})
		x0 := physics.body_position(scene.world, character.body).x
		steps(scene.world, 32)
		testing.expect(t, physics.body_position(scene.world, character.body).x > x0 + 0.9)
		physics.character_set_dormant(scene.world, character, false)
		testing.expect_value(t, physics.body_linear_velocity(scene.world, character.body), [3]f32{})
		for _ in 0 ..< 64 {
			testing.expect(t, !physics.character_update(scene.world, character, def, {}, false, 1))
			steps(scene.world, 1)
		}
		testing.expect(t, physics.character_grounded(character))
	}
	{
		world := new_world()
		defer physics.destroy(world)
		ground(world)
		box(world, {0, 1, 0}, {3, 0.2, 2}, rot = {0, 0, 0.42261826, 0.90630779}) // 50° about z
		character: physics.Character
		physics.character_create(world, &character, def, {0, 3, 0})
		for _ in 0 ..< 64 {
			physics.character_update(world, &character, def, {}, false, 1)
			steps(world, 1)
			if character.time_sliding > 0 do break
		}
		testing.expect(t, character.time_sliding > 0)
		physics.character_set_dormant(world, &character, true)
		testing.expect_value(t, character.time_sliding, 0)
	}
}

// A character standing on a dormant one keeps walking, whether its drive takes the dormant capsule for a platform or
// not (Character_Def.platform_material): going dormant doesn't sleep the bodies joined to it. The dormant one, made so
// while walking, stays exactly put under the stander, and falls asleep on its own once the stander is gone.
@(test)
a_stander_on_a_dormant_character_keeps_walking :: proc(t: ^testing.T) {
	for platform_material in ([]u64{0, 99}) {
		scene := settled({0, 1.5, 0})
		defer physics.destroy(scene.world)
		world, base := scene.world, &scene.character
		base_def := character_def()
		top_def := character_def()
		top_def.platform_material = platform_material
		top: physics.Character
		physics.character_create(world, &top, top_def, physics.body_position(world, base.body) + [3]f32{0, 2.2, 0})
		for i in 0 ..< 192 {
			move := i < 160 ? [2]f32{} : [2]f32{0.3, 0}
			physics.character_update(world, base, base_def, move, false, 1)
			physics.character_update(world, &top, top_def, move, false, 1)
			steps(world, 1)
		}
		testing.expect(t, top.ground == physics.link(base.body))
		testing.expect(t, physics.body_linear_velocity(world, base.body).x > 0.5)
		physics.character_set_dormant(world, base, true)
		testing.expectf(
			t,
			physics.body_is_awake(world, top.body),
			"material %d: the stander sleeps",
			platform_material,
		)
		lying := physics.body_position(world, base.body)
		start := physics.body_position(world, top.body)
		for _ in 0 ..< 96 {
			physics.character_update(world, base, base_def, {}, false, 1)
			physics.character_update(world, &top, top_def, {1, 0}, false, 1)
			steps(world, 1)
			testing.expect_value(t, physics.body_position(world, base.body), lying)
		}
		walked := physics.body_position(world, top.body).x - start.x
		testing.expectf(t, walked > 1.5, "material %d: the stander walked %v m", platform_material, walked)
		for _ in 0 ..< 128 {
			physics.character_update(world, &top, top_def, {1, 0}, false, 1)
			steps(world, 1)
		}
		testing.expectf(t, !physics.body_is_awake(world, base.body), "material %d: still awake", platform_material)
	}
}

DORMANT_CROWD :: 16

// What dormant characters cost a step: nothing awake, no joint, no contact, so a world of them steps as its statics
// alone do (`uni bench`'s physics row times it).
@(test)
dormant_characters_cost_a_step_nothing :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ground(world)
	crowd: [DORMANT_CROWD]physics.Character
	for &character, i in crowd {
		physics.character_create(world, &character, character_def(), {f32(i % 4) * 2, 1.5, f32(i / 4) * 2})
	}
	for _ in 0 ..< 128 {
		for &character in crowd do physics.character_update(world, &character, character_def(), {}, false, 1)
		steps(world, 1)
	}
	testing.expect_value(t, box3d.World_GetAwakeBodyCount(world.id), DORMANT_CROWD)
	testing.expect_value(t, box3d.World_GetCounters(world.id).jointCount, 2 * DORMANT_CROWD)
	for &character in crowd do physics.character_set_dormant(world, &character, true)
	testing.expect_value(t, box3d.World_GetAwakeBodyCount(world.id), 0) // asleep from the first tick
	for _ in 0 ..< 64 {
		for &character in crowd do physics.character_update(world, &character, character_def(), {}, false, 1)
		steps(world, 1)
	}
	counters := box3d.World_GetCounters(world.id)
	testing.expect_value(t, box3d.World_GetAwakeBodyCount(world.id), 0)
	testing.expect_value(t, counters.jointCount, 0)
	testing.expect_value(t, counters.contactCount, 0)
}

// A dormant character is a wall to a walker and to a thrown box (neither moves it), the walker's touch keeps it awake
// and it sleeps again once the walker leaves, and a ray, a shot rewound and a ray sideways find it.
@(test)
a_dormant_character_blocks_and_is_hit :: proc(t: ^testing.T) {
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
	physics.character_set_dormant(world, &sleeper, true)
	lying := physics.body_position(world, sleeper.body)

	touched := false
	for _ in 0 ..< 192 {
		physics.character_update(world, &walker, def, {1, 0}, false, 1)
		steps(world, 1)
		walker_x := physics.body_position(world, walker.body).x
		testing.expectf(
			t,
			walker_x < lying.x - 2 * def.radius + 0.05,
			"the walker is through the sleeper: x %v",
			walker_x,
		)
		touched ||= physics.body_is_awake(world, sleeper.body)
	}
	testing.expect(t, touched) // the walker's touch woke it in Box3D
	testing.expect_value(t, physics.body_position(world, sleeper.body), lying)
	testing.expectf(
		t,
		abs(physics.body_linear_velocity(world, walker.body).x) < 0.1,
		"the walker isn't stopped: %v",
		physics.body_linear_velocity(world, walker.body),
	)

	down, found := physics.world_cast_ray_closest(world, lying + {0, 3, 0}, {0, -4, 0})
	testing.expect(t, found && down.body == physics.link(sleeper.body))
	shot, shot_found := physics.world_cast_ray_closest_rewound(world, lying + {0, 3, 0}, {0, -4, 0}, 2.0 / HZ)
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
	testing.expect_value(t, physics.body_position(world, sleeper.body), lying)
	testing.expect(t, physics.body_position(world, thrown).x < lying.x) // it bounced off
}

// The sensor events of `world`'s last step whose visitor is `body`: how many begin and how many end.
sensor_events_of :: proc(
	world: ^physics.World,
	body: physics.Body_Ref,
	events: ^[dynamic]physics.Sensor_Event,
) -> (
	begins, ends: int,
) {
	physics.world_sensor_events(world, events)
	for event in events {
		if event.visitor.body != physics.link(body) do continue
		if event.kind == .Begin do begins += 1
		else do ends += 1
	}
	return
}

// Sensors see a dormant character as any body: a static sensor it goes dormant in keeps it (no End), one it is
// teleported into begins it, and a kinematic sensor moving over it begins it.
@(test)
a_dormant_character_and_sensors :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ground(world)
	def := character_def()
	def.sensor_events = true
	sensor_def := physics.default_shape_def()
	sensor_def.is_sensor = true
	sensor_def.enable_sensor_events = true
	box(world, {0, 1.5, 0}, {1, 1, 1}, .Static, 30, sensor_def)
	box(world, {6, 1.5, 0}, {1, 1, 1}, .Static, 31, sensor_def)
	sweeper, _ := box(world, {-6, 1.5, 6}, {0.5, 1, 0.5}, .Kinematic, 32, sensor_def)
	events: [dynamic]physics.Sensor_Event
	defer delete(events)
	character: physics.Character
	physics.character_create(world, &character, def, {0, 1.5, 0})
	begins, ends: int
	for _ in 0 ..< 64 {
		physics.character_update(world, &character, def, {}, false, 1)
		steps(world, 1)
		b, e := sensor_events_of(world, character.body, &events)
		begins, ends = begins + b, ends + e
	}
	testing.expect(t, begins == 1 && ends == 0)

	physics.character_set_dormant(world, &character, true)
	for _ in 0 ..< 64 {
		steps(world, 1)
		b, e := sensor_events_of(world, character.body, &events)
		begins, ends = begins + b, ends + e
	}
	testing.expectf(t, begins == 1 && ends == 0, "dormant in a sensor: %d begins, %d ends", begins, ends)

	physics.character_teleport(world, &character, {6, 1.5, 0})
	steps(world, 1)
	begins, ends = sensor_events_of(world, character.body, &events)
	testing.expectf(t, begins == 1 && ends == 1, "teleported into another: %d begins, %d ends", begins, ends)

	physics.character_teleport(world, &character, {-6, 1.5, 0})
	steps(world, 1)
	sensor_events_of(world, character.body, &events)
	physics.body_set_linear_velocity(world, sweeper, {0, 0, -6})
	begins = 0
	for _ in 0 ..< 96 {
		steps(world, 1)
		b, _ := sensor_events_of(world, character.body, &events)
		begins += b
	}
	testing.expectf(t, begins == 1, "a moving sensor over it: %d begins", begins)
}

// ---- dormancy under rollback: a game whose sleeper goes dormant and wakes twice while a walker runs into it

DORMANT_TICKS :: [4]u32{40, 100, 150, 200} // dormant, woken, dormant, woken

Dormant_State :: struct {
	sleeper: physics.Character,
	walker:  physics.Character,
	players: sim.Players(u32, sim.No_Profile, Rig_Input, 2),
}

Dormant_Game :: sim.Game(
	Dormant_State,
	Rig_Input,
	Rig_World,
	Library_Events,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	2,
)

DORMANT_GAME := Dormant_Game {
	name = "dormant",
	version = "1",
	tick_hz = HZ,
	world_create = proc(_: u64, _: []sim.Level_File, _: sim.No_Setup) -> ^Rig_World {
		rig_world := new(Rig_World)
		rig_world.phys = new_world()
		ground(rig_world.phys)
		return rig_world
	},
	world_destroy = RIG.world_destroy,
	extra = proc(rig_world: ^Rig_World) -> sim.Extra {return physics.extra(rig_world.phys, Dormant_State)},
	init = proc(t: ^sim.Tick(Dormant_Game)) {
		physics.character_create(t.world.phys, &t.state.sleeper, character_def(), {0, 1.5, 0})
		physics.character_create(t.world.phys, &t.state.walker, character_def(), {-3, 1.5, 0.2})
	},
	tick = proc(t: ^sim.Tick(Dormant_Game)) {
		world := t.world.phys
		switch t.number {
		case DORMANT_TICKS[0], DORMANT_TICKS[2]:
			physics.character_set_dormant(world, &t.state.sleeper, true)
		case DORMANT_TICKS[1], DORMANT_TICKS[3]:
			physics.character_set_dormant(world, &t.state.sleeper, false)
		}
		// The walker runs at the sleeper for a second and away for half of one, jumping now and then (onto it too).
		gap := physics.body_position(world, t.state.sleeper.body) - physics.body_position(world, t.state.walker.body)
		length := dmath.sqrt(gap.x * gap.x + gap.z * gap.z)
		move := [2]f32{gap.x / length, gap.z / length}
		if (t.number / 32) % 3 == 2 do move = -move
		physics.character_update(world, &t.state.sleeper, character_def(), {}, false, 1)
		physics.character_update(world, &t.state.walker, character_def(), move, t.number % 61 == 0, 1)
		physics.step(world)
	},
}

dormant_inputs :: proc(tick: u32) -> sim.Inputs(Dormant_Game) {
	return {}
}

// The forward ticks on which the walker pressed against the dormant sleeper.
dormant_touches: int

// Every change of dormancy is re-simulated (the sync-test rolls back SYNC_WINDOW ticks after every tick) and must give
// the same checksums; check_refs passes after every restore, a snapshot taken while it is dormant resumes bit-exactly
// across its second wake, the run really made it dormant and woke it, and the walker really ran into it while dormant.
@(test)
dormancy_rolls_back :: proc(t: ^testing.T) {
	ticks := DORMANT_TICKS
	dormant_touches = 0
	synctest_and_resume(t, &DORMANT_GAME, 1, ticks[3] - 20, dormant_inputs, each = proc(t: ^testing.T, simulation: ^sim.Sim(Dormant_Game)) {
			ticks := DORMANT_TICKS
			sleeper := &simulation.state.sleeper
			dormant := (simulation.tick >= ticks[0] && simulation.tick < ticks[1]) || simulation.tick >= ticks[2]
			testing.expectf(t, physics.character_dormant(sleeper) == dormant, "tick %d: dormant %v", simulation.tick, physics.character_dormant(sleeper))
			type := physics.body_type(simulation.world.phys, sleeper.body)
			testing.expectf(t, (type == .Kinematic) == dormant, "tick %d: a %v body", simulation.tick, type)
			gap := physics.body_position(simulation.world.phys, simulation.state.walker.body) - physics.body_position(simulation.world.phys, sleeper.body)
			if dormant && gap.x * gap.x + gap.z * gap.z < 0.65 * 0.65 do dormant_touches += 1
		})
	testing.expectf(t, dormant_touches > 10, "the walker touched the dormant sleeper on %d ticks", dormant_touches)
}
