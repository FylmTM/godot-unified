// games/friendslop/SPEC.md: scenarios on the real level (the committed export of game/levels/park.tscn), each
// driven by a director that reads the World and records its inputs, while every tick is sync-tested
// (restore 8 ticks back, re-simulate with the recorded inputs, compare checksums). So platforms, carries,
// two-person lifts, throws, hits, held friends and pads are all checked for determinism under rollback.
package test_friendslop

import "core:testing"

import "unified:dmath"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:physics"
import "unified:sim"

import g "../friendslop"

// A sync-tested run on the park (g.GAME's level).
Run :: headless.Run(g.Game)

// One sync-tested tick of the seated members (headless.run_seat) with these inputs (by slot).
step :: proc(run: ^Run, inputs_by_slot: [g.PLAYERS]g.Input) {
	inputs := headless.run_inputs(run)
	inputs.input = inputs_by_slot
	headless.run_step(run, &inputs)
}

player_pos :: proc(run: ^Run, slot: int) -> [3]f32 {
	return physics.body_position(run.simulation.world.phys, sim.slot_data(run.simulation, slot).controller.body)
}

item_pos :: proc(run: ^Run, item: int) -> [3]f32 {
	return physics.body_position(run.simulation.world.phys, run.simulation.state.items[item].body)
}

// The nth item of a kind, in level order.
item_of :: proc(run: ^Run, kind: g.Item_Kind, nth := 0) -> int {
	seen := 0
	for i in 0 ..< run.simulation.world.item_count {
		if run.simulation.world.items[i].kind == kind {
			if seen == nth do return i
			seen += 1
		}
	}
	return -1
}

// Walks the player in `slot` towards `target` (stops within `near`), looking at `look` (default: the target).
walk :: proc(run: ^Run, slot: int, target: [3]f32, near: f32 = 0.3, look: Maybe([3]f32) = nil) -> g.Input {
	at := player_pos(run, slot)
	offset := [2]f32{target.x - at.x, target.z - at.z}
	input: g.Input
	if dmath.length(offset) > near {
		direction := dmath.normalize(offset)
		input.move_x = dmath.axis_i8(direction.x)
		input.move_z = dmath.axis_i8(direction.y)
	}
	return aim_at(run, slot, look.? or_else target, input)
}

aim_at :: proc(run: ^Run, slot: int, target: [3]f32, input: g.Input) -> g.Input {
	input := input
	aim := dmath.normalize(target - (player_pos(run, slot) + {0, g.HOLD_UP, 0}))
	input.aim = dmath.dir3(aim)
	return input
}

idle :: proc(run: ^Run, ticks: int) {
	for _ in 0 ..< ticks do step(run, {})
}

expect_clean :: proc(t: ^testing.T, run: ^Run, loc := #caller_location) {
	scenarios.expect_synced(t, run, loc)
}

@(test)
level_loads :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	idle(&run, 64)
	// Players stand on the floor: centre at FEET above it.
	testing.expectf(t, abs(player_pos(&run, 0).y - g.FEET) < 0.05, "standing at %v", player_pos(&run, 0))
	testing.expect(t, physics.character_grounded(&sim.slot_data(run.simulation, 0).controller))
	expect_clean(t, &run)
}

// Two players lift the heavy crate together; one alone can only drag it.
@(test)
heavy_needs_two :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	heavy := item_of(&run, .Heavy)
	heavy_pos := item_pos(&run, heavy)
	rest_y := heavy_pos.y
	sides := [2][3]f32{heavy_pos + {-1.7, 0, 0}, heavy_pos + {1.7, 0, 0}}
	// Walk to the two ends, face the crate.
	for _ in 0 ..< 160 {
		step(&run, {walk(&run, 0, sides[0], 0.1, heavy_pos), walk(&run, 1, sides[1], 0.1, heavy_pos), {}, {}})
	}
	// P0 grabs alone and pulls up for 2 s: it stays on the floor.
	step(&run, {aim_at(&run, 0, heavy_pos + {0, 1, 0}, {buttons = {.Grab}}), aim_at(&run, 1, heavy_pos, {}), {}, {}})
	testing.expect_value(t, sim.slot_data(run.simulation, 0).held_kind, g.Held_Kind.Item)
	for _ in 0 ..< 128 {
		step(&run, {aim_at(&run, 0, heavy_pos + {0, 2, 0}, {}), aim_at(&run, 1, heavy_pos, {}), {}, {}})
	}
	alone := item_pos(&run, heavy).y
	testing.expectf(t, alone < rest_y + 0.25, "one player lifted the heavy crate to %v (rest %v)", alone, rest_y)
	// P1 takes the other grab point: together it rises.
	step(&run, {
		aim_at(&run, 0, heavy_pos + {0, 2, 0}, {}),
		aim_at(&run, 1, item_pos(&run, heavy), {buttons = {.Grab}}),
		{},
		{},
	})
	testing.expect_value(t, sim.slot_data(run.simulation, 1).held_kind, g.Held_Kind.Item)
	if sim.slot_data(run.simulation, 1).held_kind == .Item {
		testing.expect(t, sim.slot_data(run.simulation, 1).grab_point != sim.slot_data(run.simulation, 0).grab_point)
	}
	peak: f32 = 0
	for _ in 0 ..< 128 {
		step(&run, {aim_at(&run, 0, heavy_pos + {0, 2, 0}, {}), aim_at(&run, 1, heavy_pos + {0, 2, 0}, {}), {}, {}})
		peak = max(peak, item_pos(&run, heavy).y)
	}
	testing.expectf(t, peak > rest_y + 0.4, "two players lifted it only to %v (rest %v)", peak, rest_y)
	// Carry it together for 2 s along -z.
	start_z := item_pos(&run, heavy).z
	for _ in 0 ..< 128 {
		step(&run, {
			{move_z = -127, aim = dmath.dir3({100, 40, 0})},
			{move_z = -127, aim = dmath.dir3({-100, 40, 0})},
			{},
			{},
		})
	}
	testing.expectf(t, start_z - item_pos(&run, heavy).z > 3, "carried only %v m", start_z - item_pos(&run, heavy).z)
	expect_clean(t, &run)
}

// A charged throw of a crate at a friend knocks them over; they get up again.
@(test)
throw_hits_friend :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	crate := item_of(&run, .Crate)
	crate_pos := item_pos(&run, crate)
	stand := crate_pos + {-1.3, 0, 0}
	friend := crate_pos + {-1.3, 0, -5}
	for _ in 0 ..< 200 {
		step(&run, {walk(&run, 0, stand, 0.1, crate_pos), walk(&run, 1, friend, 0.1), {}, {}})
	}
	step(&run, {aim_at(&run, 0, item_pos(&run, crate), {buttons = {.Grab}}), {}, {}, {}})
	testing.expect_value(t, sim.slot_data(run.simulation, 0).held_kind, g.Held_Kind.Item)
	for _ in 0 ..< 40 {
		step(&run, {aim_at(&run, 0, player_pos(&run, 1) + {0, 0.6, 0}, {buttons = {.Throw}}), {}, {}, {}})
	}
	step(&run, {aim_at(&run, 0, player_pos(&run, 1) + {0, 0.6, 0}, {}), {}, {}, {}}) // release: throw
	testing.expect_value(t, headless.run_events(&run, g.Event_Thrown), 1)
	stunned := false
	for _ in 0 ..< 96 {
		step(&run, {})
		stunned ||= sim.slot_data(run.simulation, 1).stun > 0
	}
	testing.expect(t, stunned)
	testing.expectf(
		t,
		headless.run_events(&run, g.Event_Hit) >= 1,
		"no hit (thrown %d)",
		headless.run_events(&run, g.Event_Thrown),
	)
	idle(&run, 96)
	testing.expect_value(t, sim.slot_data(run.simulation, 1).stun, 0)
	testing.expect(t, .Limp not_in sim.slot_data(run.simulation, 1).controller.flags)
	expect_clean(t, &run)
}

// Ride the lift up and step off onto the ledge; ride the ferry sideways.
@(test)
platforms_carry_players :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	world := run.simulation.world
	lift, ferry := platform_at_marker(&run, "Lift"), platform_at_marker(&run, "Ferry")
	testing.expect(t, lift >= 0 && ferry >= 0)
	if lift < 0 || ferry < 0 do return
	lift_at := world.platforms[lift].origin
	ferry_at := world.platforms[ferry].origin
	// Wait at the bottom: the lift comes back down every cycle.
	cycle := int(physics.path_duration_ticks(&world.platforms[lift].path, g.TICK_HZ))
	on_lift := false
	top: f32 = 0
	for _ in 0 ..< 2 * cycle {
		lift_pos := physics.body_position(world.phys, run.simulation.state.platforms[lift].body)
		target := lift_pos.y < lift_at.y + 0.1 || on_lift ? lift_at : lift_at + {-3, 0, 0}
		step(&run, {walk(&run, 0, target, 0.1), walk(&run, 1, ferry_at, 0.1), {}, {}})
		rider := player_pos(&run, 0)
		if abs(rider.x - lift_at.x) < 0.5 && abs(rider.z - lift_at.z) < 0.5 do on_lift = true
		if on_lift do top = max(top, player_pos(&run, 0).y)
	}
	testing.expectf(t, on_lift && top > lift_at.y + 2.5, "rode the lift to %v", top)
	// P1 stood on the ferry: it moved P1 along x by most of the ferry's 8 m.
	ferry_x: [2]f32 = {1e9, -1e9} // the rider's lowest and highest x
	for _ in 0 ..< cycle {
		step(&run, {{}, {}, {}, {}})
		ferry_x = {min(ferry_x[0], player_pos(&run, 1).x), max(ferry_x[1], player_pos(&run, 1).x)}
	}
	testing.expectf(t, ferry_x[1] - ferry_x[0] > 6, "the ferry moved its rider only %v m", ferry_x[1] - ferry_x[0])
	expect_clean(t, &run)
}

// The jump pad launches a player onto the high ledge.
@(test)
pad_launches_player :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 1)
	defer headless.run_end(&run)
	pad := run.simulation.world.pads[0].volume.pos
	peak: f32 = 0
	for _ in 0 ..< 200 {
		step(&run, {walk(&run, 0, pad, 0.05), {}, {}, {}})
		peak = max(peak, player_pos(&run, 0).y)
		if headless.run_events(&run, g.Event_Launched) > 0 do break
	}
	testing.expect(t, headless.run_events(&run, g.Event_Launched) >= 1)
	for _ in 0 ..< 160 {
		step(&run, {})
		peak = max(peak, player_pos(&run, 0).y)
	}
	testing.expectf(t, peak > 5, "launched only to %v", peak)
	testing.expectf(t, player_pos(&run, 0).y > 5, "did not land on the high ledge: %v", player_pos(&run, 0))
	expect_clean(t, &run)
}

// Grab a friend, carry them, they mash jump and break free; grab again and throw them.
@(test)
hold_and_throw_friend :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	idle(&run, 32)
	for _ in 0 ..< 64 {
		step(&run, {walk(&run, 0, player_pos(&run, 1) + {-1.2, 0, 0}, 0.1, player_pos(&run, 1)), {}, {}, {}})
	}
	step(&run, {aim_at(&run, 0, player_pos(&run, 1), {buttons = {.Grab}}), {}, {}, {}})
	testing.expect_value(t, sim.slot_data(run.simulation, 0).held_kind, g.Held_Kind.Player)
	testing.expect_value(t, sim.slot_data(run.simulation, 1).held_by, sim.player_in_slot(run.simulation, 0))
	start_y := player_pos(&run, 1).y
	for _ in 0 ..< 48 do step(&run, {aim_at(&run, 0, player_pos(&run, 0) + {0, 0.3, 2}, {}), {}, {}, {}})
	testing.expectf(
		t,
		player_pos(&run, 1).y > start_y + 0.2,
		"the friend wasn't lifted: %v -> %v",
		start_y,
		player_pos(&run, 1).y,
	)
	// Mash jump: 3 presses.
	for k in 0 ..< 12 {
		step(&run, {
			aim_at(&run, 0, player_pos(&run, 0) + {0, 0.3, 2}, {}),
			{buttons = {.Jump} if k % 2 == 0 else {}},
			{},
			{},
		})
	}
	testing.expect_value(t, headless.run_events(&run, g.Event_Broke_Free), 1)
	testing.expect_value(t, sim.slot_data(run.simulation, 1).held_by, sim.Player{})
	idle(&run, 96)
	// Grab again and throw.
	for _ in 0 ..< 96 {
		step(&run, {walk(&run, 0, player_pos(&run, 1) + {-1.2, 0, 0}, 0.1, player_pos(&run, 1)), {}, {}, {}})
	}
	step(&run, {aim_at(&run, 0, player_pos(&run, 1), {buttons = {.Grab}}), {}, {}, {}})
	testing.expect_value(t, sim.slot_data(run.simulation, 0).held_kind, g.Held_Kind.Player)
	for _ in 0 ..< 8 do step(&run, {
		{aim = dmath.dir3({0, 40, 100}), buttons = {.Throw}},
		{},
		{},
		{},
	})
	step(&run, {
		{aim = dmath.dir3({0, 40, 100})},
		{},
		{},
		{},
	})
	testing.expect_value(t, headless.run_events(&run, g.Event_Thrown), 1)
	testing.expect(t, sim.slot_data(run.simulation, 1).thrown)
	idle(&run, 160)
	testing.expect(t, !sim.slot_data(run.simulation, 1).thrown)
	testing.expectf(
		t,
		physics.character_grounded(&sim.slot_data(run.simulation, 1).controller),
		"not back on its feet: %v at %v",
		sim.slot_data(run.simulation, 1).controller.flags,
		player_pos(&run, 1),
	)
	testing.expect_value(t, headless.run_events(&run, g.Event_Fell), 0)
	expect_clean(t, &run)
}


// What a player owns follows the person, not the slot: the thrower of a crate leaves, someone new takes their slot
// (the crate is still the thrower's), and the thrower comes back in another slot as the same player.
@(test)
owners_follow_the_person :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 1, seated = 2)
	defer headless.run_end(&run)
	items := &run.simulation.state.items
	crate := item_of(&run, .Crate)
	crate_pos := item_pos(&run, crate)
	for _ in 0 ..< 200 do step(&run, {walk(&run, 0, crate_pos + {-1.3, 0, 0}, 0.1, crate_pos), {}, {}, {}})
	step(&run, {aim_at(&run, 0, item_pos(&run, crate), {buttons = {.Grab}}), {}, {}, {}})
	testing.expect_value(t, sim.slot_data(run.simulation, 0).held_kind, g.Held_Kind.Item)
	thrower := sim.player_in_slot(run.simulation, 0)
	for _ in 0 ..< 8 do step(&run, {{aim = dmath.dir3({0, 40, -100}), buttons = {.Throw}}, {}, {}, {}})
	step(&run, {{aim = dmath.dir3({0, 40, -100})}, {}, {}, {}}) // release: throw
	testing.expect_value(t, headless.run_events(&run, g.Event_Thrown), 1)
	testing.expect_value(t, items[crate].thrown_by, thrower)
	// The thrower leaves; someone new (member 100) takes slot 0.
	headless.run_seat(&run, 0, 0)
	step(&run, {})
	headless.run_seat(&run, 0, 100)
	step(&run, {})
	testing.expect_value(t, items[crate].thrown_by, thrower)
	// The thrower comes back in slot 2, and the crate is still theirs.
	headless.run_seat(&run, 2, 1)
	step(&run, {})
	testing.expect_value(t, items[crate].thrown_by, thrower)
	testing.expect(t, items[crate].thrown_ticks > 0)
	testing.expect_value(t, headless.run_events(&run, g.Event_Spawned), 4) // two at the start, the newcomer, the return
	expect_clean(t, &run)
}
