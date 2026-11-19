package survivor

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// The phases: lobby -> match when a player leaves the start circle; match -> over when every present player is dead at
// once (or nobody is present: back to the lobby); over -> lobby (the world reset) after the hold.
advance_phase :: proc(t: ^Tick) {
	present, alive := 0, 0
	players := sim.iterate_present(t)
	for character in sim.next(&players) {
		present += 1
		alive += int(character.alive)
	}
	switch t.state.phase {
	case .Lobby:
		players = sim.iterate_present(t)
		for character, player in sim.next(&players) {
			if character.alive && dmath.length_sq(character.pos.xz) > START_RADIUS * START_RADIUS {
				t.state.phase = .Match
				t.state.match_tick = t.number
				t.state.over_tick = 0
				t.state.wave = 0
				sim.emit(t, Event_Match_Started{position = sim.Position(character.pos), player = player})
				break
			}
		}
	case .Match:
		t.state.wave = (t.number - t.state.match_tick) / t.state.tuning.wave_ticks
		if present == 0 {
			reset_world(t)
		} else if alive == 0 && !t.state.tuning.endless {
			t.state.phase = .Over
			t.state.over_tick = t.number
			t.state.best_wave = dmath.max(t.state.best_wave, t.state.wave + 1)
			sim.emit(t, Event_Match_Over {
				duration_s = sim.seconds(t.number - t.state.match_tick, TICK_HZ),
				waves      = t.state.wave + 1,
				best_wave  = t.state.best_wave,
			})
		}
	case .Over:
		if t.number - t.state.over_tick >= OVER_HOLD_TICKS {
			reset_world(t)
		}
	}
}

// Back to the lobby: every dynamic body is destroyed and rebuilt in creation order (items at their spots, then
// present players at their start spots, in slot order); everyone's progress starts fresh, absent players' too;
// enemies, projectiles and gems go.
reset_world :: proc(t: ^Tick) {
	for &item in t.state.items[:t.world.items.count] {
		physics.destroy_body(t.world.phys, &item.body)
	}
	known := sim.iterate_known(t)
	for character in sim.next(&known) {
		physics.destroy_body(t.world.phys, &character.body)
		character_reset(character, character.role)
	}
	for i in 0 ..< int(t.world.items.count) {
		item_reset(t.state, t.world, i)
	}
	for slot in 0 ..< PLAYERS {
		player := sim.player_in_slot(t, slot)
		if character := sim.player_data(t, player); character != nil {
			character_spawn(t.world, character, slot)
			sim.emit(t, Event_Player_Respawned{position = sim.Position(character.pos), player = player})
		}
	}
	sim.despawn_all(&t.state.enemies)
	sim.despawn_all(&t.state.projectiles)
	sim.despawn_all(&t.state.gems)
	t.state.phase = .Lobby
	t.state.match_tick = 0
	t.state.over_tick = 0
	t.state.wave = 0
}
