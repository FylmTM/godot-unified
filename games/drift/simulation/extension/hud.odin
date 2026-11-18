package extension

import "unified:sim"

import g "../drift"

// ---- the session data: the HUD (Unified.data.hud)

Data :: union {
	Data_Hud,
}

// A slot's player (zero for an empty slot: who holds it, UnifiedSession.get_players).
Hud_Player :: struct {
	shots: u32,
	gems:  u32,
}

Data_Hud :: struct {
	players:     [g.PLAYERS]Hud_Player,
	phase:       g.Phase, // EnumPhase in GDScript
	_pad:        u8,
	wave:        u16,
	station_hp:  i32, // of Unified.constants.station_hp
	score:       u32,
	rocks:       u32,
	time_s:      f32, // match time (over: survived)
	next_wave_s: f32, // match: until the next wave
	reset_in_s:  f32, // over: until back to the lobby
}

hud_of :: proc(state: ^g.State, tick: u32) -> (hud: Data_Hud) {
	hud.phase = state.phase
	hud.wave = state.waves
	hud.station_hp = state.station_hp
	hud.score = state.score
	hud.rocks = u32(state.rocks.count)
	switch state.phase {
	case .Lobby:
	case .Match:
		hud.time_s = sim.seconds(tick - state.match_tick, g.TICK_HZ)
		hud.next_wave_s = state.next_wave_tick > tick ? sim.seconds(state.next_wave_tick - tick, g.TICK_HZ) : 0
	case .Over:
		hud.time_s = sim.seconds(state.over_tick - state.match_tick, g.TICK_HZ)
		end := state.over_tick + g.OVER_HOLD_TICKS
		hud.reset_in_s = end > tick ? sim.seconds(end - tick, g.TICK_HZ) : 0
	}
	for slot in 0 ..< g.PLAYERS {
		ship := sim.slot_data(&state.players, slot)
		if ship == nil do continue
		hud.players[slot] = {
			shots = ship.shots,
			gems  = ship.gems,
		}
	}
	return
}
