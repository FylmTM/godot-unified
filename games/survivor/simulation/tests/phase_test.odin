// Phases: lobby -> match on leaving the start circle, match -> over when everyone is dead, over ->
// lobby after the hold with a fresh world.
package test_survivor

import "core:testing"

import g "../survivor"
@(require) import "unified:headless" // the balance test (LONG only)
import "unified:headless/scenarios"
import "unified:sim"

// Steps with fixed inputs for the present slots: the player in slot i is member i + 1, as in scripted runs (so a
// slot emptied and filled again brings its member back).
step_with :: proc(simulation: ^sim.Sim(g.Game), present: sim.Slots, input: g.Input) {
	inputs: g.Inputs
	for slot in present {
		sim.seat(&inputs, simulation, slot, slot + 1)
		inputs.input[slot] = input
	}
	sim.step(simulation, &inputs)
}

@(test)
lobby_match_over_lobby :: proc(t: ^testing.T) {
	simulation := sim.create(&g.GAME, 9)
	defer sim.destroy(simulation)
	for _ in 0 ..< 64 {
		step_with(simulation, {0, 1}, {}) // standing still: stays in the lobby, no enemies
	}
	state := &simulation.state
	testing.expect_value(t, state.phase, g.Phase.Lobby)
	testing.expect_value(t, state.enemies.count, 0)
	testing.expect_value(t, state.circle_radius, g.START_RADIUS)
	testing.expect(
		t,
		sim.slot_data(simulation, 0) != nil &&
		sim.slot_data(simulation, 1) != nil &&
		sim.slot_data(simulation, 2) == nil,
	)

	// Player 0 walks out of the circle (+x): the match starts on the tick its centre crosses.
	started: u32
	for _ in 0 ..< 128 {
		inputs: g.Inputs
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
	pos := sim.slot_data(simulation, 0).pos
	testing.expect(t, pos.x * pos.x + pos.z * pos.z > g.START_RADIUS * g.START_RADIUS)
	found := false
	for &raw in sim.events_at(simulation, started) {
		if event, ok := sim.event_value(&raw, g.Event).(g.Event_Match_Started); ok {
			found ||= event.player == sim.player_in_slot(simulation, 0)
		}
	}
	testing.expect(t, found)
	for _ in 0 ..< 2 * g.TUNINGS[.Play].spawn_every_ticks {
		step_with(simulation, {0, 1}, {})
	}
	testing.expect(t, state.enemies.count > 0)
	testing.expect_value(t, state.wave, 0) // the HUD shows wave + 1
	testing.expect_value(t, state.circle_radius, 0)
	testing.expect(t, simulation.tick > state.match_tick)

	// Everyone present dies in the same tick: over; nobody respawns; after the hold, a fresh lobby.
	sim.slot_data(simulation, 0).hp, sim.slot_data(simulation, 1).hp = 0, 0 // they die at the next tick's start
	step_with(simulation, {0, 1}, {})
	testing.expect_value(t, state.phase, g.Phase.Over)
	over := simulation.tick
	for _ in 0 ..< g.OVER_HOLD_TICKS - 1 {
		step_with(simulation, {0, 1}, {})
		testing.expect(t, !sim.slot_data(simulation, 0).alive)
	}
	testing.expect_value(t, state.phase, g.Phase.Over)
	step_with(simulation, {0, 1}, {})
	testing.expect_value(t, simulation.tick, over + g.OVER_HOLD_TICKS)
	testing.expect_value(t, state.phase, g.Phase.Lobby)
	testing.expect_value(t, state.enemies.count, 0)
	testing.expect(
		t,
		sim.slot_data(simulation, 0).alive &&
		sim.slot_data(simulation, 1).alive &&
		sim.slot_data(simulation, 2) == nil,
	)
	testing.expect_value(t, sim.slot_data(simulation, 0).level, 1)
	testing.expect_value(t, state.matches, 1)
}

@(test)
joining_mid_match_spawns_at_the_start_spot :: proc(t: ^testing.T) {
	simulation := sim.create(&g.GAME, 4)
	defer sim.destroy(simulation)
	for simulation.state.phase == .Lobby && simulation.tick < 200 {
		step_with(simulation, {0}, {move_z = 127})
	}
	testing.expect_value(t, simulation.state.phase, g.Phase.Match)
	step_with(simulation, {0, 3}, {})
	testing.expect(t, sim.slot_data(simulation, 3).alive)
	testing.expect_value(t, sim.slot_data(simulation, 3).pos.x, g.PLAYER_START[3].x)
}

@(test)
levels_start_at_one :: proc(t: ^testing.T) {
	simulation := sim.create(&g.GAME, 2)
	defer sim.destroy(simulation)
	step_with(simulation, {0}, {})
	testing.expect_value(t, sim.slot_data(simulation, 0).level, 1)
	testing.expect_value(
		t,
		g.xp_next(&simulation.state.tuning, sim.slot_data(simulation, 0).level),
		g.TUNINGS[.Play].xp_first,
	)
}

@(test)
no_items_inside_the_start_circle :: proc(t: ^testing.T) {
	for i in 0 ..< g.ITEM_COUNT {
		spot := g.item_position(i)
		testing.expectf(t, spot.x * spot.x + spot.z * spot.z > 4.0 * 4.0, "item %d at %v", i, spot)
	}
}

// The `play` tuning played by the bot (games/survivor/simulation/survivor/bot.odin) over 8 seeds: guards the tuning's targets as a population, so one unlucky seed can't fail it or pass it: every seed's first
// level-up comes in 10..45 s, and on average the bot survives past 120 s and reaches wave 3.5. A balance check, not a
// correctness one: `uni test --long` only.
when scenarios.LONG {
	@(test)
	play_tuning_with_the_bot :: proc(t: ^testing.T) {
		SEEDS :: 8
		survived_sum, wave_sum: f32
		for seed in 1 ..= u64(SEEDS) {
			game := g.GAME
			game.scripted_input, game.scripted_commands = g.bot_input, g.bot_commands
			simulation := sim.create(&game, seed)
			defer sim.destroy(simulation)
			state := &simulation.state
			first_level: f32 = -1
			bots := headless.Headless(g.Game) {
				game = &game,
			}
			commands: headless.Scripted_Commands(g.Game)
			defer headless.scripted_commands_destroy(&commands)
			for simulation.tick < 200 * g.TICK_HZ && state.phase != .Over {
				inputs := headless.scripted(&bots, simulation, simulation.tick + 1, 1, &commands)
				sim.step(simulation, &inputs)
				if first_level < 0 && sim.slot_data(simulation, 0).level > 1 {
					first_level = sim.seconds(simulation.tick - state.match_tick, g.TICK_HZ)
				}
			}
			survived_sum += sim.seconds(
				(state.phase == .Over ? state.over_tick : simulation.tick) - state.match_tick,
				g.TICK_HZ,
			)
			wave_sum += f32(state.wave)
			testing.expectf(
				t,
				first_level > 10 && first_level < 45,
				"seed %d: first level-up at %.1f s",
				seed,
				first_level,
			)
		}
		testing.expectf(
			t,
			survived_sum / SEEDS > 120,
			"mean survival %.1f s over %d seeds",
			survived_sum / SEEDS,
			SEEDS,
		)
		testing.expectf(t, wave_sum / SEEDS >= 3.5, "mean wave %.2f over %d seeds", wave_sum / SEEDS, SEEDS)
	}
}

// The arena is the level's (game/levels/arena.tscn): its eight pillars on a 14 m ring and the walls' inner faces at
// 30 m, which keep the enemies (they are no physics bodies).
@(test)
the_world_reads_the_arena_from_the_level :: proc(t: ^testing.T) {
	world := g.world_create(1, g.GAME.content)
	defer g.world_destroy(world)
	testing.expect_value(t, world.pillar_count, 8)
	testing.expect_value(t, world.arena_inner, 30)
	for pillar in world.pillars[:world.pillar_count] {
		ring := pillar.center.x * pillar.center.x + pillar.center.y * pillar.center.y
		testing.expectf(t, abs(ring - 14 * 14) < 0.01 && pillar.half == {1, 1}, "pillar %v", pillar)
	}
}
