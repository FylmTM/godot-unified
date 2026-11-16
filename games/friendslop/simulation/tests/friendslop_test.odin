// games/friendslop/SPEC.md: scenarios on the real level (the committed export of game/levels/park.tscn), each
// driven by a director that reads the World and records its inputs, while every tick is sync-tested
// (restore 8 ticks back, re-simulate with the recorded inputs, compare checksums). So platforms, carries,
// two-person lifts, throws, hits, held friends and pads are all checked for determinism under rollback.
package test_friendslop

import "core:testing"

import fs "../friendslop"
import "unified:dmath"
import "unified:physics"
import "unified:sim"

PARK :: #load("../../game/levels/park.level")
WINDOW :: 8

Run :: struct {
	simulation:  ^fs.Sim,
	recorded:    [dynamic]fs.Inputs, // recorded[tick] = the inputs of that tick
	forward:     [dynamic]u64,
	mismatches:  int,
	counts:      [256]int, // events of the forward ticks, by kind (event_count)
	present:     sim.Slots,
	joins:       [fs.PLAYERS]u16, // join records for the next step (a member id per slot; 0: none)
	floor:       u32, // the sync-test never restores before this tick (a setup changed it)
	setup_index: int, // a setup's arguments (tests run on several threads: no globals)
	setup_pos:   [3]f32,
}

// A run with `players` slots present from the first tick (slot i is member i + 1).
start :: proc(players: int) -> Run {
	run := Run {
		simulation = sim.create(&fs.GAME, 1, PARK),
	}
	append(&run.recorded, fs.Inputs{})
	append(&run.forward, 0)
	for slot in 0 ..< players do join(&run, slot, slot + 1)
	step(&run, {}) // players join on the first tick: their bodies exist from here on
	return run
}

finish :: proc(run: ^Run) {
	sim.destroy(run.simulation)
	delete(run.recorded)
	delete(run.forward)
}

// `member` takes `slot` on the next step (someone new, or a member coming back).
join :: proc(run: ^Run, slot: int, member: int) {
	run.present += {slot}
	run.joins[slot] = u16(member)
}

// Whoever holds `slot` leaves on the next step.
leave :: proc(run: ^Run, slot: int) {
	run.present -= {slot}
	run.joins[slot] = 0
}

// One forward tick with these inputs (by slot), then the sync-test check of the last WINDOW ticks.
step :: proc(run: ^Run, inputs_by_slot: [fs.PLAYERS]fs.Input) {
	inputs := fs.Inputs {
		present = run.present,
		input   = inputs_by_slot,
	}
	for member, slot in run.joins {
		if member != 0 do sim.join(&inputs, slot, int(member))
	}
	run.joins = {}
	append(&run.recorded, inputs)
	sim.step(run.simulation, &inputs)
	tick := run.simulation.tick
	append(&run.forward, sim.checksum(run.simulation))
	for event in sim.events_at(run.simulation, tick) do run.counts[event.kind] += 1
	if tick < WINDOW do return
	from := max(tick - WINDOW, run.floor)
	if from == tick do return
	if !sim.restore(run.simulation, from) || !physics.check_refs(run.simulation.world.phys, &run.simulation.state) {
		run.mismatches += 1
		return
	}
	for replayed in from + 1 ..= tick {
		sim.step(run.simulation, &run.recorded[replayed])
		if sim.checksum(run.simulation) != run.forward[replayed] do run.mismatches += 1
	}
}

// How many events of this type (a variant of fs.Event) the forward ticks emitted.
event_count :: proc(run: ^Run, event: typeid) -> int {
	kind := sim.variant_kind(fs.Event, event)
	assert(kind >= 0, "not a friendslop event")
	return run.counts[kind]
}

// Who holds `slot` now (sim.Player{}: nobody).
player_in :: proc(run: ^Run, slot: int) -> sim.Player {
	return sim.player_in_slot(&run.simulation.state.players, slot)
}

// The data of whoever holds `slot` (nil: nobody).
character :: proc(run: ^Run, slot: int) -> ^fs.Character {
	return sim.player_data(&run.simulation.state.players, player_in(run, slot))
}

player_pos :: proc(run: ^Run, slot: int) -> [3]f32 {
	return physics.position(run.simulation.world.phys, character(run, slot).controller.body)
}

item_pos :: proc(run: ^Run, item: int) -> [3]f32 {
	return physics.position(run.simulation.world.phys, run.simulation.state.items[item].body)
}

// The nth item of a kind, in level order.
item_of :: proc(run: ^Run, kind: fs.Item_Kind, nth := 0) -> int {
	seen := 0
	for i in 0 ..< run.simulation.world.item_count {
		if run.simulation.world.items[i].kind == kind {
			if seen == nth do return i
			seen += 1
		}
	}
	return -1
}

i8_of :: proc(x: f32) -> i8 {
	return i8(clamp(x * 127, -127, 127))
}

// Walks the player in `slot` towards `target` (stops within `near`), looking at `look` (default: the target).
walk :: proc(run: ^Run, slot: int, target: [3]f32, near: f32 = 0.3, look: Maybe([3]f32) = nil) -> fs.Input {
	at := player_pos(run, slot)
	offset := [2]f32{target.x - at.x, target.z - at.z}
	input: fs.Input
	if dmath.length2(offset) > near {
		direction := dmath.normalize2(offset)
		input.move_x = i8_of(direction.x)
		input.move_z = i8_of(direction.y)
	}
	return aim_at(run, slot, look.? or_else target, input)
}

aim_at :: proc(run: ^Run, slot: int, target: [3]f32, input: fs.Input) -> fs.Input {
	input := input
	aim := dmath.normalize3(target - (player_pos(run, slot) + {0, fs.HOLD_UP, 0}))
	input.aim = dmath.dir3(aim)
	return input
}

idle :: proc(run: ^Run, ticks: int) {
	for _ in 0 ..< ticks do step(run, {})
}

expect_clean :: proc(t: ^testing.T, run: ^Run) {
	testing.expectf(t, run.mismatches == 0, "%d sync-test mismatches", run.mismatches)
}

@(test)
level_loads :: proc(t: ^testing.T) {
	run := start(1)
	defer finish(&run)
	world := run.simulation.world
	testing.expect(t, world.item_count >= 8)
	testing.expect(t, world.platform_count >= 2)
	testing.expect(t, world.pad_count >= 1)
	testing.expect(t, item_of(&run, .Heavy) >= 0)
	idle(&run, 64)
	// Players stand on the floor: centre at FEET above it.
	testing.expectf(t, abs(player_pos(&run, 0).y - fs.FEET) < 0.05, "standing at %v", player_pos(&run, 0))
	testing.expect(t, physics.character_grounded(&character(&run, 0).controller))
	expect_clean(t, &run)
}

// Two players lift the heavy crate together; one alone can only drag it.
@(test)
heavy_needs_two :: proc(t: ^testing.T) {
	run := start(2)
	defer finish(&run)
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
	testing.expect_value(t, character(&run, 0).held_kind, fs.Held_Kind.Item)
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
	testing.expect_value(t, character(&run, 1).held_kind, fs.Held_Kind.Item)
	if character(&run, 1).held_kind == .Item {
		testing.expect(t, character(&run, 1).grab_point != character(&run, 0).grab_point)
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
	run := start(2)
	defer finish(&run)
	crate := item_of(&run, .Crate)
	crate_pos := item_pos(&run, crate)
	stand := crate_pos + {-1.3, 0, 0}
	friend := crate_pos + {-1.3, 0, -5}
	for _ in 0 ..< 200 {
		step(&run, {walk(&run, 0, stand, 0.1, crate_pos), walk(&run, 1, friend, 0.1), {}, {}})
	}
	step(&run, {aim_at(&run, 0, item_pos(&run, crate), {buttons = {.Grab}}), {}, {}, {}})
	testing.expect_value(t, character(&run, 0).held_kind, fs.Held_Kind.Item)
	for _ in 0 ..< 40 {
		step(&run, {aim_at(&run, 0, player_pos(&run, 1) + {0, 0.6, 0}, {buttons = {.Throw}}), {}, {}, {}})
	}
	step(&run, {aim_at(&run, 0, player_pos(&run, 1) + {0, 0.6, 0}, {}), {}, {}, {}}) // release: throw
	testing.expect_value(t, event_count(&run, fs.Event_Thrown), 1)
	stunned := false
	for _ in 0 ..< 96 {
		step(&run, {})
		stunned ||= character(&run, 1).stun > 0
	}
	testing.expect(t, stunned)
	testing.expectf(t, event_count(&run, fs.Event_Hit) >= 1, "no hit (thrown %d)", event_count(&run, fs.Event_Thrown))
	idle(&run, 96)
	testing.expect_value(t, character(&run, 1).stun, 0)
	testing.expect(t, .Limp not_in character(&run, 1).controller.flags)
	expect_clean(t, &run)
}

// Ride the lift up and step off onto the ledge; ride the ferry sideways.
@(test)
platforms_carry_players :: proc(t: ^testing.T) {
	run := start(2)
	defer finish(&run)
	world := run.simulation.world
	lift, ferry := platform_at_marker(&run, "Lift"), platform_at_marker(&run, "Ferry")
	testing.expect(t, lift >= 0 && ferry >= 0)
	if lift < 0 || ferry < 0 do return
	lift_at := world.platforms[lift].origin
	ferry_at := world.platforms[ferry].origin
	// Wait at the bottom: the lift comes back down every cycle.
	cycle := int(physics.path_duration_ticks(&world.platforms[lift].path, fs.TICK_HZ))
	on_lift := false
	top: f32 = 0
	for _ in 0 ..< 2 * cycle {
		lift_pos := physics.position(world.phys, run.simulation.state.platforms[lift].body)
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
	run := start(1)
	defer finish(&run)
	pad := run.simulation.world.pads[0].volume.pos
	peak: f32 = 0
	for _ in 0 ..< 200 {
		step(&run, {walk(&run, 0, pad, 0.05), {}, {}, {}})
		peak = max(peak, player_pos(&run, 0).y)
		if event_count(&run, fs.Event_Launched) > 0 do break
	}
	testing.expect(t, event_count(&run, fs.Event_Launched) >= 1)
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
	run := start(2)
	defer finish(&run)
	idle(&run, 32)
	for _ in 0 ..< 64 {
		step(&run, {walk(&run, 0, player_pos(&run, 1) + {-1.2, 0, 0}, 0.1, player_pos(&run, 1)), {}, {}, {}})
	}
	step(&run, {aim_at(&run, 0, player_pos(&run, 1), {buttons = {.Grab}}), {}, {}, {}})
	testing.expect_value(t, character(&run, 0).held_kind, fs.Held_Kind.Player)
	testing.expect_value(t, character(&run, 1).held_by, player_in(&run, 0))
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
	testing.expect_value(t, event_count(&run, fs.Event_Broke_Free), 1)
	testing.expect_value(t, character(&run, 1).held_by, sim.Player{})
	idle(&run, 96)
	// Grab again and throw.
	for _ in 0 ..< 96 {
		step(&run, {walk(&run, 0, player_pos(&run, 1) + {-1.2, 0, 0}, 0.1, player_pos(&run, 1)), {}, {}, {}})
	}
	step(&run, {aim_at(&run, 0, player_pos(&run, 1), {buttons = {.Grab}}), {}, {}, {}})
	testing.expect_value(t, character(&run, 0).held_kind, fs.Held_Kind.Player)
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
	testing.expect_value(t, event_count(&run, fs.Event_Thrown), 1)
	testing.expect(t, character(&run, 1).thrown)
	idle(&run, 160)
	testing.expect(t, !character(&run, 1).thrown)
	testing.expectf(
		t,
		physics.character_grounded(&character(&run, 1).controller),
		"not back on its feet: %v at %v",
		character(&run, 1).controller.flags,
		player_pos(&run, 1),
	)
	testing.expect_value(t, event_count(&run, fs.Event_Fell), 0)
	expect_clean(t, &run)
}

// Four chaos players for 20 s (the CLI's scripted input): everything at once, still deterministic.
@(test)
chaos_synctest :: proc(t: ^testing.T) {
	run := start(4)
	defer finish(&run)
	for tick in u32(1) ..= 1280 {
		inputs: [fs.PLAYERS]fs.Input
		for slot in 0 ..< 4 do inputs[slot] = fs.scripted_input(7, slot, tick, nil)
		step(&run, inputs)
	}
	testing.expect(t, event_count(&run, fs.Event_Grabbed) > 0)
	expect_clean(t, &run)
}

// What a player owns follows the person, not the slot: the thrower of a crate leaves, someone new takes their slot
// (the crate is still the thrower's), and the thrower comes back in another slot as the same player.
@(test)
owners_follow_the_person :: proc(t: ^testing.T) {
	run := start(2)
	defer finish(&run)
	items := &run.simulation.state.items
	crate := item_of(&run, .Crate)
	crate_pos := item_pos(&run, crate)
	for _ in 0 ..< 200 do step(&run, {walk(&run, 0, crate_pos + {-1.3, 0, 0}, 0.1, crate_pos), {}, {}, {}})
	step(&run, {aim_at(&run, 0, item_pos(&run, crate), {buttons = {.Grab}}), {}, {}, {}})
	testing.expect_value(t, character(&run, 0).held_kind, fs.Held_Kind.Item)
	thrower := player_in(&run, 0)
	for _ in 0 ..< 8 do step(&run, {{aim = dmath.dir3({0, 40, -100}), buttons = {.Throw}}, {}, {}, {}})
	step(&run, {{aim = dmath.dir3({0, 40, -100})}, {}, {}, {}}) // release: throw
	testing.expect_value(t, event_count(&run, fs.Event_Thrown), 1)
	testing.expect_value(t, items[crate].thrown_by, thrower)
	// The thrower leaves; someone new (member 100) takes slot 0.
	leave(&run, 0)
	step(&run, {})
	testing.expect(t, !sim.player_present(&run.simulation.state.players, thrower))
	join(&run, 0, 100)
	step(&run, {})
	newcomer := player_in(&run, 0)
	testing.expect(t, newcomer != {} && newcomer != thrower)
	testing.expect_value(t, items[crate].thrown_by, thrower)
	// The thrower comes back in slot 2: the same handle, and the crate is still theirs.
	join(&run, 2, 1)
	step(&run, {})
	testing.expect_value(t, player_in(&run, 2), thrower)
	testing.expect_value(t, items[crate].thrown_by, thrower)
	testing.expect(t, items[crate].thrown_ticks > 0)
	testing.expect_value(t, event_count(&run, fs.Event_Spawned), 4) // two at the start, the newcomer, the return
	expect_clean(t, &run)
}
