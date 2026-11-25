// The block check (sim.block_violation): crafted snapshots refused with Block_Rejected, honest states passing.
package test_sim

import "core:slice"
import "core:testing"

import "../toy"
import "unified:sim"

// A snapshot whose block no state of the game can be is refused before anything indexes by it (Block_Rejected), even
// with an intact digest: a crafted snapshot from a modified peer, a damaged file re-sealed. Every honest block passes,
// and a NaN (which indexes nothing) still loads.
@(test)
a_crafted_block_is_refused :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 7)
	defer sim.destroy(simulation)
	for tick in 1 ..= 20 {
		inputs := sim.seated_inputs(simulation)
		if tick == 1 {
			sim.seat(&inputs, simulation, 0, 1)
			sim.seat(&inputs, simulation, 1, 2)
		}
		if tick % 2 == 0 do inputs.input[0].buttons = {.Spawn}
		sim.step(simulation, &inputs)
		testing.expect_value(t, sim.block_violation(&simulation.state), "")
	}
	honest := sim.snapshot_encode(simulation, simulation.tick)
	defer delete(honest)
	testing.expect(t, simulation.state.things.count > 1, "the toy spawned things")
	Case :: struct {
		what:  string,
		craft: proc(state: ^toy.State),
		want:  sim.Snap_Error,
	}
	cases := []Case {
		{
			"a slot naming a member past the table",
			proc(state: ^toy.State) {state.players.slots[0].index = 0xFFFF},
			.Block_Rejected,
		},
		{
			"a member in a slot past PLAYERS",
			proc(state: ^toy.State) {state.players.members[0].slot = 200},
			.Block_Rejected,
		},
		{
			"slots naming each other's members",
			proc(state: ^toy.State) {
				state.players.slots[0], state.players.slots[1] = state.players.slots[1], state.players.slots[0]
			},
			.Block_Rejected,
		},
		{
			"two members with one id",
			proc(state: ^toy.State) {state.players.members[1].id = state.players.members[0].id},
			.Block_Rejected,
		},
		{"a free head past the table", proc(state: ^toy.State) {state.things.free_head = 1_000_000}, .Block_Rejected},
		{
			"a high water past the table",
			proc(state: ^toy.State) {state.things.high_water = 1_000_000},
			.Block_Rejected,
		},
		{"a negative high water", proc(state: ^toy.State) {state.things.high_water = -5}, .Block_Rejected},
		{"a count past the live slots", proc(state: ^toy.State) {state.things.count += 1}, .Block_Rejected},
		{
			"a slot past the high water linked",
			proc(state: ^toy.State) {state.things.slots[31].next_free = 3},
			.Block_Rejected,
		},
		{
			"a free list through a live slot",
			proc(state: ^toy.State) {
				state.things.free_head = 1
				state.things.slots[0].next_free = 1
			},
			.Block_Rejected,
		},
		{
			"a live slot past the high water",
			proc(state: ^toy.State) {state.things.slots[31].next_free = sim.SLOT_ALIVE},
			.Block_Rejected,
		},
		{
			"a List past its capacity",
			proc(state: ^toy.State) {state.players.data[0].trail.count = 200},
			.Block_Rejected,
		},
		{"a bool byte of 7", proc(state: ^toy.State) {(^u8)(&state.clock.paused)^ = 7}, .Block_Rejected},
		{"an undeclared level", proc(state: ^toy.State) {(^u8)(&state.level.id)^ = 250}, .Block_Rejected},
		{
			"a bit_set bit of no element",
			proc(state: ^toy.State) {(^u8)(&state.players.before[0].buttons)^ = 0x80},
			.Block_Rejected,
		},
		{
			"a NaN",
			proc(state: ^toy.State) {state.players.data[0].pos.x = transmute(f32)u32(0x7FC0_0001)},
			.None,
		},
	}
	BLOCK_AT :: sim.SNAP_HEADER + 2 + size_of(toy.Setup)
	for test_case in cases {
		crafted := slice.clone(honest)
		defer delete(crafted)
		test_case.craft((^toy.State)(&crafted[BLOCK_AT]))
		sim.snapshot_seal(crafted)
		restored, err := sim.from_snapshot(&toy.GAME, crafted)
		testing.expectf(t, err == test_case.want, "%s: %v, wanted %v", test_case.what, err, test_case.want)
		if restored != nil do sim.destroy(restored)
	}
}

// The inline collections and the enum rule, nested in arrays: a Bits index past its size, a Queue's head past its
// capacity, an enum's undeclared value (0 is fine even when undeclared: dead items are zeroed).
@(test)
the_block_check_reads_collections_and_enums_in_arrays :: proc(t: ^testing.T) {
	Mood :: enum u8 {
		Calm  = 1,
		Angry = 2,
	}
	Crowd :: struct {
		moods: [3]Mood,
		_pad:  [5]u8,
		seen:  sim.Bits(70),
		queue: sim.Queue(u32, 5),
	}
	State :: struct {
		crowds: [2]Crowd,
	}
	state: State
	testing.expect_value(t, sim.block_violation(&state), "")
	state.crowds[1].moods[2] = .Angry
	sim.incl(&state.crowds[1].seen, 69)
	sim.append(&state.crowds[0].queue, 7)
	testing.expect_value(t, sim.block_violation(&state), "")
	(^u8)(&state.crowds[1].moods[1])^ = 3
	testing.expect_value(t, sim.block_violation(&state), "crowds[1].moods[1]: 3 is no value of its enum")
	state.crowds[1].moods[1] = .Calm
	state.crowds[0].seen.words[1] |= 1 << 63
	testing.expect_value(t, sim.block_violation(&state), "crowds[0].seen: a Bits(70) holds 127")
	state.crowds[0].seen = {}
	state.crowds[1].queue.head = 5
	testing.expect_value(t, sim.block_violation(&state), "crowds[1].queue: its count or head is past its capacity 5")
}

// The check names the field it refuses, as a desync report names a field.
@(test)
a_block_violation_names_the_field :: proc(t: ^testing.T) {
	state: toy.State
	testing.expect_value(t, sim.block_violation(&state), "")
	state.things.count = 1
	testing.expect_value(t, sim.block_violation(&state), "things: a Table of 32 with high_water 0 and count 1")
}
