// The HUD's session data (Data_Hud, pushed every frame by fill_frame with godot.push_data): what a UI shows,
// derived from the state on the session thread. GDScript reads it as `Unified.data.hud` (class DataHud, typed
// properties, `changed` when it changes): `phase` is an EnumPhase value, `players` an Array of Dictionaries (by slot;
// `player` is the player's key, 0 for an empty slot). Player names and the local player come from the session
// (Game.player_name, Game.local_player). View code, not simulation code: f32 for display only. Plain and
// padding-free (`_pad`).
package survivor_extension

import "unified:sim"

import "../survivor"

Data :: union {
	Data_Hud,
}

Hud_Player :: struct {
	player:           sim.Player, // who holds the slot ({}: nobody)
	present:          bool,
	alive:            bool,
	_pad:             [2]u8,
	hp:               i32,
	hp_max:           i32,
	xp:               i32,
	xp_next:          i32,
	level:            i32,
	pending_levelups: i32,
	respawn_s:        f32, // seconds until respawn (0 when alive)
}

Data_Hud :: struct {
	phase:         survivor.Phase, // lobby, match, over
	_pad:          [3]u8,
	tick:          u32,
	time_s:        f32, // match time: 0 in the lobby, frozen when over
	wave:          u32, // 1-based during a match, 0 in the lobby
	enemies_alive: i32,
	circle_radius: f32, // the start circle (lobby), 0 otherwise
	matches:       u32,
	players:       [survivor.PLAYERS]Hud_Player,
}

hud_of :: proc(state: ^survivor.State, tick: u32) -> (hud: Data_Hud) {
	hud.phase = state.phase
	hud.tick = tick
	switch state.phase {
	case .Lobby:
	case .Match:
		hud.time_s = f32(tick - state.match_tick) * survivor.DT
		hud.wave = state.wave + 1
	case .Over:
		hud.time_s = f32(state.over_tick - state.match_tick) * survivor.DT
		hud.wave = state.wave + 1
	}
	hud.enemies_alive = state.enemies.count
	hud.circle_radius = state.circle_radius
	hud.matches = state.matches
	for slot in 0 ..< survivor.PLAYERS {
		player := sim.player_in_slot(&state.players, slot)
		character := sim.player_data(&state.players, player)
		if character == nil do continue
		hud.players[slot] = {
			player           = player,
			present          = true,
			alive            = character.alive,
			hp               = max(character.hp, 0),
			hp_max           = survivor.PLAYER_HP,
			xp               = character.xp,
			xp_next          = survivor.xp_next(state, character.level),
			level            = character.level,
			pending_levelups = character.pending_levelups,
			respawn_s        = character.alive ? 0 : f32(character.respawn) * survivor.DT,
		}
	}
	return
}
