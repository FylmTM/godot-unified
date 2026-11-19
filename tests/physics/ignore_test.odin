// ignore_contacts / stop_ignoring (src/physics/joint.odin): a pair that doesn't touch while ignored, and touches again
// on stop_ignoring even overlapping at rest; the ignore under rollback, on 1 and 4 workers; world_set_worker_count.
package test_physics

import "core:slice"
import "core:testing"

import "unified:physics"
import "unified:sim"

// Two overlapping spheres in a world without gravity, stepped 30 ticks; `release` runs at tick 10 (nil: never).
// Returns the tick of the first contact Begin between them (0: none).
first_begin :: proc(ignore: bool, release: proc(world: ^physics.World, ignore: ^physics.Filter_Joint_Ref)) -> u32 {
	world := physics.create({tick_hz = HZ, gravity = [3]f32{}})
	defer physics.destroy(world)
	shape_def := physics.default_shape_def()
	shape_def.density = 1
	shape_def.enable_contact_events = true
	a, _ := physics.create_sphere(world, physics.body_def(.Dynamic, {0, 0, 0}), shape_def, 0.25)
	b, _ := physics.create_sphere(world, physics.body_def(.Dynamic, {0.3, 0, 0}), shape_def, 0.25)
	joint: physics.Filter_Joint_Ref
	if ignore do joint = physics.ignore_contacts(world, physics.link(a), physics.link(b))
	events: [dynamic]physics.Contact_Event
	defer delete(events)
	for tick in u32(1) ..= 30 {
		if tick == 10 && release != nil do release(world, &joint)
		physics.step(world)
		physics.world_contact_events(world, &events)
		for event in events do if event.kind == .Begin do return tick
	}
	return 0
}

@(test)
ignore_contacts_until_stopped :: proc(t: ^testing.T) {
	testing.expect_value(t, first_begin(false, nil), 1) // the pair touches at once
	testing.expect_value(t, first_begin(true, nil), 0) // ignored: never
	// stop_ignoring re-pairs the bodies at rest: they touch on the next step
	testing.expect_value(t, first_begin(true, proc(world: ^physics.World, ignore: ^physics.Filter_Joint_Ref) {
			physics.stop_ignoring(world, ignore)
			assert(ignore^ == {})
		}), 10)
	// a bare destroy_joint leaves the resting overlap alone (what stop_ignoring exists for)
	testing.expect_value(t, first_begin(true, proc(world: ^physics.World, ignore: ^physics.Filter_Joint_Ref) {
			physics.destroy_joint(world, &ignore.joint)
		}), 0)
}

@(test)
worker_count_is_settable :: proc(t: ^testing.T) {
	world := physics.create({tick_hz = HZ})
	defer physics.destroy(world)
	testing.expect_value(t, physics.world_worker_count(world), 1)
	physics.world_set_worker_count(world, 4)
	testing.expect_value(t, physics.world_worker_count(world), 4)
	testing.expect_value(t, world.workers, 4)
}

// A game whose thrower (a) and ball (b) ignore each other for 20 ticks of every 48, the ball shoved into the thrower
// meanwhile, and whose ball is destroyed and remade at tick 200 while ignored (the ref goes stale and stop_ignoring
// zeroes it).
Ignore_State :: struct {
	thrower, ball: physics.Body_Ref,
	ignore:        physics.Filter_Joint_Ref,
	begins:        u32,
	_pad:          u32,
	players:       sim.Players(u32, Rig_Input, 2),
}

Ignore_World :: struct {
	phys:   ^physics.World,
	events: [dynamic]physics.Contact_Event,
}

Ignore_Game :: sim.Game(Ignore_State, Rig_Input, Ignore_World, Library_Events, sim.No_Commands, 2)
Ignore_Tick :: sim.Tick(Ignore_Game)

IGNORE_TICKS :: 320

ignore_ball :: proc(world: ^physics.World) -> physics.Body_Ref {
	shape_def := physics.default_shape_def()
	shape_def.density = 1
	shape_def.enable_contact_events = true
	ball, _ := physics.create_sphere(world, physics.body_def(.Dynamic, {1.5, 0.3, 0}), shape_def, 0.25)
	return ball
}

IGNORE := Ignore_Game {
	name = "ignore",
	version = "1",
	tick_hz = HZ,
	world_create = proc(seed: u64, _: []u8) -> ^Ignore_World {
		ignore_world := new(Ignore_World)
		ignore_world.phys = physics.create({tick_hz = HZ})
		ground(ignore_world.phys)
		return ignore_world
	},
	world_destroy = proc(ignore_world: ^Ignore_World) {
		physics.destroy(ignore_world.phys)
		delete(ignore_world.events)
		free(ignore_world)
	},
	extra = proc(ignore_world: ^Ignore_World) -> sim.Extra {return physics.extra(ignore_world.phys, Ignore_State)},
	init = proc(t: ^Ignore_Tick) {
		world := t.world.phys
		t.state.thrower, _ = box(world, {0, 0.5, 0}, {0.4, 0.5, 0.4}, .Dynamic)
		t.state.ball = ignore_ball(world)
	},
	tick = proc(t: ^Ignore_Tick) {
		world := t.world.phys
		if t.number == 200 {
			physics.destroy_body(world, &t.state.ball) // the ignore goes with it: its ref is stale now
			physics.stop_ignoring(world, &t.state.ignore)
			t.state.ball = ignore_ball(world)
		}
		switch t.number % 48 {
		case 4:
			t.state.ignore = physics.ignore_contacts(world, physics.link(t.state.thrower), physics.link(t.state.ball))
		case 8:
			ball := physics.body_position(world, t.state.ball)
			thrower := physics.body_position(world, t.state.thrower)
			physics.body_apply_linear_impulse_to_center(world, t.state.ball, (thrower - ball) * 0.4)
		case 24:
			physics.stop_ignoring(world, &t.state.ignore)
		case 36:
			ball := physics.body_position(world, t.state.ball)
			physics.body_apply_linear_impulse_to_center(world, t.state.ball, {1.5 - ball.x, 0.5, -ball.z} * 0.3)
		}
		physics.step(world)
		physics.world_contact_events(world, &t.world.events)
		for event in t.world.events do t.state.begins += u32(event.kind == .Begin)
	},
}

ignore_inputs :: proc(tick: u32) -> sim.Inputs(Ignore_Game) {
	return {}
}

// The ignore coming and going (and going stale) under rollback: every re-simulated tick reproduces, check_refs passes
// after every restore, a snapshot resumes; 4 workers (set after creation) compute the same checksums.
@(test)
ignore_synctest :: proc(t: ^testing.T) {
	one_worker := synctest_and_resume(
		t,
		&IGNORE,
		1,
		IGNORE_TICKS,
		ignore_inputs,
		after = proc(t: ^testing.T, simulation: ^sim.Sim(Ignore_Game)) {
			testing.expectf(
				t,
				simulation.state.begins >= 6,
				"the ball touched the thrower %d times",
				simulation.state.begins,
			)
		},
	)
	on_4 := IGNORE
	on_4.world_create = proc(seed: u64, content: []u8) -> ^Ignore_World {
		ignore_world := IGNORE.world_create(seed, content)
		physics.world_set_worker_count(ignore_world.phys, 4)
		return ignore_world
	}
	four_workers := synctest_and_resume(t, &on_4, 1, IGNORE_TICKS, ignore_inputs)
	testing.expect(t, slice.equal(four_workers, one_worker), "on 4 workers: checksums differ from 1 worker's")
}
