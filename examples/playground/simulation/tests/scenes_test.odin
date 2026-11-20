// Every scene as a headless determinism test (a rollback every tick, the extra's check after each restore, the
// scripted players using every tool), each with the facts its sample is about; and the tools and the scene change on
// inputs of the test's own.
package test_playground

import "core:testing"

import "unified:dmath"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:physics"
import "unified:sim"

import g "../playground"

SCENE_TICKS :: 600 when scenarios.LONG else 160

// A sync-tested run of `scene` with four scripted players.
@(private = "file")
scene_run :: proc(scene: g.Scene, seated := g.PLAYERS) -> headless.Run(g.Game) {
	return headless.run_begin(&g.GAME, 3, setup = g.Setup{scene = scene}, seated = seated)
}

@(private = "file")
play :: proc(run: ^headless.Run(g.Game), ticks: int) {
	for _ in 0 ..< ticks do headless.run_scripted(run, g.PLAYERS)
}

@(private = "file")
count_role :: proc(state: ^g.State, role: g.Role) -> (count: int) {
	props := sim.iterate(&state.props)
	for prop in sim.next(&props) do count += int(prop.role == role)
	return
}

@(test)
every_scene_is_deterministic :: proc(t: ^testing.T) {
	for scene in g.Scene {
		run := scene_run(scene)
		defer headless.run_end(&run)
		built := count_role(&run.simulation.state, .Scene) // the scene as built (bodies may go below KILL_Y later)
		play(&run, SCENE_TICKS)
		if !scenarios.expect_synced(t, &run) do testing.expectf(t, false, "%v", scene)
		state := &run.simulation.state
		testing.expect_value(t, state.level.id, scene)
		switch scene {
		case .Pyramid:
			testing.expect_value(t, built, g.PYRAMID_ROWS * (g.PYRAMID_ROWS + 1) / 2)
		case .Dominoes:
			testing.expect_value(t, built, g.DOMINO_COUNT + 1)
		case .Bridge, .Wind, .Bounce_House, .Conveyor:
			testing.expectf(t, built >= 8, "%v built", scene)
		case .Driving:
			for &car in state.cars do testing.expect(t, car.chassis != {})
		case .Ragdolls:
			for &ragdoll in state.ragdolls do testing.expect(t, ragdoll.bones[.Pelvis] != {})
		case .Bullets:
			testing.expectf(
				t,
				headless.run_events(&run, g.Event_Shot) >= SCENE_TICKS / g.TURRET_EVERY_TICKS,
				"the turret fires",
			)
		case .Sensors:
			visits: u32
			for sensor in state.sensors do visits += sensor.visits
			testing.expectf(
				t,
				visits > 0 && headless.run_events(&run, g.Event_Sensor_Entered) > 0,
				"bodies entered the sensors",
			)
		case .Breakable:
			testing.expect_value(t, built, g.WALL_ROWS * g.WALL_COLUMNS + 14)
		case .Rain:
			testing.expectf(t, count_role(state, .Rain) >= SCENE_TICKS / g.RAIN_EVERY_TICKS - 1, "it rains")
		}
	}
}

// One player's input for a test: looking along `look` (a direction), holding `buttons`.
@(private = "file")
inputs_of :: proc(look: [3]f32, buttons := g.Buttons{}, stick := [3]i8{}) -> (inputs: [g.PLAYERS]g.Input) {
	inputs[0] = {
		right   = stick.x,
		up      = stick.y,
		forward = stick.z,
		buttons = buttons,
		aim     = dmath.aim_toward(look),
	}
	return
}

// The grab pulls the body under the aim toward the camera's grab point and lets go on release; a reset scene puts
// everything back.
@(test)
the_grab_pulls_and_the_reset_rebuilds :: proc(t: ^testing.T) {
	run := scene_run(.Pyramid, seated = 1)
	defer headless.run_end(&run)
	camera := sim.slot_data(&run.simulation.state.players, 0).pos
	at := [3]f32{0, 0.4, 0} // the bottom row's middle box
	look := at - camera
	headless.run_step(&run, inputs_of(look, {.Grab}))
	data := sim.slot_data(&run.simulation.state.players, 0)
	if !testing.expect(t, data.grab != {}, "grabbed") do return
	held, _ := physics.resolve(run.simulation.world.phys, data.held_body)
	for _ in 0 ..< 60 do headless.run_step(&run, inputs_of(look, {.Grab, .Closer}))
	pulled := physics.body_position(run.simulation.world.phys, held)
	testing.expectf(t, pulled.z > 1, "pulled out toward the camera: %v", pulled)
	headless.run_step(&run, inputs_of(look))
	testing.expect(t, sim.slot_data(&run.simulation.state.players, 0).grab == {}, "let go")
	testing.expect_value(t, headless.run_events(&run, g.Event_Released), 1)

	headless.run_command(&run, inputs_of(look), 0, g.Command_Scene{scene = .Pyramid})
	testing.expect_value(t, headless.run_events(&run, g.Event_Scene_Entered), 1)
	testing.expect_value(t, count_role(&run.simulation.state, .Scene), g.PYRAMID_ROWS * (g.PYRAMID_ROWS + 1) / 2)
	scenarios.expect_synced(t, &run)
}

// Shots fly as bullets and are gone after SHOT_TICKS; spawns come in front of the camera; an explosion throws the
// pyramid about; the tools wait out their cooldown.
@(test)
shoot_spawn_explode :: proc(t: ^testing.T) {
	run := scene_run(.Pyramid, seated = 1)
	defer headless.run_end(&run)
	look := [3]f32{0, -0.2, -1}
	headless.run_command(&run, inputs_of(look), 0, g.Command_Shoot{})
	headless.run_command(&run, inputs_of(look), 0, g.Command_Shoot{}) // in the cooldown: dropped
	testing.expect_value(t, headless.run_events(&run, g.Event_Shot), 1)
	testing.expect_value(t, count_role(&run.simulation.state, .Bullet), 1)
	for _ in 0 ..< g.SHOT_TICKS do headless.run_step(&run, inputs_of(look))
	testing.expect_value(t, count_role(&run.simulation.state, .Bullet), 0)

	for shape in g.Shape {
		headless.run_command(&run, inputs_of(look), 0, g.Command_Spawn{shape = shape})
		for _ in 0 ..< g.SPAWN_COOLDOWN_TICKS do headless.run_step(&run, inputs_of(look))
	}
	testing.expect_value(t, count_role(&run.simulation.state, .Spawned), len(g.Shape))

	world := run.simulation.world.phys
	headless.run_command(
		&run,
		inputs_of({0, 0.4, 0} - sim.slot_data(&run.simulation.state.players, 0).pos),
		0,
		g.Command_Explode{},
	)
	testing.expect_value(t, headless.run_events(&run, g.Event_Exploded), 1)
	for _ in 0 ..< 8 do headless.run_step(&run, inputs_of(look))
	testing.expectf(t, physics.world_awake_body_count(world) > 50, "the pyramid blown about")
	scenarios.expect_synced(t, &run)
}

// In Driving, Command_Drive takes the nearest car; the stick's forward drives it along its +x and its right steers it right,
// the camera riding behind; Command_Drive again gets out.
@(test)
a_car_drives_forward :: proc(t: ^testing.T) {
	run := scene_run(.Driving, seated = 1)
	defer headless.run_end(&run)
	for _ in 0 ..< 60 do headless.run_step(&run, inputs_of({0, 0, -1})) // the cars settle
	world := run.simulation.world.phys
	data := sim.slot_data(&run.simulation.state.players, 0)
	nearest := -1
	best := f32(1e9)
	for &car, i in run.simulation.state.cars {
		dist := dmath.dist_sq3(physics.body_position(world, car.chassis), data.pos)
		if dist < best do nearest, best = i, dist
	}
	// fly next to that car, then take it
	car := &run.simulation.state.cars[nearest]
	for dmath.dist_sq3(
		    physics.body_position(world, car.chassis),
		    sim.slot_data(&run.simulation.state.players, 0).pos,
	    ) >
	    g.DRIVE_RANGE * g.DRIVE_RANGE {
		to := physics.body_position(world, car.chassis) - sim.slot_data(&run.simulation.state.players, 0).pos
		headless.run_step(&run, inputs_of(to, stick = {0, 0, 127}))
	}
	headless.run_command(&run, inputs_of({0, 0, -1}), 0, g.Command_Drive{})
	if !testing.expect_value(t, sim.slot_data(&run.simulation.state.players, 0).car, i8(nearest)) do return
	start := physics.body_position(world, car.chassis)
	forward := physics.body_world_vector(world, car.chassis, {1, 0, 0})
	for _ in 0 ..< 128 do headless.run_step(&run, inputs_of({0, 0, -1}, stick = {0, 0, 127}))
	moved := physics.body_position(world, car.chassis) - start
	testing.expectf(t, dmath.dot3(moved, forward) > 4, "driven forward: %v along %v", moved, forward)
	// full right: its forward turns toward its right (forward × up)
	right := [3]f32{-forward.z, 0, forward.x}
	for _ in 0 ..< 64 do headless.run_step(&run, inputs_of({0, 0, -1}, stick = {127, 0, 127}))
	turned := physics.body_world_vector(world, car.chassis, {1, 0, 0})
	testing.expectf(t, dmath.dot3(turned, right) > 0.03, "steered right: %v from %v", turned, forward)
	headless.run_command(&run, inputs_of({0, 0, -1}), 0, g.Command_Drive{})
	testing.expect_value(t, sim.slot_data(&run.simulation.state.players, 0).car, i8(-1))
	scenarios.expect_synced(t, &run)
}

// Breakable: an explosion against the wall breaks welds (joint events).
@(test)
an_explosion_breaks_the_wall :: proc(t: ^testing.T) {
	run := scene_run(.Breakable, seated = 1)
	defer headless.run_end(&run)
	look := [3]f32{0, 1.5, 0} - sim.slot_data(&run.simulation.state.players, 0).pos
	headless.run_command(&run, inputs_of(look), 0, g.Command_Explode{})
	for _ in 0 ..< 30 do headless.run_step(&run, inputs_of(look))
	testing.expectf(t, headless.run_events(&run, g.Event_Joint_Broke) > 0, "welds broke")
	scenarios.expect_synced(t, &run)
}
