package drift

import "unified:physics"
import "unified:sim"

// The tick's commands, by player in slot order: `start` begins a match from the lobby, `restart` resets an over match
// at once. Either is ignored outside its phase.
apply_commands :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for _, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			switch _ in sent {
			case Command_Start:
				if t.state.phase == .Lobby do start_match(t, player)
			case Command_Restart:
				if t.state.phase == .Over do reset_world(t)
			}
		}
	}
}

start_match :: proc(t: ^Tick, player: sim.Player) {
	t.state.phase = .Match
	t.state.match_tick = t.time
	sim.timer_start_ticks(t, &t.state.next_wave, 0) // the first wave: this tick
	t.state.waves = 0
	t.state.rocks_left = 0
	t.state.score = 0
	sim.emit(t, Event_Match_Started{player = player})
}

// At the end of the tick: a match is over when the station's HP is 0, an over match resets after OVER_HOLD_TICKS,
// and the world resets whenever nobody is present.
advance_phase :: proc(t: ^Tick) {
	if sim.present_count(t) == 0 {
		if t.state.phase != .Lobby do reset_world(t)
		return
	}
	switch t.state.phase {
	case .Lobby:
	case .Match:
		if t.state.station_hp <= 0 {
			t.state.phase = .Over
			sim.timer_start_ticks(t, &t.state.over_hold, OVER_HOLD_TICKS)
			sim.emit(t, Event_Match_Over{duration_s = sim.seconds(t.time - t.state.match_tick, TICK_HZ)})
		}
	case .Over:
		if sim.timer_done(t, t.state.over_hold) do reset_world(t)
	}
}

// Back to the lobby: rocks, bullets and gems cleared, the present ships at rest at their slots' spawns, the gates
// charged, the station repaired.
reset_world :: proc(t: ^Tick) {
	physics.despawn_all(t.world.phys, &t.state.rocks)
	sim.despawn_all(&t.state.bullets)
	sim.despawn_all(&t.state.gems)
	ships := sim.iterate_present(t)
	for ship, player in sim.next(&ships) {
		physics.body_teleport_2d(t.world.phys, ship.body, t.world.spawns[sim.player_slot(t, player)], UP)
		ship.fire_cooldown, ship.boost_cooldown, ship.gate_cooldown = {}, {}, {}
	}
	t.state.gates = {}
	t.state.phase = .Lobby
	t.state.station_hp = STATION_HP
	t.state.waves = 0
	t.state.rocks_left = 0
}
