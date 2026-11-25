// Players: members come and go by join records, keep their handle and data, the longest-absent is forgotten first.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

// One tick with `slots` present (no new join records unless `joins` gives them: {slot, member} pairs).
presence_step :: proc(simulation: ^toy.Sim, slots: sim.Slots, joins: ..[2]int) {
	inputs: toy.Inputs
	inputs.present = slots
	for join in joins do join_record(&inputs, join[0], join[1])
	sim.step(simulation, &inputs)
}

// The player whose join (or return) the tick emitted for `slot`.
joined_in :: proc(simulation: ^toy.Sim, tick: u32, slot: int) -> (event: sim.Event_Player_Joined, ok: bool) {
	for &raw in sim.events_at(simulation, tick) {
		if joined, is_joined := sim.event_value(&raw, toy.Event).(sim.Event_Player_Joined);
		   is_joined && int(joined.slot) == slot {
			return joined, true
		}
	}
	return
}

@(test)
a_returning_player_keeps_handle_and_data_in_another_slot :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	presence_step(simulation, {0, 1}, {0, 11}, {1, 12})
	alice := sim.player_in_slot(players, 0)
	testing.expect(t, alice.id == 11 && sim.player_present(players, alice))
	sim.player_data(players, alice).score = 5
	presence_step(simulation, {1}) // alice leaves
	slot, present := sim.player_slot(players, alice)
	testing.expect(t, !present && slot == -1)
	testing.expect(t, sim.player_data(players, alice) != nil, "an absent player's data stays")
	testing.expect_value(t, sim.player_in_slot(players, 0), sim.Player{})
	presence_step(simulation, {1}) // an absent tick
	presence_step(simulation, {1, 3}, {3, 11}) // alice comes back in slot 3
	testing.expect_value(t, sim.player_in_slot(players, 3), alice)
	slot, present = sim.player_slot(players, alice)
	testing.expect(t, present && slot == 3)
	testing.expect_value(t, sim.player_data(players, alice).score, 5)
	back, ok := joined_in(simulation, 4, 3)
	testing.expect(t, ok && back.returning && back.player == alice)
	testing.expect_value(t, sim.player_key(alice), u64(11) << 16 | u64(alice.index))
	testing.expect_value(t, sim.player_of_key(sim.player_key(alice)), alice)
	testing.expect_value(t, sim.player_key({}), 0)
}

@(test)
a_newcomer_in_an_old_slot_is_someone_else :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	presence_step(simulation, {0}, {0, 1})
	first := sim.player_in_slot(players, 0)
	sim.player_data(players, first).score = 9
	presence_step(simulation, {})
	presence_step(simulation, {0}, {0, 2})
	second := sim.player_in_slot(players, 0)
	testing.expect(t, second != first && second.id == 2)
	testing.expect_value(t, sim.player_data(players, second).score, 0)
	testing.expect_value(t, sim.player_data(players, first).score, 9) // still remembered, absent
	testing.expect(t, !sim.player_present(players, first))
	joined, ok := joined_in(simulation, 3, 0)
	testing.expect(t, ok && !joined.returning)
	// A join record of another member on a slot still held: the holder leaves, the newcomer joins.
	presence_step(simulation, {0}, {0, 3})
	testing.expect_value(t, sim.player_in_slot(players, 0).id, 3)
	testing.expect(t, !sim.player_present(players, second))
}

@(test)
the_longest_absent_member_is_forgotten_first :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	// Members 1..8 fill the table (2 x PLAYERS = 8), each joining slot 0 and leaving: member k leaves at tick 2k.
	handles: [toy.PLAYERS * sim.MEMBERS_PER_SLOT]sim.Player
	for k in 0 ..< toy.PLAYERS * sim.MEMBERS_PER_SLOT {
		presence_step(simulation, {0}, {0, k + 1})
		handles[k] = sim.player_in_slot(players, 0)
		sim.player_data(players, handles[k]).score = i32(k + 1)
		presence_step(simulation, {})
	}
	// Member 3 comes back and leaves again: member 1 is now the longest absent, then 2, then 4.
	presence_step(simulation, {1}, {1, 3})
	presence_step(simulation, {})
	order := [?]int{0, 1, 3}
	for forgotten, k in order {
		presence_step(simulation, {2}, {2, 100 + k})
		testing.expectf(t, sim.player_data(players, handles[forgotten]) == nil, "member %d forgotten", forgotten + 1)
		newcomer := sim.player_in_slot(players, 2)
		testing.expect_value(t, newcomer.index, handles[forgotten].index)
		testing.expect_value(t, sim.player_data(players, newcomer).score, 0) // a zeroed T, not the old one's
		presence_step(simulation, {})
	}
	testing.expect_value(t, sim.player_data(players, handles[2]).score, 3)
	// A forgotten person who comes back is new.
	presence_step(simulation, {3}, {3, 1})
	back, _ := joined_in(simulation, simulation.tick, 3)
	testing.expect(t, !back.returning && sim.player_data(players, back.player).score == 0)
	known := 0
	walk := sim.iterate_known(players)
	for _, player in sim.next(&walk) {
		known += 1
		testing.expect(t, sim.player_known(players, player))
	}
	testing.expect_value(t, known, toy.PLAYERS * sim.MEMBERS_PER_SLOT)
}

@(test)
a_slot_present_without_a_join_record_stays_absent :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	inputs: toy.Inputs
	inputs.present = {0, 1}
	inputs.input[1].dx = 64
	join_record(&inputs, 0, 1)
	sim.step(simulation, &inputs)
	testing.expect_value(t, sim.player_in_slot(players, 1), sim.Player{})
	present := 0
	walk := sim.iterate_present(players)
	for _ in sim.next(&walk) do present += 1
	testing.expect_value(t, present, 1)
	testing.expect_value(t, len(sim.events_at(simulation, 1)), 1) // slot 0's join only
	// An absent player's input reads as zero.
	tick := toy.Tick {
		state  = &simulation.state,
		inputs = &inputs,
	}
	testing.expect_value(t, sim.input(&tick, sim.player_in_slot(players, 0)), inputs.input[0])
	testing.expect_value(t, sim.input(&tick, sim.Player{index = 1, id = 2}), toy.Input{})
	testing.expect_value(t, len(sim.commands(&tick, sim.Player{})), 0)
}

@(test)
players_is_plain_at_any_player_count :: proc(t: ^testing.T) {
	Wide :: struct {
		value: u64,
	}
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.Players(Wide, sim.No_Profile, toy.Input, 3))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.Players(Wide, sim.No_Profile, [3]u8, 4))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.Players(u32, sim.No_Profile, u8, 1))), "")
}

// A member who left on a tick keeps its entry through that tick, so the game can clean up by its handle in
// t.player_changes.left: when the table is full, newcomers take the entries of members who left earlier.
Tight_State :: struct {
	players: sim.Players(u32, sim.No_Profile, toy.Input, 2),
}

Tight_Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}

Tight_Game :: sim.Game(
	Tight_State,
	toy.Input,
	toy.World,
	Tight_Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	2,
)

TIGHT := Tight_Game {
	name = "tight",
	tick_hz = 64,
	tick = proc(t: ^sim.Tick(Tight_Game)) {
		for player in t.player_changes.left {
			assert(sim.player_data(t, player) != nil, "a leaver's handle names its data on its tick")
		}
	},
}

@(test)
a_member_who_just_left_is_not_forgotten_on_that_tick :: proc(t: ^testing.T) {
	simulation := sim.create(&TIGHT, 3)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	testing.expect_value(t, len(players.members), 4) // 2 x PLAYERS
	inputs: sim.Inputs(Tight_Game)
	swap :: proc(simulation: ^sim.Sim(Tight_Game), inputs: ^sim.Inputs(Tight_Game), a, b: int) {
		inputs^ = {}
		join_record(inputs, 0, a)
		join_record(inputs, 1, b)
		sim.step(simulation, inputs)
	}
	swap(simulation, &inputs, 1, 2)
	first, second := sim.player_in_slot(players, 0), sim.player_in_slot(players, 1)
	swap(simulation, &inputs, 3, 4) // 1 and 2 leave; 3 and 4 take the free entries
	third, fourth := sim.player_in_slot(players, 0), sim.player_in_slot(players, 1)
	swap(simulation, &inputs, 5, 6) // the table is full: 5 and 6 take 1's and 2's entries, not those of 3 and 4
	testing.expect(t, sim.player_data(players, first) == nil && sim.player_data(players, second) == nil)
	testing.expect(t, sim.player_data(players, third) != nil && sim.player_data(players, fourth) != nil)
	testing.expect_value(t, sim.player_in_slot(players, 0).id, 5)
	testing.expect_value(t, sim.player_in_slot(players, 1).id, 6)
}

// Every query answers the same on a simulation (tests and drivers hold a ^Sim) as on its state's Players.
@(test)
the_queries_take_a_simulation :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	presence_step(simulation, {0, 1}, {0, 11}, {1, 12})
	presence_step(simulation, {1}) // slot 0's member leaves: known, not present
	gone, here := sim.Player {
			index = 0,
			id    = 11,
		}, sim.player_in_slot(simulation, 1)
	testing.expect(t, sim.player_known(simulation, gone) && sim.player_known(players, gone))
	testing.expect_value(t, sim.player_data(simulation, gone), sim.player_data(players, gone))
	testing.expect_value(t, sim.player_slot(simulation, here), sim.player_slot(players, here))
	testing.expect(t, sim.player_present(simulation, here) && !sim.player_present(simulation, gone))
	testing.expect_value(t, sim.present_count(simulation), 1)
	testing.expect_value(t, sim.slot_data(simulation, 1), sim.player_data(simulation, here))
	present, known := sim.iterate_present(simulation), sim.iterate_known(simulation)
	present_count, known_count := 0, 0
	for _ in sim.next(&present) do present_count += 1
	for _ in sim.next(&known) do known_count += 1
	testing.expect(t, present_count == 1 && known_count == 2, "present 1, known 2")
}

// A member seated once stays while each tick's inputs start from seated_inputs (one join record, on the first tick);
// unseat lets them go on the next tick (their leave), and nobody is asked for after.
@(test)
seated_inputs_keep_a_member_seated_until_unseat :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	for tick in 1 ..= 20 {
		inputs := sim.seated_inputs(simulation)
		if tick == 1 {
			sim.seat(&inputs, simulation, 1, 4)
		} else {
			testing.expect_value(t, inputs.joins[1], 0) // held already: no join record
		}
		sim.step(simulation, &inputs)
		testing.expect_value(t, sim.player_in_slot(simulation, 1).id, 4)
	}
	sim.unseat(simulation, 1)
	inputs := sim.seated_inputs(simulation)
	testing.expect_value(t, inputs.present, sim.Slots{})
	sim.step(simulation, &inputs)
	testing.expect_value(t, sim.player_in_slot(simulation, 1), sim.Player{})
	empty: toy.Inputs
	sim.step(simulation, &empty) // nobody seated by hand: nobody asked for
}

// A member seated with a Profile keeps it: a restore to before their join and the inputs seated_inputs gives replay the
// join on its own tick, bringing the same Profile (the zero one used to come back).
@(test)
seated_inputs_keep_the_profile_across_a_restore :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	inputs := sim.seated_inputs(simulation)
	sim.seat(&inputs, simulation, 0, 1, toy.Profile{color = 9})
	sim.step(simulation, &inputs)
	player := sim.player_in_slot(simulation, 0)
	testing.expect_value(t, sim.player_profile(simulation, player).color, 9)
	testing.expect(t, sim.restore(simulation, 0))
	testing.expect_value(t, sim.seated_inputs(simulation).joins[0], 1) // tick 1 again: the join record
	for _ in 0 ..< 3 {
		again := sim.seated_inputs(simulation)
		sim.step(simulation, &again)
	}
	player = sim.player_in_slot(simulation, 0)
	testing.expect_value(t, player.id, 1)
	testing.expect_value(t, sim.player_profile(simulation, player).color, 9)
}

// A member seated once, then a tick's inputs made without them (a zero Inputs): step names the slot and the cause
// rather than letting them leave unseen.
@(test)
a_seated_member_left_out_of_a_tick_panics :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the panic ends the test before destroy
	simulation := sim.create(&toy.GAME, 3)
	inputs: toy.Inputs
	sim.seat(&inputs, simulation, 0, 1)
	sim.step(simulation, &inputs)
	testing.expect_assert_message(
		t,
		"sim.step: tick 2's inputs leave out slot 0, where sim.seat seated member 1 from tick 1. Inputs are one tick's: start each tick's from sim.seated_inputs (or seat the member every tick), and sim.unseat a member to have them leave",
	)
	fresh: toy.Inputs
	sim.step(simulation, &fresh)
}

// A raw join record, as the relay writes one (sim.seat writes them for a test that seats members): `member` present
// in `slot` for this tick's inputs only, bringing `profile` (the zero Profile when left out).
join_record :: proc {
	join_record_plain,
	join_record_with_profile,
}

join_record_plain :: proc(inputs: ^sim.Inputs($G), slot: int, member: int) {
	join_record_with_profile(inputs, slot, member, sim.part(G, sim.GAME_PROFILE){})
}

join_record_with_profile :: proc(inputs: ^sim.Inputs($G), slot: int, member: int, profile: $P) {
	inputs.present += {slot}
	inputs.joins[slot] = u16(member)
	inputs.profiles[slot] = profile
}
