// Phases: lobby -> match on leaving the start circle, match -> over when everyone is dead, over ->
// lobby after the hold with a fresh world; the HUD view of it.
package test_survivor

import "core:testing"

import "../survivor"
import "unified:headless/scenarios"
import "unified:sim"

// Steps with fixed inputs for the present slots (a slot nobody holds joins: join_free).
step_with :: proc(simulation: ^survivor.Sim, present: sim.Players, input: survivor.Input) {
	inputs: survivor.Inputs
	join_free(simulation, &inputs, present)
	for slot in present {
		inputs.input[slot] = input
	}
	sim.step(simulation, &inputs)
}

// Makes the slots in `present` present, with a join record for each slot nobody holds yet: the player in slot i
// is member i + 1, as in scripted runs (so a slot emptied and filled again brings its member back).
join_free :: proc(simulation: ^survivor.Sim, inputs: ^survivor.Inputs, present: sim.Players) {
	inputs.present = present
	for slot in present {
		if sim.slot_player(simulation, slot) == {} {
			sim.join(inputs, slot, slot + 1)
		}
	}
}

// The character of whoever holds `slot` (nil: nobody).
in_slot :: proc(simulation: ^survivor.Sim, slot: int) -> ^survivor.Character {
	return sim.player_get(&simulation.state.players, sim.slot_player(simulation, slot))
}

// Damages the players in `slots` between ticks, as a system would inside one (the events go nowhere).
damage_players :: proc(simulation: ^survivor.Sim, amount: i32, slots: ..int) {
	events := sim.Events {
		type = survivor.Event,
	}
	defer delete(events.list)
	tick := survivor.Tick {
		state  = &simulation.state,
		world  = simulation.world,
		number = simulation.tick,
		seed   = simulation.seed,
		events = &events,
	}
	for slot in slots {
		survivor.damage_player(&tick, sim.slot_player(simulation, slot), amount)
	}
}

@(test)
lobby_match_over_lobby :: proc(t: ^testing.T) {
	simulation := sim.create(&survivor.GAME, 9)
	defer sim.destroy(simulation)
	for _ in 0 ..< 64 {
		step_with(simulation, {0, 1}, {}) // standing still: stays in the lobby, no enemies
	}
	state := &simulation.state
	testing.expect_value(t, state.phase, survivor.Phase.Lobby)
	testing.expect_value(t, state.enemies.count, 0)
	testing.expect_value(t, state.circle_radius, survivor.START_RADIUS)
	testing.expect(t, in_slot(simulation, 0) != nil && in_slot(simulation, 1) != nil && in_slot(simulation, 2) == nil)

	// Player 0 walks out of the circle (+x): the match starts on the tick its centre crosses.
	started: u32
	for _ in 0 ..< 128 {
		inputs: survivor.Inputs
		inputs.present = {0, 1}
		inputs.input[0] = {
			move_x = 127,
		}
		sim.step(simulation, &inputs)
		if state.phase == .Match {
			started = simulation.tick
			break
		}
	}
	testing.expect(t, started > 0)
	testing.expect_value(t, state.match_tick, started)
	pos := in_slot(simulation, 0).pos
	testing.expect(t, pos.x * pos.x + pos.z * pos.z > survivor.START_RADIUS * survivor.START_RADIUS)
	found := false
	for &raw in sim.events_at(simulation, started) {
		if event, ok := sim.event_value(&raw, survivor.Event).(survivor.Event_Match_Started); ok {
			found ||= event.player == sim.slot_player(simulation, 0)
		}
	}
	testing.expect(t, found)
	for _ in 0 ..< 2 * survivor.TUNINGS[.Play].spawn_every_ticks {
		step_with(simulation, {0, 1}, {})
	}
	testing.expect(t, state.enemies.count > 0)
	testing.expect_value(t, state.wave, 0) // the HUD shows wave + 1
	testing.expect_value(t, state.circle_radius, 0)
	testing.expect(t, simulation.tick > state.match_tick)

	// Everyone present dies in the same tick: over; nobody respawns; after the hold, a fresh lobby.
	damage_players(simulation, 1000, 0, 1)
	step_with(simulation, {0, 1}, {})
	testing.expect_value(t, state.phase, survivor.Phase.Over)
	over := simulation.tick
	for _ in 0 ..< survivor.OVER_HOLD_TICKS - 1 {
		step_with(simulation, {0, 1}, {})
		testing.expect(t, !in_slot(simulation, 0).alive)
	}
	testing.expect_value(t, state.phase, survivor.Phase.Over)
	step_with(simulation, {0, 1}, {})
	testing.expect_value(t, simulation.tick, over + survivor.OVER_HOLD_TICKS)
	testing.expect_value(t, state.phase, survivor.Phase.Lobby)
	testing.expect_value(t, state.enemies.count, 0)
	testing.expect(t, in_slot(simulation, 0).alive && in_slot(simulation, 1).alive && in_slot(simulation, 2) == nil)
	testing.expect_value(t, in_slot(simulation, 0).level, 1)
	testing.expect_value(t, state.matches, 1)
}

@(test)
joining_mid_match_spawns_at_the_start_spot :: proc(t: ^testing.T) {
	simulation := sim.create(&survivor.GAME, 4)
	defer sim.destroy(simulation)
	for simulation.state.phase == .Lobby && simulation.tick < 200 {
		step_with(simulation, {0}, {move_z = 127})
	}
	testing.expect_value(t, simulation.state.phase, survivor.Phase.Match)
	step_with(simulation, {0, 3}, {})
	testing.expect(t, in_slot(simulation, 3).alive)
	testing.expect_value(t, in_slot(simulation, 3).pos.x, survivor.PLAYER_START[3].x)
}

@(test)
time_constants_are_whole_ticks :: proc(t: ^testing.T) {
	testing.expect_value(t, survivor.RESPAWN_TICKS, 192)
	testing.expect_value(t, survivor.OVER_HOLD_TICKS, 320)
	testing.expect_value(t, survivor.TUNINGS[.Play].wave_ticks, 1920)
	testing.expect_value(t, survivor.TUNINGS[.Stress].spawn_every_ticks, 20)
}

@(test)
levels_start_at_one :: proc(t: ^testing.T) {
	simulation := sim.create(&survivor.GAME, 2)
	defer sim.destroy(simulation)
	step_with(simulation, {0}, {})
	testing.expect_value(t, in_slot(simulation, 0).level, 1)
	testing.expect_value(
		t,
		survivor.xp_next(&simulation.state, in_slot(simulation, 0).level),
		survivor.TUNINGS[.Play].xp_first,
	)
	stress := sim.create(&survivor.GAME_STRESS, 2)
	defer sim.destroy(stress)
	testing.expect_value(t, stress.state.tuning, survivor.Tuning_Kind.Stress)
	testing.expect(t, stress.state.tune == survivor.TUNINGS[.Stress])
}

@(test)
no_items_inside_the_start_circle :: proc(t: ^testing.T) {
	for i in 0 ..< survivor.ITEM_COUNT {
		spot := survivor.item_position(i)
		testing.expectf(t, spot.x * spot.x + spot.z * spot.z > 4.0 * 4.0, "item %d at %v", i, spot)
	}
}

// The `play` tuning with the bot policy (games/survivor/simulation/survivor/bot.odin), 2 seeds:
// guards the tuning's targets (games/survivor/SPEC.md). `survivor bot` measures more seeds. A balance check,
// not a correctness one: `uni test --long` only.
when scenarios.LONG {
	@(test)
	play_tuning_with_the_bot :: proc(t: ^testing.T) {
		for seed in 1 ..= u64(2) {
			simulation := sim.create(&survivor.GAME, seed)
			defer sim.destroy(simulation)
			state := &simulation.state
			first_level: f32 = -1
			out: sim.Command_Out
			defer delete(out.list)
			for simulation.tick < 200 * survivor.TICK_HZ && state.phase != .Over {
				inputs := survivor.bot_tick(state, 1, simulation.tick + 1, &out)
				sim.step(simulation, &inputs)
				if first_level < 0 && in_slot(simulation, 0).level > 1 {
					first_level = f32(simulation.tick - state.match_tick) * survivor.DT
				}
			}
			survived :=
				f32((state.phase == .Over ? state.over_tick : simulation.tick) - state.match_tick) * survivor.DT
			testing.expectf(
				t,
				first_level > 10 && first_level < 45,
				"seed %d: first level-up at %.1f s",
				seed,
				first_level,
			)
			testing.expectf(t, survived > 100, "seed %d: survived %.1f s", seed, survived)
			testing.expectf(t, state.wave >= 3, "seed %d: wave %d", seed, state.wave)
		}
	}
}
