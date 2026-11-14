// The survivor game on the harness: plain-data state and input, presence-driven join and leave,
// events, and a short sync-test.
package test_survivor

import "core:testing"

import "../survivor"
import "unified:sim"

@(test)
state_is_plain_data :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.plain_violation(type_info_of(survivor.State)), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(survivor.Input)), "")
	testing.expect_value(t, size_of(survivor.Input), 3)
	game := &survivor.GAME
	testing.expect_value(t, sim.game_violation(game.name, game.tick_hz, game.commands, game.events), "")
}

// GDScript sends commands and matches events by these names: renaming a type breaks the game's scripts.
@(test)
command_and_event_names :: proc(t: ^testing.T) {
	commands := sim.command_names(survivor.Command, context.temp_allocator)
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

step :: proc(simulation: ^survivor.Sim, present: sim.Players) {
	inputs: survivor.Inputs
	inputs.present = present
	for player in present {
		inputs.input[player] = survivor.scripted_input(simulation.seed, player, simulation.tick + 1, &simulation.state)
	}
	sim.step(simulation, &inputs)
}

// Whether `tick` emitted a presence event (Player_Joined or Player_Left: `Kind`) about `player`.
has_event :: proc(simulation: ^survivor.Sim, tick: u32, $Kind: typeid, player: int) -> bool {
	for &raw in sim.events_at(simulation, tick) {
		if event, ok := sim.event_value(&raw, survivor.Event).(Kind); ok && int(event.player) == player {
			return true
		}
	}
	return false
}

@(test)
presence_joins_and_leaves :: proc(t: ^testing.T) {
	simulation := sim.create(&survivor.GAME, 3)
	defer sim.destroy(simulation)
	state := &simulation.state
	step(simulation, {0})
	testing.expect(t, state.players[0].active && state.players[0].alive)
	testing.expect(t, !state.players[1].active)
	testing.expect(t, has_event(simulation, 1, survivor.Player_Joined, 0))
	step(simulation, {0, 1})
	testing.expect(t, state.players[1].active)
	testing.expect(t, has_event(simulation, 2, survivor.Player_Joined, 1))
	step(simulation, {1})
	testing.expect(t, !state.players[0].active && state.players[0].body == {})
	testing.expect(t, has_event(simulation, 3, survivor.Player_Left, 0))
}

@(test)
synctest_short :: proc(t: ^testing.T) {
	simulation := sim.create(&survivor.GAME, 42)
	defer sim.destroy(simulation)
	forward: [241]u64
	for tick in 1 ..= u32(240) {
		step(simulation, {0, 1, 2, 3})
		forward[tick] = sim.checksum(simulation)
		if tick < 8 {
			continue
		}
		testing.expect(t, sim.restore(simulation, tick - 8))
		for resim in tick - 7 ..= tick {
			step(simulation, {0, 1, 2, 3})
			if sim.checksum(simulation) != forward[resim] {
				testing.expectf(t, false, "tick %d re-sim at %d differs", resim, tick)
				return
			}
		}
	}
}
