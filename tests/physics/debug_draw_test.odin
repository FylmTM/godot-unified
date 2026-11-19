// src/physics/debug_draw.odin: physics.debug_draw never changes the simulation. For each flag alone and all together,
// the rig (characters, boxes, a kinematic platform, a hold joint) plus revolute joints is run twice, one drawing every
// tick: Box3D's whole-world hash is equal every tick and the portable snapshots are byte-equal at the end. A flag in
// DEBUG_DRAW_PURE is drawn without the snapshot bracket, so a Box3D upgrade that makes one write fails here; the one
// that writes today is shown to (when it stops, it joins DEBUG_DRAW_PURE: the upgrade-dependency skill).
package test_physics

import "core:slice"
import "core:testing"

import box3d "box3d:bindings"
import "unified:physics"
import "unified:sim"

// The flags the drawing rig's tick draws with (each test's own thread).
@(thread_local)
draw_flags: physics.Debug_Draw_Flags

// The rig's world plus three revolute joints (the World's: made in world_create).
draw_world_create :: proc(seed: u64, _: []sim.Level_File, _: sim.No_Setup) -> ^Rig_World {
	rig_world := rig_world_create(1)
	for i in 0 ..< 3 {
		hinge_a, hinge_b := joint_pair(rig_world.phys, {f32(i) * 3 - 3, 3, -4})
		hinge_def := physics.default_revolute_joint_def()
		hinge_def.base.local_frame_a = JOINT_FRAME_AT_B
		hinge_def.enable_motor = true
		hinge_def.motor_speed = 2
		hinge_def.max_motor_torque = 5
		physics.create_revolute_joint(rig_world.phys, physics.link(hinge_a), physics.link(hinge_b), hinge_def)
	}
	return rig_world
}

draw_tick :: proc(t: ^Rig_Tick) {
	rig_tick(t)
	physics.debug_draw(t, t.world.phys, draw_flags)
}

drawing_rig :: proc() -> Rig_Game {
	game := RIG
	game.name = "drawing rig"
	game.world_create = draw_world_create
	game.tick = draw_tick
	return game
}

@(test)
debug_draw_changes_nothing :: proc(t: ^testing.T) {
	game := drawing_rig()
	cases := make([dynamic]physics.Debug_Draw_Flags, context.temp_allocator)
	for flag in physics.Debug_Draw_Flag do append(&cases, physics.Debug_Draw_Flags{flag})
	append(&cases, ~physics.Debug_Draw_Flags{})
	for flags in cases {
		draw_flags = flags
		plain := sim.create(&game, 5)
		drawn := sim.create(&game, 5)
		sim.dev_attach(drawn)
		sim.dev_enable(drawn, max(u64))
		shapes := 0
		for tick in u32(1) ..= 160 {
			inputs := rig_inputs(tick)
			sim.step(plain, &inputs)
			sim.step(drawn, &inputs)
			if draws := sim.debug_draws(drawn, tick); draws != nil do shapes += len(draws.shapes)
			plain_hash := box3d.World_HashState(plain.world.phys.id)
			drawn_hash := box3d.World_HashState(drawn.world.phys.id)
			if plain_hash != drawn_hash {
				testing.expectf(t, false, "%v: the world hash differs at tick %d", flags, tick)
				break
			}
		}
		testing.expectf(t, check_drawn(flags, shapes), "%v drew %d shapes", flags, shapes)
		testing.expectf(t, physics.check_refs(drawn.world.phys, &drawn.state) == "", "%v: refs", flags)
		// a rollback and a re-simulation with drawing on: still the same world
		testing.expect(t, sim.restore(drawn, 150) && sim.restore(plain, 150))
		for tick in u32(151) ..= 160 {
			inputs := rig_inputs(tick)
			sim.step(plain, &inputs)
			sim.step(drawn, &inputs)
		}
		plain_image := sim.snapshot_encode(plain, 160)
		drawn_image := sim.snapshot_encode(drawn, 160)
		testing.expectf(t, slice.equal(plain_image, drawn_image), "%v: the snapshots differ", flags)
		delete(plain_image)
		delete(drawn_image)
		sim.destroy(plain)
		sim.destroy(drawn)
	}
}

// Whether a run with these flags drew what it should: every flag that always has something to draw in the rig did.
check_drawn :: proc(flags: physics.Debug_Draw_Flags, shapes: int) -> bool {
	ALWAYS :: physics.Debug_Draw_Flags{.Shapes, .Joints, .Joint_Extras, .Bounds, .Mass, .Contacts, .Body_Names}
	return flags & ALWAYS == {} || shapes > 0
}

// Box3D's own draw with joint extras writes cached joint axes the whole-world hash covers: the reason it is drawn
// between a snapshot save and restore. When a Box3D release makes it pure, this fails: move .Joint_Extras into
// DEBUG_DRAW_PURE.
@(test)
debug_draw_joint_extras_write :: proc(t: ^testing.T) {
	game := drawing_rig()
	draw_flags = {}
	simulation := sim.create(&game, 5)
	defer sim.destroy(simulation)
	world := simulation.world.phys
	changed := false
	for tick in u32(1) ..= 64 {
		inputs := rig_inputs(tick)
		sim.step(simulation, &inputs)
		before := box3d.World_HashState(world.id)
		debug := box3d.DefaultDebugDraw()
		debug.drawJoints, debug.drawJointExtras = true, true
		debug.DrawSegmentFcn = proc "c" (_, _: box3d.Pos, _: box3d.HexColor, _: rawptr) {}
		debug.DrawTransformFcn = proc "c" (_: box3d.WorldTransform, _: rawptr) {}
		debug.DrawPointFcn = proc "c" (_: box3d.Pos, _: f32, _: box3d.HexColor, _: rawptr) {}
		debug.DrawStringFcn = proc "c" (_: box3d.Pos, _: cstring, _: box3d.HexColor, _: rawptr) {}
		debug.drawingBounds = {{-1e30, -1e30, -1e30}, {1e30, 1e30, 1e30}}
		box3d.World_Draw(world.id, &debug, max(u64))
		changed ||= box3d.World_HashState(world.id) != before
	}
	testing.expect(t, changed, "Box3D's joint extras no longer write: move .Joint_Extras into DEBUG_DRAW_PURE")
}

// Shapes: a sphere is one sphere, a capsule one capsule, a box its 12 edges, each in the shapes group.
@(test)
debug_draw_shapes :: proc(t: ^testing.T) {
	Shapes_World :: struct {
		phys: ^physics.World,
	}
	Shapes_State :: struct {
		players: sim.Players(u32, sim.No_Profile, Rig_Input, 1),
	}
	Shapes_Game :: sim.Game(
		Shapes_State,
		Rig_Input,
		Shapes_World,
		Library_Events,
		sim.No_Commands,
		sim.No_Setup,
		sim.No_Profile,
		1,
	)
	game := Shapes_Game {
		name = "shapes",
		version = "1",
		tick_hz = HZ,
		world_create = proc(_: u64, _: []sim.Level_File, _: sim.No_Setup) -> ^Shapes_World {
			shapes_world := new(Shapes_World)
			shapes_world.phys = physics.create({tick_hz = HZ})
			def := physics.default_shape_def()
			physics.create_sphere(shapes_world.phys, physics.body_def(.Static, {0, 0, 0}), def, 0.5)
			physics.create_capsule(
				shapes_world.phys,
				physics.body_def(.Static, {3, 0, 0}),
				def,
				{{0, -0.5, 0}, {0, 0.5, 0}, 0.25},
			)
			physics.create_box(shapes_world.phys, physics.body_def(.Static, {6, 0, 0}), def, {1, 1, 1})
			return shapes_world
		},
		world_destroy = proc(shapes_world: ^Shapes_World) {
			physics.destroy(shapes_world.phys)
			free(shapes_world)
		},
		extra = proc(shapes_world: ^Shapes_World) -> sim.Extra {return physics.extra(shapes_world.phys, Shapes_State)},
		tick = proc(tick: ^sim.Tick(Shapes_Game)) {physics.debug_draw(tick, tick.world.phys, {.Shapes})},
	}
	simulation := sim.create(&game, 1)
	defer sim.destroy(simulation)
	dev := sim.dev_attach(simulation)
	sim.dev_enable(simulation, max(u64))
	inputs: sim.Inputs(Shapes_Game)
	sim.step(simulation, &inputs)
	draws := sim.debug_draws(simulation, 1)
	counts: [sim.Debug_Kind]int
	corner := false
	for shape in draws.shapes {
		counts[shape.kind] += 1
		testing.expect_value(t, dev.groups[shape.group], "physics_shapes")
		corner ||= shape.kind == .Line && (near(shape.a, {7, 1, 1}) || near(shape.b, {7, 1, 1}))
	}
	testing.expect_value(t, counts[.Sphere], 1)
	testing.expect_value(t, counts[.Capsule], 1)
	testing.expect_value(t, counts[.Line], 12)
	testing.expect(t, corner, "a box edge ends at its corner")
}
