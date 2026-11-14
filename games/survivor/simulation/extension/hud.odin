// What a UI shows, derived from the state on the session thread: the data behind the GDScript
// `UnifiedSession.hud()` contract (the host adds local_player and converts to a Dictionary, see
// extension.odin). View code, not simulation code: f32 for display only.
package survivor_extension

import "../survivor"

Hud_Player :: struct {
	player:           int,
	present:          bool,
	alive:            bool,
	hp:               i32,
	hp_max:           i32,
	xp:               i32,
	xp_next:          i32,
	level:            i32,
	pending_levelups: i32,
	respawn_s:        f32, // seconds until respawn (0 when alive)
}

Hud :: struct {
	phase:         survivor.Phase,
	phase_name:    string, // "lobby" | "match" | "over"
	tick:          u32,
	time_s:        f32, // match time: 0 in the lobby, frozen when over
	wave:          u32, // 1-based during a match, 0 in the lobby
	enemies_alive: i32,
	circle_radius: f32, // the start circle (lobby), 0 otherwise
	matches:       u32,
	players:       [survivor.PLAYERS]Hud_Player,
}

@(rodata)
PHASE_NAMES := [survivor.Phase]string {
	.Lobby = "lobby",
	.Match = "match",
	.Over  = "over",
}

hud_of :: proc(state: ^survivor.State, tick: u32) -> (hud: Hud) {
	hud.phase = state.phase
	hud.phase_name = PHASE_NAMES[state.phase]
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
	for &character, player in state.players {
		hud.players[player] = {
			player           = player,
			present          = character.active,
			alive            = character.alive,
			hp               = max(character.hp, 0),
			hp_max           = survivor.PLAYER_HP,
			xp               = character.xp,
			xp_next          = survivor.xp_next(state, character.level),
			level            = character.level,
			pending_levelups = character.pending_levelups,
			respawn_s        = character.alive || !character.active ? 0 : f32(character.respawn) * survivor.DT,
		}
	}
	return
}
