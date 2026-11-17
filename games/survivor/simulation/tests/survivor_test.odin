// The survivor game on the harness: plain-data state and input, joins and leaves (players are session members:
// their progress follows them), events, and a short sync-test.
package test_survivor

import "core:testing"

import "../survivor"
import "unified:sim"


// GDScript sends commands and matches events by these names: renaming a type breaks the game's scripts.
@(test)
command_and_event_names :: proc(t: ^testing.T) {
	commands := sim.command_names(survivor.Cmd, context.temp_allocator)
	testing.expect_value(t, len(commands), 1)
	testing.expect_value(t, commands[0], "pick")
	events := sim.event_names(survivor.Event, context.temp_allocator)
	expected := []string {
		"player_died",
		"player_respawned",
		"enemy_died",
		"barrel_exploded",
		"gem_collected",
		"level_up",
		"match_started",
		"match_over",
		"player_joined",
		"player_left",
	}
	testing.expect_value(t, len(events), len(expected))
	for name, i in expected {
		testing.expect_value(t, events[i], name)
	}
}

step :: proc(simulation: ^survivor.Sim, present: sim.Slots) {
	inputs: survivor.Inputs
	join_free(simulation, &inputs, present)
	for slot in present {
		inputs.input[slot] = survivor.scripted_input(simulation.seed, slot, simulation.tick + 1, &simulation.state)
	}
	sim.step(simulation, &inputs)
}

// The library's join or leave event (`Kind`: sim.Event_Player_Joined or sim.Event_Player_Left) about `player` that
// `tick` emitted, if any.
presence_event :: proc(
	simulation: ^survivor.Sim,
	tick: u32,
	$Kind: typeid,
	player: sim.Player,
) -> (
	event: Kind,
	found: bool,
) {
	for &raw in sim.events_at(simulation, tick) {
		if event, found = sim.event_value(&raw, survivor.Event).(Kind); found && event.player == player {
			return
		}
	}
	return {}, false
}

@(test)
presence_joins_and_leaves :: proc(t: ^testing.T) {
	simulation := sim.create(&survivor.GAME, 3)
	defer sim.destroy(simulation)
	step(simulation, {0})
	first := sim.player_in_slot(simulation, 0)
	testing.expect(t, first != {} && in_slot(simulation, 0).alive)
	testing.expect(t, in_slot(simulation, 1) == nil)
	_, joined := presence_event(simulation, 1, sim.Event_Player_Joined, first)
	testing.expect(t, joined)
	step(simulation, {0, 1})
	second := sim.player_in_slot(simulation, 1)
	testing.expect(t, second != {} && second != first)
	_, joined = presence_event(simulation, 2, sim.Event_Player_Joined, second)
	testing.expect(t, joined)
	step(simulation, {1})
	character := sim.player_data(&simulation.state.players, first)
	testing.expect(t, !sim.player_present(&simulation.state.players, first))
	testing.expect(t, character != nil && !character.alive && character.body == {}) // an absent player has no body
	left, has_left := presence_event(simulation, 3, sim.Event_Player_Left, first)
	testing.expect(t, has_left && left.slot == 0)
}

// Progress belongs to the person, not the slot: the first player levels up and leaves; someone new takes their
// slot with fresh progress and a new handle; the first comes back in another slot as the same player, with their
// progress and a new body at that slot's start spot.
@(test)
progress_follows_the_player :: proc(t: ^testing.T) {
	simulation := sim.create(&survivor.GAME, 3)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	inputs: survivor.Inputs
	sim.join(&inputs, 0, 1)
	sim.step(simulation, &inputs)
	first := sim.player_in_slot(simulation, 0)
	sim.player_data(players, first).level = 4
	sim.player_data(players, first).damage_bonus = 6

	inputs = {} // the first leaves
	sim.step(simulation, &inputs)
	inputs = {}
	sim.join(&inputs, 0, 2) // someone new takes slot 0
	sim.step(simulation, &inputs)
	second := sim.player_in_slot(simulation, 0)
	testing.expect(t, second != {} && second != first)
	testing.expect_value(t, in_slot(simulation, 0).level, 1)
	testing.expect_value(t, in_slot(simulation, 0).damage_bonus, 0)
	away := sim.player_data(players, first)
	testing.expect(t, !sim.player_present(players, first) && away.level == 4 && away.body == {})

	inputs = {}
	inputs.present = {0}
	sim.join(&inputs, 1, 1) // the first comes back, in slot 1
	sim.step(simulation, &inputs)
	testing.expect_value(t, sim.player_in_slot(simulation, 1), first)
	testing.expect_value(t, sim.player_in_slot(simulation, 0), second)
	back := sim.player_data(players, first)
	testing.expect_value(t, back.level, 4)
	testing.expect_value(t, back.damage_bonus, 6)
	testing.expect(t, back.alive && back.body != {} && back.hp == survivor.PLAYER_HP)
	testing.expect_value(t, back.pos.x, survivor.PLAYER_START[1].x)
	testing.expect_value(t, back.pos.z, survivor.PLAYER_START[1].z)
	joined, found := presence_event(simulation, simulation.tick, sim.Event_Player_Joined, first)
	testing.expect(t, found && joined.returning && joined.slot == 1)
	testing.expect_value(t, in_slot(simulation, 0).level, 1)
}
