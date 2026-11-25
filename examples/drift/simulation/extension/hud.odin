package drift_extension

import "unified:sim"

import g "../drift"

// ---- the session data: the HUD (Unified.data.hud)

Data :: union {
	Data_Hud,
}

// A slot's player (zero for an empty slot: who holds it, UnifiedSession.players).
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

hud_of :: proc(f: ^Frame) -> (hud: Data_Hud) {
	hud.phase = f.state.phase
	hud.wave = f.state.waves
	hud.station_hp = f.state.station_hp
	hud.score = f.state.score
	hud.rocks = u32(f.state.rocks.count)
	switch f.state.phase {
	case .Lobby:
	case .Match:
		hud.time_s = sim.seconds(f.time - f.state.match_tick, g.TICK_HZ)
		hud.next_wave_s = sim.timer_remaining_s(f.time, f.state.next_wave, g.TICK_HZ)
	case .Over:
		hud.time_s = sim.seconds(f.state.over_hold.start - f.state.match_tick, g.TICK_HZ)
		hud.reset_in_s = sim.timer_remaining_s(f.time, f.state.over_hold, g.TICK_HZ)
	}
	for slot in 0 ..< g.PLAYERS {
		ship := sim.slot_data(&f.state.players, slot)
		if ship == nil do continue
		hud.players[slot] = {
			shots = ship.shots,
			gems  = ship.gems,
		}
	}
	return
}
