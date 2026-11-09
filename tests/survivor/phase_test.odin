// Phases: lobby -> match on leaving the start circle, match -> over when everyone is dead, over ->
// lobby after the hold with a fresh world; the HUD view of it.
package test_survivor

import "core:testing"

import "../../games/survivor/simulation/survivor"
import "unified:sim"

// Steps with fixed inputs for the present slots.
step_with :: proc(s: ^survivor.Sim, present: sim.Players, in_: survivor.Input) {
	inputs: survivor.Inputs
	inputs.present = present
	for p in present {
		inputs.input[p] = in_
	}
	sim.step(s, &inputs)
}

@(test)
lobby_match_over_lobby :: proc(t: ^testing.T) {
	s := sim.create(&survivor.GAME, 9)
	defer sim.destroy(s)
	for _ in 0 ..< 64 {
		step_with(s, {0, 1}, {}) // standing still: stays in the lobby, no enemies
	}
	testing.expect_value(t, s.state.phase, survivor.Phase.Lobby)
	testing.expect_value(t, s.state.enemies.count, 0)
	st := &s.state
	testing.expect_value(t, st.phase, survivor.Phase.Lobby)
	testing.expect_value(t, st.circle_radius, survivor.START_RADIUS)
	testing.expect(t, st.players[0].active && st.players[1].active && !st.players[2].active)

	// Player 0 walks out of the circle (+x): the match starts on the tick its centre crosses.
	started: u32
	for _ in 0 ..< 128 {
		inputs: survivor.Inputs
		inputs.present = {0, 1}
		inputs.input[0] = {
			move_x = 127,
		}
		sim.step(s, &inputs)
		if s.state.phase == .Match {
			started = s.tick
			break
		}
	}
	testing.expect(t, started > 0)
	testing.expect_value(t, s.state.match_tick, started)
	pos := s.state.players[0].pos
	testing.expect(t, pos.x * pos.x + pos.z * pos.z > survivor.START_RADIUS * survivor.START_RADIUS)
	found := false
	for e in sim.events_at(s, started) {
		found ||= e.kind == u16(survivor.Event_Kind.Match_Started) && e.slot == 0
	}
	testing.expect(t, found)
	for _ in 0 ..< 2 * survivor.TUNINGS[.Play].spawn_every_ticks {
		step_with(s, {0, 1}, {})
	}
	testing.expect(t, s.state.enemies.count > 0)
	testing.expect_value(t, st.wave, 0) // the HUD shows wave + 1
	testing.expect_value(t, st.circle_radius, 0)
	testing.expect(t, s.tick > st.match_tick)

	// Everyone present dies in the same tick: over; nobody respawns; after the hold, a fresh lobby.
	ev: [dynamic]sim.Event
	defer delete(ev)
	survivor.damage_player(&s.state, s.world, 0, 1000, &ev)
	survivor.damage_player(&s.state, s.world, 1, 1000, &ev)
	step_with(s, {0, 1}, {})
	testing.expect_value(t, s.state.phase, survivor.Phase.Over)
	over := s.tick
	for _ in 0 ..< survivor.OVER_HOLD_TICKS - 1 {
		step_with(s, {0, 1}, {})
		testing.expect(t, !s.state.players[0].alive)
	}
	testing.expect_value(t, s.state.phase, survivor.Phase.Over)
	step_with(s, {0, 1}, {})
	testing.expect_value(t, s.tick, over + survivor.OVER_HOLD_TICKS)
	testing.expect_value(t, s.state.phase, survivor.Phase.Lobby)
	testing.expect_value(t, s.state.enemies.count, 0)
	testing.expect(t, s.state.players[0].alive && s.state.players[1].alive && !s.state.players[2].active)
	testing.expect_value(t, s.state.players[0].level, 1)
	testing.expect_value(t, s.state.matches, 1)
	testing.expect_value(t, st.phase, survivor.Phase.Lobby)
}

@(test)
joining_mid_match_spawns_at_the_start_spot :: proc(t: ^testing.T) {
	s := sim.create(&survivor.GAME, 4)
	defer sim.destroy(s)
	for s.state.phase == .Lobby && s.tick < 200 {
		step_with(s, {0}, {move_z = 127})
	}
	testing.expect_value(t, s.state.phase, survivor.Phase.Match)
	step_with(s, {0, 3}, {})
	testing.expect(t, s.state.players[3].alive)
	testing.expect_value(t, s.state.players[3].pos.x, survivor.PLAYER_START[3].x)
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
	s := sim.create(&survivor.GAME, 2)
	defer sim.destroy(s)
	step_with(s, {0}, {})
	testing.expect_value(t, s.state.players[0].level, 1)
	testing.expect_value(t, survivor.xp_next(&s.state, s.state.players[0].level), survivor.TUNINGS[.Play].xp_first)
	stress := sim.create(&survivor.GAME_STRESS, 2)
	defer sim.destroy(stress)
	testing.expect_value(t, stress.state.tuning, survivor.Tuning_Kind.Stress)
	testing.expect(t, stress.state.tune == survivor.TUNINGS[.Stress])
}

@(test)
no_items_inside_the_start_circle :: proc(t: ^testing.T) {
	for i in 0 ..< survivor.ITEM_COUNT {
		c := survivor.item_position(i)
		testing.expectf(t, c.x * c.x + c.z * c.z > 4.0 * 4.0, "item %d at %v", i, c)
	}
}

// The `play` tuning with the bot policy (games/survivor/simulation/survivor/bot.odin), 2 seeds:
// guards the tuning's targets (spec/GAME.md). `survivor bot` measures more seeds.
@(test)
play_tuning_with_the_bot :: proc(t: ^testing.T) {
	for seed in 1 ..= u64(2) {
		s := sim.create(&survivor.GAME, seed)
		defer sim.destroy(s)
		first_level: f32 = -1
		for s.tick < 200 * survivor.TICK_HZ && s.state.phase != .Over {
			in_: survivor.Inputs
			in_.present = {0}
			in_.input[0] = survivor.bot_input(&s.state, 0, s.tick + 1)
			sim.step(s, &in_)
			if first_level < 0 && s.state.players[0].level > 1 {
				first_level = f32(s.tick - s.state.match_tick) * survivor.DT
			}
		}
		survived := f32((s.state.phase == .Over ? s.state.over_tick : s.tick) - s.state.match_tick) * survivor.DT
		testing.expectf(
			t,
			first_level > 10 && first_level < 45,
			"seed %d: first level-up at %.1f s",
			seed,
			first_level,
		)
		testing.expectf(t, survived > 100, "seed %d: survived %.1f s", seed, survived)
		testing.expectf(t, s.state.wave >= 3, "seed %d: wave %d", seed, s.state.wave)
	}
}
