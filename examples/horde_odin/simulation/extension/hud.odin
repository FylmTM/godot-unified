package horde_odin_extension

import "unified:sim"

import g "../../../horde/simulation/horde"

UPGRADE_TEXT := [g.Upgrade]string {
	.Bolt_Count  = "+1 bolt",
	.Bolt_Pierce = "+1 pierce",
	.Fire_Rate   = "faster bolts",
	.Chains      = "+1 chain",
	.Bomb_Radius = "bigger blasts",
	.Move_Speed  = "faster feet",
	.Max_Hp      = "+25 max HP",
}

// What both UIs show, read straight from the shown State: the match and the local hero.
Hud :: struct {
	wave, enemies, kills: u32,
	time_s:               f32,
	hp, hp_max:           i32,
	xp, xp_next:          i32,
	level:                i32,
	offers:               [3]g.Upgrade,
	pending:              bool,
	over:                 bool,
}

hud_of :: proc(d: ^Draw) -> (hud: Hud) {
	state := d.state
	hud = {
		wave    = state.wave,
		enemies = u32(state.enemies.count),
		kills   = state.kills,
		time_s  = f32(sim.game_time(state, d.tick) - state.match_tick) / f32(g.TICK_HZ),
		over    = state.phase == .Over,
	}
	player := d.local_players[0]
	if hero := sim.player_data(&state.players, player); hero != nil {
		hud.hp, hud.hp_max = hero.hp, hero.hp_max
		hud.xp, hud.xp_next = hero.xp, g.xp_to_next(hero.level)
		hud.level = hero.level
		if hero.pending_levelups > 0 {
			hud.pending = true
			hud.offers = g.upgrade_offers(d.seed, player, g.oldest_pending_level(hero))
		}
	}
	return
}

// The frame rate the HUD shows, smoothed (real frames, not ticks).
fps_smoothed: f32

fps_update :: proc(d: ^Draw) -> f32 {
	if d.dt > 0 do fps_smoothed += (1 / d.dt - fps_smoothed) * 0.05
	return fps_smoothed
}
