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
	h := survivor.hud(&s.state, s.tick)
	testing.expect_value(t, h.phase_name, "lobby")
	testing.expect_value(t, h.circle_radius, survivor.START_RADIUS)
	testing.expect(t, h.players[0].present && h.players[1].present && !h.players[2].present)

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
	for _ in 0 ..< 2 * survivor.SPAWN_EVERY_TICKS {
		step_with(s, {0, 1}, {})
	}
	testing.expect(t, s.state.enemies.count > 0)
	h = survivor.hud(&s.state, s.tick)
	testing.expect_value(t, h.wave, 1)
	testing.expect_value(t, h.circle_radius, 0)
	testing.expect(t, h.time_s > 0)

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
	testing.expect_value(t, s.state.players[0].level, 0)
	testing.expect_value(t, s.state.matches, 1)
	h = survivor.hud(&s.state, s.tick)
	testing.expect_value(t, h.phase_name, "lobby")
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
	testing.expect_value(t, survivor.WAVE_TICKS, 640)
}
