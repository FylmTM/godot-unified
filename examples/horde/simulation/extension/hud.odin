// The HUD's session data (Data_Hud, pushed every frame by fill_frame with godot.push_data): what a UI shows, derived
// from the state on the session thread. GDScript reads it as `Unified.data.hud` (class DataHud, typed properties,
// `changed` when it changes): `phase` is an EnumPhase value, `heroes` an Array[DataHudHero] by slot (zero for an empty
// slot). Who holds a slot, the names and the local player come from the session. View code, not simulation code: f32
// for display only. Plain and padding-free (`_pad`).
package horde_extension

import "unified:sim"

import g "../horde"

// The session data.
Data :: union {
	Data_Hud,
}

// One slot's hero: its HP, progress and, while a level-up is pending, the three upgrades the oldest one offers.
Hud_Hero :: struct {
	alive:            bool,
	offers:           [3]g.Upgrade, // the oldest pending level-up's offers (g.upgrade_offers; pending_levelups > 0)
	hp:               i32,
	hp_max:           i32,
	xp:               i32,
	xp_next:          i32,
	level:            i32,
	pending_levelups: i32,
	respawn_s:        f32, // seconds until a downed hero stands up (0 when alive)
}

// The match and every slot's hero.
Data_Hud :: struct {
	phase:      g.Phase, // match, over
	_pad:       [3]u8,
	time_s:     f32, // match time, frozen when over
	wave:       u32, // 1-based
	enemies:    i32, // alive
	kills:      u32, // this match
	reset_in_s: f32, // over: seconds until the arena resets (0 otherwise)
	heroes:     [g.PLAYERS]Hud_Hero,
}

// The HUD's data of the frame's tick: reads the state, never writes it.
hud_of :: proc(f: ^Frame) -> (hud: Data_Hud) {
	hud.phase = f.state.phase
	hud.wave = f.state.wave + 1
	hud.enemies = f.state.enemies.count
	hud.kills = f.state.kills
	switch f.state.phase {
	case .Match:
		hud.time_s = sim.seconds(f.time - f.state.match_tick, g.TICK_HZ)
	case .Over:
		hud.time_s = sim.seconds(f.state.over_hold.start - f.state.match_tick, g.TICK_HZ)
		hud.reset_in_s = sim.timer_remaining_s(f.time, f.state.over_hold, g.TICK_HZ)
	}
	for slot in 0 ..< g.PLAYERS {
		hero := sim.slot_data(&f.state.players, slot)
		if hero == nil do continue
		hud.heroes[slot] = {
			alive            = hero.alive,
			hp               = hero.hp,
			hp_max           = hero.hp_max,
			xp               = hero.xp,
			xp_next          = g.xp_to_next(hero.level),
			level            = hero.level,
			pending_levelups = hero.pending_levelups,
			respawn_s        = hero.alive ? 0 : sim.timer_remaining_s(f.time, hero.respawn, g.TICK_HZ),
		}
		if hero.pending_levelups > 0 { 	// the roll the sim makes for the pick, peeked: nothing in the block changes
			player := sim.player_in_slot(&f.state.players, slot)
			hud.heroes[slot].offers = g.upgrade_offers(f.seed, player, g.oldest_pending_level(hero))
		}
	}
	return
}
