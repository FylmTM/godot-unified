// Phases: lobby -> match on leaving the start circle, match -> over when everyone is dead, over ->
// lobby after the hold with a fresh world.
package test_survivor

import "core:testing"

import g "../survivor"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:sim"

// One sync-tested tick of the seated players (headless.run_seat), each with its input.
step :: proc(run: ^headless.Run(g.Game), input: [g.PLAYERS]g.Input = {}) {
	headless.run_step(run, input)
}

// The tick on which killing_tick kills every present player (0: none), through the game's own rule.
@(thread_local)
kill_tick: u32

// g.tick, after killing everyone present on kill_tick: the tick of a copy of g.GAME (the same tick on a re-simulation).
killing_tick :: proc(t: ^g.Tick) {
	if t.number == kill_tick {
		players := sim.iterate_present(t)
		for _, player in sim.next(&players) do g.damage_player(t, player, g.PLAYER_HP)
	}
	g.tick(t)
}

@(test)
lobby_match_over_lobby :: proc(t: ^testing.T) {
	game := g.GAME
	game.tick = killing_tick
	kill_tick = 0
	run := headless.run_begin(&game, 9, seated = 2)
	defer headless.run_end(&run)
	simulation := run.simulation
	state := &simulation.state
	for _ in 0 ..< 64 {
		step(&run) // standing still: stays in the lobby, no enemies
	}
	testing.expect_value(t, state.phase, g.Phase.Lobby)
	testing.expect_value(t, state.enemies.count, 0)
	testing.expect(
		t,
		sim.slot_data(simulation, 0) != nil &&
		sim.slot_data(simulation, 1) != nil &&
		sim.slot_data(simulation, 2) == nil,
	)

	// Player 0 walks out of the circle (+x): the match starts on the tick its centre crosses.
	started: u32
	for _ in 0 ..< 128 {
		step(&run, {0 = {move_x = 127}})
		if state.phase == .Match {
			started = simulation.tick
			break
		}
	}
	testing.expect(t, started > 0)
	testing.expect_value(t, state.match_tick, sim.Game_Time(started))
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
		step(&run)
	}
	testing.expect(t, state.enemies.count > 0)
	testing.expect_value(t, state.wave, 0) // the HUD shows wave + 1
	testing.expect(t, sim.game_time(state, simulation.tick) > state.match_tick)

	// Everyone present dies in the same tick: over; nobody respawns; after the hold, a fresh lobby.
	kill_tick = simulation.tick + 1
	step(&run)
	testing.expect_value(t, state.phase, g.Phase.Over)
	over := simulation.tick
	for _ in 0 ..< g.OVER_HOLD_TICKS - 1 {
		step(&run)
		testing.expect(t, !sim.slot_data(simulation, 0).alive)
	}
	testing.expect_value(t, state.phase, g.Phase.Over)
	step(&run)
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
	scenarios.expect_synced(t, &run)
}

@(test)
joining_mid_match_spawns_at_the_start_spot :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 4, seated = 1)
	defer headless.run_end(&run)
	simulation := run.simulation
	for simulation.state.phase == .Lobby && simulation.tick < 200 {
		step(&run, {0 = {move_z = 127}})
	}
	testing.expect_value(t, simulation.state.phase, g.Phase.Match)
	headless.run_seat(&run, 3, 4)
	step(&run)
	testing.expect(t, sim.slot_data(simulation, 3).alive)
	testing.expect_value(t, sim.slot_data(simulation, 3).pos.x, simulation.world.spawns[3].x)
	scenarios.expect_synced(t, &run)
}

@(test)
levels_start_at_one :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 2, seated = 1)
	defer headless.run_end(&run)
	simulation := run.simulation
	testing.expect_value(t, sim.slot_data(simulation, 0).level, 1)
	testing.expect_value(
		t,
		g.xp_next(&simulation.state.tuning, sim.slot_data(simulation, 0).level),
		g.TUNINGS[.Play].xp_first,
	)
}

// The `play` tuning played by the bot (bot.odin) over 8 seeds: guards the tuning's targets as a population, so one
// unlucky seed can't fail it or pass it: on average the first level-up comes in 15..40 s (every seed's within 60 s),
// the bot survives past 120 s and reaches wave 3.5. A balance check, not a correctness one: `uni test --long` only.
// On the bare sim, not a sync-tested run: 8 matches of up to 200 s re-simulated every tick would cost minutes.
when scenarios.LONG {
	@(test)
	play_tuning_with_the_bot :: proc(t: ^testing.T) {
		SEEDS :: 8
		first_level_sum, survived_sum, wave_sum: f32
		for seed in 1 ..= u64(SEEDS) {
			game := g.GAME
			game.scripted_input, game.scripted_commands = bot_input, bot_commands
			simulation := sim.create(&game, seed)
			defer sim.destroy(simulation)
			bot_world = simulation.world
			state := &simulation.state
			first_level: f32 = -1
			commands: headless.Scripted_Commands(g.Game)
			defer headless.scripted_commands_destroy(&commands)
			for simulation.tick < 200 * g.TICK_HZ && state.phase != .Over {
				inputs := headless.scripted(&game, simulation, simulation.tick + 1, 1, &commands)
				sim.step(simulation, &inputs)
				if first_level < 0 && sim.slot_data(simulation, 0).level > 1 {
					first_level = sim.seconds(sim.game_time(state, simulation.tick) - state.match_tick, g.TICK_HZ)
				}
			}
			survived_sum += sim.seconds(
				(state.phase == .Over ? state.over_hold.start : sim.game_time(state, simulation.tick)) -
				state.match_tick,
				g.TICK_HZ,
			)
			wave_sum += f32(state.wave)
			first_level_sum += first_level
			testing.expectf(
				t,
				first_level > 0 && first_level < 60,
				"seed %d: first level-up at %.1f s",
				seed,
				first_level,
			)
		}
		testing.expectf(
			t,
			first_level_sum / SEEDS > 15 && first_level_sum / SEEDS < 40,
			"mean first level-up at %.1f s over %d seeds",
			first_level_sum / SEEDS,
			SEEDS,
		)
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
	world := g.world_create(1, g.GAME.levels, {})
	defer g.world_destroy(world)
	testing.expect_value(t, len(sim.slice(&world.pillars)), 8)
	testing.expect_value(t, world.arena_inner, 30)
	for pillar in sim.slice(&world.pillars) {
		ring := pillar.center.x * pillar.center.x + pillar.center.y * pillar.center.y
		testing.expectf(t, abs(ring - 14 * 14) < 0.01 && pillar.half == {1, 1}, "pillar %v", pillar)
	}
}
