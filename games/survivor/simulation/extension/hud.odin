// The HUD's session data (Data_Hud, pushed every frame by fill_frame with godot.push_data): what a UI shows,
// derived from the state on the session thread. GDScript reads it as `Unified.data.hud` (class DataHud, typed
// properties, `changed` when it changes): `phase` is an EnumPhase value, `players` an Array[DataHudPlayer] by slot
// (zero for an empty slot). Who holds a slot, the names and the local player come from the session. View code, not
// simulation code: f32 for display only. Plain and padding-free (`_pad`).
package extension

import "unified:sim"

import g "../survivor"

Data :: union {
	Data_Hud,
}

Hud_Player :: struct {
	alive:            bool,
	offer_a:          g.Upgrade, // the oldest pending level-up's two offers (g.upgrade_offers; pending_levelups > 0)
	offer_b:          g.Upgrade,
	_pad:             u8,
	hp:               i32,
	hp_max:           i32,
	xp:               i32,
	xp_next:          i32,
	level:            i32,
	pending_levelups: i32,
	respawn_s:        f32, // seconds until respawn (0 when alive)
}

Data_Hud :: struct {
	phase:         g.Phase, // lobby, match, over
	_pad:          [3]u8,
	time_s:        f32, // match time: 0 in the lobby, frozen when over
	wave:          u32, // 1-based during a match, 0 in the lobby
	enemies_alive: i32,
	reset_in_s:    f32, // over: seconds until the world resets and the lobby begins again (0 otherwise)
	players:       [g.PLAYERS]Hud_Player,
}

hud_of :: proc(state: ^g.State, tick: u32, seed: u64) -> (hud: Data_Hud) {
	hud.phase = state.phase
	switch state.phase {
	case .Lobby:
	case .Match:
		hud.time_s = sim.seconds(tick - state.match_tick, g.TICK_HZ)
		hud.wave = state.wave + 1
	case .Over:
		hud.time_s = sim.seconds(state.over_tick - state.match_tick, g.TICK_HZ)
		hud.wave = state.wave + 1
		hud.reset_in_s = sim.seconds(state.over_tick + g.OVER_HOLD_TICKS - tick, g.TICK_HZ)
	}
	hud.enemies_alive = state.enemies.count
	for slot in 0 ..< g.PLAYERS {
		character := sim.slot_data(&state.players, slot)
		if character == nil do continue
		hud.players[slot] = {
			alive            = character.alive,
			hp               = max(character.hp, 0),
			hp_max           = g.PLAYER_HP,
			xp               = character.xp,
			xp_next          = g.xp_next(&state.tuning, character.level),
			level            = character.level,
			pending_levelups = character.pending_levelups,
			respawn_s        = character.alive ? 0 : sim.seconds(character.respawn, g.TICK_HZ),
		}
		if character.pending_levelups > 0 { 	// the roll the sim makes for the pick, peeked: nothing in the block changes
			offers := g.upgrade_offers(seed, state.players.slots[slot], g.oldest_pending_level(character))
			hud.players[slot].offer_a, hud.players[slot].offer_b = offers[0], offers[1]
		}
	}
	return
}
