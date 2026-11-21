package horde

import "unified:sim"

// Every event the sim emits: the library's joins and leaves, and the game's own. Positions are sim.position_2d
// points on the arena's plane. Hits, arcs and gem pickups come by the hundred per second at full load: they are the
// load a view's event path carries.
Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
	Event_Enemy_Hit,
	Event_Enemy_Died,
	Event_Arc,
	Event_Bolt_Fired,
	Event_Bomb_Landed,
	Event_Gem_Collected,
	Event_Level_Up,
	Event_Hero_Hurt,
	Event_Hero_Down,
	Event_Match_Over,
}

// What dealt a hit (a damage number's colour).
Source :: enum u8 {
	Bolt,
	Lightning,
	Blast,
}

// `enemy` took `damage` at `position` (a damage number, a hit flash).
Event_Enemy_Hit :: struct {
	enemy:    sim.Handle(Enemy),
	position: sim.Position,
	damage:   i32,
	source:   Source,
	_pad:     [3]u8,
}

// `enemy` died at `position` (a burst of particles).
Event_Enemy_Died :: struct {
	enemy:    sim.Handle(Enemy),
	position: sim.Position,
	enemy_kind: Enemy_Kind,
	_pad:     [3]u8,
}

// One link of a lightning strike, from `from` (the hero, or the enemy before) to `to`; `link` 0 is the first.
Event_Arc :: struct {
	player: sim.Player,
	from:   sim.Position,
	to:     sim.Position,
	link:   u8,
	_pad:   [3]u8,
}

// `player` fired a fan of `count` bolts (a sound).
Event_Bolt_Fired :: struct {
	player:   sim.Player,
	position: sim.Position,
	count:    u8,
	_pad:     [3]u8,
}

// A bomb landed and blasted `radius` around `position` (a shockwave, a shake).
Event_Bomb_Landed :: struct {
	position: sim.Position,
	radius:   f32,
}

// `player` picked up a gem worth `xp`.
Event_Gem_Collected :: struct {
	gem:      sim.Handle(Gem),
	position: sim.Position,
	xp:       i32,
	player:   sim.Player,
}

// `player` reached `level`.
Event_Level_Up :: struct {
	player:   sim.Player,
	position: sim.Position,
	level:    i32,
}

// `player` lost `damage` HP.
Event_Hero_Hurt :: struct {
	player:   sim.Player,
	position: sim.Position,
	damage:   i32,
}

// `player` went down (they stand up after HERO_RESPAWN_S, unless the match is over first).
Event_Hero_Down :: struct {
	player:   sim.Player,
	position: sim.Position,
}

// Every present hero is down: the match lasted `duration_s`, reached `wave` and killed `kills`.
Event_Match_Over :: struct {
	duration_s: f32,
	wave:       u32,
	kills:      u32,
}
