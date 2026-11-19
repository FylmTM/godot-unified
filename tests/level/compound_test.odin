// src/physics/README.md, Levels: a level's statics are one compound per cell and filter category. A level with every
// shape kind and many materials: the bodies it makes, rays and hits naming each child's material and category, a
// shape alone in its cell staying a shape, and the cells starting from the level's own corner.
package test_level

import "core:testing"

import "unified:level"
import "unified:physics"
import "unified:sim"

CAT_LEDGE :: u64(1 << 3)

// Near the origin, in one 64 m cell: a box, a ball, a pill, a wedge and a two-material ramp mesh (materials 1 to 6) on
// a body turned 90° about +Y; two ledge boxes of their own category (7); a lone box 200 m away (9); a height field (10).
compound_level :: proc() -> []u8 {
	turned := [4]f32{0, 0.70710677, 0, 0.70710677} // 90° about +Y: body +x is world -z, body +z is world +x
	mixed := []level.Shape {
		{
			kind = .Box,
			pos = {0, -0.5, 0},
			rot = {0, 0, 0, 1},
			half = {10, 0.5, 10},
			surface = {friction = 0.5, material = 1},
		},
		{kind = .Sphere, pos = {4, 1, 0}, rot = {0, 0, 0, 1}, radius = 1, surface = {friction = 0.5, material = 2}},
		{
			kind = .Capsule,
			pos = {-4, 1, 0},
			rot = {0, 0, 0, 1},
			radius = 0.5,
			half_height = 1,
			surface = {friction = 0.5, material = 3},
		},
		{
			kind = .Hull,
			rot = {0, 0, 0, 1},
			points = {{0, 0, 4}, {1, 0, 4}, {0, 0, 5}, {0, 2, 4}},
			surface = {friction = 0.5, material = 4},
		},
		{
			kind = .Mesh,
			rot = {0, 0, 0, 1},
			points = {{-2, 0.5, -6}, {2, 0.5, -6}, {2, 0.5, -4}, {-2, 0.5, -4}},
			triangles = {{0, 2, 1}, {0, 3, 2}},
			triangle_materials = {0, 1},
			surface = {friction = 0.5, material = 5},
			materials = {{friction = 0.5, material = 5}, {friction = 0.9, material = 6}},
		},
	}
	ledges := []level.Shape {
		{kind = .Box, pos = {0, 5, 8}, rot = {0, 0, 0, 1}, half = {1, 0.25, 1}},
		{kind = .Box, pos = {0, 5, -8}, rot = {0, 0, 0, 1}, half = {1, 0.25, 1}},
	}
	lone := []level.Shape{{kind = .Box, rot = {0, 0, 0, 1}, half = {1, 1, 1}}}
	field := []level.Shape {
		{
			kind    = .Height_Field,
			pos     = {20, 0, 20},
			rot     = {0, 0, 0, 1},
			count_x = 3,
			count_z = 3,
			scale   = {2, 1, 2},
			heights = {0, 0, 0, 0, 1, 0, 0, 0, 0},
		},
	}
	bodies := []level.Body {
		{name = "mixed", rot = turned, surface = {friction = 0.5, material = 1}, shapes = mixed},
		{
			name = "ledges",
			rot = {0, 0, 0, 1},
			surface = {friction = 0.5, material = 7},
			category = CAT_LEDGE,
			shapes = ledges,
		},
		{
			name = "lone",
			pos = {200, 1, 0},
			rot = {0, 0, 0, 1},
			surface = {friction = 0.5, material = 9},
			shapes = lone,
		},
		{name = "field", rot = {0, 0, 0, 1}, surface = {friction = 0.5, material = 10}, shapes = field},
	}
	return encode(bodies, nil, allocator = context.temp_allocator)
}

// A ray straight down onto (x, z) from 20 m up, onto level shapes only (the levels' categories).
down :: proc(world: ^physics.World, x, z: f32) -> (physics.Hit, bool) {
	return physics.world_cast_ray_closest(world, {x, 20, z}, {0, -40, 0}, {mask = 1 | CAT_LEDGE})
}

@(test)
a_level_bakes_into_compounds :: proc(t: ^testing.T) {
	session := show(compound_level())
	defer show_end(session)
	world := session.world.phys
	level_bodies := 0
	for entry in world.bodies do level_bodies += int(.Level in entry.flags)
	testing.expect_value(t, level_bodies, 4) // the mixed cell, the ledges, the lone box, the field
	// Each child names its material and its category; the turned body puts its +x at world -z.
	Expect :: struct {
		x, z:     f32,
		material: u64,
		category: u64,
		type:     physics.Shape_Type,
	}
	expects := []Expect {
		{0, 0, 1, 1, .Compound}, // the floor
		{0, -4, 2, 1, .Compound}, // the ball: body (4, 1, 0)
		{0, 4, 3, 1, .Compound}, // the pill: body (-4, 1, 0)
		{4.2, -0.2, 4, 1, .Compound}, // the wedge: body z 4..5 is world x 4..5
		{-5.8, -1, 5, 1, .Compound}, // the ramp's first triangle (body x -2..2, z -6..-4: world x -6..-4, z -2..2)
		{-4.2, 1, 6, 1, .Compound}, // ... its second
		{0, 8, 7, CAT_LEDGE, .Compound}, // a ledge (5 m up, over the floor)
		{200, 0, 9, 1, .Hull}, // alone in its cell: a shape of its own
		{22, 22, 10, 1, .Height},
	}
	compound: physics.Body_Link
	for expect in expects {
		hit, ok := down(world, expect.x, expect.z)
		testing.expectf(t, ok, "(%v, %v): no hit", expect.x, expect.z)
		if !ok do continue
		testing.expectf(
			t,
			hit.material == expect.material && hit.category == expect.category,
			"(%v, %v): material %v category %v, want %v %v",
			expect.x,
			expect.z,
			hit.material,
			hit.category,
			expect.material,
			expect.category,
		)
		testing.expect_value(t, physics.shape_type(world, hit.shape), expect.type)
		// A ray against the shape alone names the same material.
		alone, alone_ok := physics.shape_ray_cast(world, hit.shape, {expect.x, 20, expect.z}, {0, -40, 0})
		testing.expectf(
			t,
			alone_ok && alone.material == expect.material,
			"(%v, %v): alone %v",
			expect.x,
			expect.z,
			alone,
		)
		if expect.material == 1 do compound = hit.body
	}
	ball, _ := down(world, 0, -4)
	testing.expect(t, ball.body == compound, "the ball is the floor's compound's")
	ledge, _ := down(world, 0, 8)
	testing.expect(t, ledge.body != compound, "the ledges' category is a compound of its own")
	// The compound's body sits at the cell's corner (the level's lowest corner), unrotated.
	body, _ := physics.resolve(world, compound)
	testing.expect_value(t, physics.body_rotation(world, body), [4]f32{0, 0, 0, 1})
}

// A contact's hit event names the child it hit: a box dropped onto the ramp's second triangle reports material 6.
@(test)
a_hit_on_a_compound_names_the_child :: proc(t: ^testing.T) {
	session := show(compound_level())
	defer show_end(session)
	world := session.world.phys
	def := physics.shape_def(2)
	def.density = 1
	def.enable_hit_events = true
	def.base_material.user_material_id = 77
	physics.create_box(world, physics.body_def(.Dynamic, {-4.4, 3, 1}), def, {0.2, 0.2, 0.2})
	events: [dynamic]physics.Contact_Event
	defer delete(events)
	found := false
	for _ in 0 ..< 64 {
		physics.step(world)
		physics.world_contact_events(world, &events)
		for event in events {
			if event.kind != .Hit do continue
			materials := [2]u64{event.material_a, event.material_b}
			testing.expectf(t, materials == {6, 77} || materials == {77, 6}, "hit materials %v", materials)
			found = true
		}
		if found do break
	}
	testing.expect(t, found, "no hit event")
}

// Two levels whose shapes share cell coordinates build compounds of their own, and a change swaps them.
@(test)
two_levels_build_their_own_compounds :: proc(t: ^testing.T) {
	session := sim.create(&PIT, 9)
	defer sim.destroy(session)
	world := session.world.phys
	yard, _ := down(world, -3.8, 4.2) // the yard's wedge
	testing.expect_value(t, physics.shape_type(world, yard.shape), physics.Shape_Type.Compound)
	for tick in u32(1) ..= 45 {
		inputs := pit_inputs(tick)
		sim.step(session, &inputs)
	}
	testing.expect_value(t, session.state.level.id, Area.Pit)
	ball, ok := down(world, 0, 3)
	testing.expect(t, ok && ball.material == 3, "the pit's ball")
	testing.expect_value(t, physics.shape_type(world, ball.shape), physics.Shape_Type.Compound)
}
