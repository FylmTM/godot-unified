package horde_hybrid_extension

import "unified:dmath"
import "unified:godot"
import "unified:sim"

import g "../../../horde/simulation/horde"

Frame :: godot.Frame(g.Game, View, MultiView)

UNIT_PX :: 32 // view pixels per sim unit

// No scene views: the world is drawn in Odin (draw.odin).
View :: union {}

// No MultiMesh views either.
MultiView :: enum u8 {}

// The session data: the HUD's (GDScript reads it).
Data :: union {
	Data_Hud,
}

// The HUD: the match and the local hero.
Data_Hud :: struct {
	wave:    u32,
	enemies: u32,
	kills:   u32,
	time_s:  f32,
	hp:      i32,
	hp_max:  i32,
	xp:      i32,
	xp_next: i32,
	level:   i32,
	pending: i32,
	offers:  [3]g.Upgrade,
	phase:   g.Phase,
	alive:   bool,
	_pad:    [3]u8,
}

// Session thread, every published tick: only the HUD's data (the world is draw.odin's).
fill_frame :: proc(f: ^Frame) {
	hud := Data_Hud {
		wave    = f.state.wave,
		enemies = u32(f.state.enemies.count),
		kills   = f.state.kills,
		time_s  = f32(f.time - f.state.match_tick) / f32(g.TICK_HZ),
		phase   = f.state.phase,
	}
	if hero := sim.player_data(&f.state.players, f.local_players[0]); hero != nil {
		hud.hp = hero.hp
		hud.hp_max = hero.hp_max
		hud.xp = hero.xp
		hud.xp_next = g.xp_to_next(hero.level)
		hud.level = hero.level
		hud.pending = hero.pending_levelups
		hud.alive = hero.alive
		if hero.pending_levelups > 0 {
			hud.offers = g.upgrade_offers(f.seed, f.local_players[0], g.oldest_pending_level(hero))
		}
	}
	godot.push_data(f, hud)
}

// The stick from the arrow keys (and a pad's d-pad), through Godot's ui_* actions.
sample_input :: proc(_: int, input: ^g.Input) {
	move := godot.action_vector("ui_left", "ui_right", "ui_up", "ui_down")
	input.dx = dmath.axis_i8(move.x)
	input.dy = dmath.axis_i8(move.y)
}
