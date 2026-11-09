// What a UI shows, derived from the state: the data behind the GDScript `UnifiedSession.hud()`
// contract (the host adds local_slot and converts to a Dictionary). Not simulation code: f32 for
// display only.
package survivor

Hud_Player :: struct {
	slot:             int,
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
	phase:         Phase,
	phase_name:    string, // "lobby" | "match" | "over"
	tick:          u32,
	time_s:        f32, // match time: 0 in the lobby, frozen when over
	wave:          u32, // 1-based during a match, 0 in the lobby
	enemies_alive: i32,
	circle_radius: f32, // the start circle (lobby), 0 otherwise
	matches:       u32,
	players:       [MAX_PLAYERS]Hud_Player,
}

PHASE_NAMES := [Phase]string {
	.Lobby = "lobby",
	.Match = "match",
	.Over  = "over",
}

hud :: proc(s: ^State, tick: u32) -> (h: Hud) {
	h.phase = s.phase
	h.phase_name = PHASE_NAMES[s.phase]
	h.tick = tick
	switch s.phase {
	case .Lobby:
	case .Match:
		h.time_s = f32(tick - s.match_tick) * DT
		h.wave = s.wave + 1
	case .Over:
		h.time_s = f32(s.over_tick - s.match_tick) * DT
		h.wave = s.wave + 1
	}
	h.enemies_alive = s.enemies.count
	h.circle_radius = s.circle_radius
	h.matches = s.matches
	for &pl, p in s.players {
		h.players[p] = {
			slot             = p,
			present          = pl.active,
			alive            = pl.alive,
			hp               = max(pl.hp, 0),
			hp_max           = PLAYER_HP,
			xp               = pl.xp,
			xp_next          = xp_next(s, pl.level),
			level            = pl.level,
			pending_levelups = pl.pending_levelups,
			respawn_s        = pl.alive || !pl.active ? 0 : f32(pl.respawn) * DT,
		}
	}
	return
}
