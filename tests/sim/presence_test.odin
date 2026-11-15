package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

// One tick with `slots` present (no new join records unless `joins` gives them: {slot, member} pairs).
presence_step :: proc(simulation: ^toy.Sim, slots: sim.Players, joins: ..[2]int) {
	inputs: toy.Inputs
	inputs.present = slots
	for join in joins do sim.join(&inputs, join[0], join[1])
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
	sim.player_get(players, alice).score = 5
	presence_step(simulation, {1}) // alice leaves
	slot, present := sim.player_slot(players, alice)
	testing.expect(t, !present && slot == -1)
	testing.expect(t, sim.player_get(players, alice) != nil, "an absent player's data stays")
	testing.expect_value(t, sim.player_in_slot(players, 0), sim.Player{})
	presence_step(simulation, {1}) // an absent tick
	presence_step(simulation, {1, 3}, {3, 11}) // alice comes back in slot 3
	testing.expect_value(t, sim.player_in_slot(players, 3), alice)
	slot, present = sim.player_slot(players, alice)
	testing.expect(t, present && slot == 3)
	testing.expect_value(t, sim.player_get(players, alice).score, 5)
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
	sim.player_get(players, first).score = 9
	presence_step(simulation, {})
	presence_step(simulation, {0}, {0, 2})
	second := sim.player_in_slot(players, 0)
	testing.expect(t, second != first && second.id == 2)
	testing.expect_value(t, sim.player_get(players, second).score, 0)
	testing.expect_value(t, sim.player_get(players, first).score, 9) // still remembered, absent
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
	// Members 1..8 fill the table (MEMBERS = 8), each joining slot 0 and leaving: member k leaves at tick 2k.
	handles: [toy.MEMBERS]sim.Player
	for k in 0 ..< toy.MEMBERS {
		presence_step(simulation, {0}, {0, k + 1})
		handles[k] = sim.player_in_slot(players, 0)
		sim.player_get(players, handles[k]).score = i32(k + 1)
		presence_step(simulation, {})
	}
	// Member 3 comes back and leaves again: member 1 is now the longest absent, then 2, then 4.
	presence_step(simulation, {1}, {1, 3})
	presence_step(simulation, {})
	order := [?]int{0, 1, 3}
	for forgotten, k in order {
		presence_step(simulation, {2}, {2, 100 + k})
		testing.expectf(t, sim.player_get(players, handles[forgotten]) == nil, "member %d forgotten", forgotten + 1)
		newcomer := sim.player_in_slot(players, 2)
		testing.expect_value(t, newcomer.index, handles[forgotten].index)
		testing.expect_value(t, sim.player_get(players, newcomer).score, 0) // a zeroed T, not the old one's
		presence_step(simulation, {})
	}
	testing.expect_value(t, sim.player_get(players, handles[2]).score, 3)
	// A forgotten person who comes back is new.
	presence_step(simulation, {3}, {3, 1})
	back, _ := joined_in(simulation, simulation.tick, 3)
	testing.expect(t, !back.returning && sim.player_get(players, back.player).score == 0)
	known := 0
	walk := sim.iterate_known(players)
	for _, player in sim.next(&walk) {
		known += 1
		testing.expect(t, sim.player_known(players, player))
	}
	testing.expect_value(t, known, toy.MEMBERS)
}

@(test)
a_slot_present_without_a_join_record_stays_absent :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	inputs: toy.Inputs
	inputs.present = {0, 1}
	inputs.input[1].dx = 64
	sim.join(&inputs, 0, 1)
	sim.step(simulation, &inputs)
	testing.expect_value(t, sim.player_in_slot(players, 1), sim.Player{})
	present := 0
	walk := sim.iterate_present(players)
	for _ in sim.next(&walk) do present += 1
	testing.expect_value(t, present, 1)
	testing.expect_value(t, len(sim.events_at(simulation, 1)), 1) // slot 0's join only
	// An absent player's input reads as zero.
	tick := toy.Tick {
		state    = &simulation.state,
		inputs   = &inputs,
		presence = &simulation.presence,
	}
	testing.expect_value(t, sim.input(&tick, sim.player_in_slot(players, 0)), inputs.input[0])
	testing.expect_value(t, sim.input(&tick, sim.Player{index = 1, id = 2}), toy.Input{})
	testing.expect_value(t, len(sim.commands(&tick, sim.Player{})), 0)
}

@(test)
presence_is_plain_at_any_player_count :: proc(t: ^testing.T) {
	Wide :: struct {
		value: u64,
	}
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.Presence(Wide, 3, 3))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.Presence(Wide, 4, 9))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.Presence(u32, 1, 1))), "")
	Two :: struct {
		a, b: sim.Presence(u8, 4, 4),
	}
	_, reason := sim.presence_layout_of(type_info_of(Two), 4)
	testing.expect(t, reason != "", "two Presence fields are refused")
	_, reason = sim.presence_layout_of(type_info_of(toy.Thing), 4)
	testing.expect(t, reason != "", "a State without one is refused")
	_, reason = sim.presence_layout_of(type_info_of(toy.State), 3)
	testing.expect(t, reason != "", "a Presence for another player count is refused")
}

// A member who left on a tick keeps its entry through that tick, so the game can clean up by its handle in t.left: a
// script that swaps both slots' members at once in a table of two leaves the newcomers absent.
Tight_State :: struct {
	players: sim.Presence(u32, 2, 2),
}

Tight_Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}

Tight_Game :: sim.Game(Tight_State, toy.Input, toy.World, 2)

TIGHT := Tight_Game {
	name = "tight",
	tick_hz = 64,
	world_create = proc(seed: u64, _: []u8) -> ^toy.World {return new(toy.World)},
	world_destroy = proc(world: ^toy.World) {free(world)},
	init = proc(state: ^Tight_State, world: ^toy.World, seed: u64) {},
	tick = proc(t: ^sim.Tick(Tight_State, toy.Input, toy.World, 2)) {
		for player in t.left {
			assert(sim.player_get(&t.state.players, player) != nil, "a leaver's handle names its data on its tick")
		}
	},
	events = Tight_Event,
}

@(test)
a_member_who_just_left_is_not_forgotten_on_that_tick :: proc(t: ^testing.T) {
	simulation := sim.create(&TIGHT, 3)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	inputs: sim.Inputs(toy.Input, 2)
	sim.join(&inputs, 0, 1)
	sim.join(&inputs, 1, 2)
	sim.step(simulation, &inputs)
	first, second := sim.player_in_slot(players, 0), sim.player_in_slot(players, 1)
	inputs = {}
	sim.join(&inputs, 0, 3)
	sim.join(&inputs, 1, 4)
	sim.step(simulation, &inputs)
	testing.expect(t, sim.player_get(players, first) != nil && sim.player_get(players, second) != nil)
	testing.expect_value(t, sim.player_in_slot(players, 0), sim.Player{}) // no entry for the newcomers
	testing.expect_value(t, sim.player_in_slot(players, 1), sim.Player{})
	inputs.member = {}
	sim.step(simulation, &inputs) // on a later tick the slots stay absent: their records are gone
	inputs.member = {3, 4}
	sim.step(simulation, &inputs) // records again: now the two who left are forgotten
	testing.expect(t, sim.player_get(players, first) == nil && sim.player_in_slot(players, 0).id == 3)
}
