package drift

import "unified:physics"
import "unified:sim"

// The whole simulation state: one pointer-free block (checked by sim.create). The bodies are Box3D's, which
// physics.extra snapshots with it.
State :: struct {
	level:          sim.Active_Level(Level_Id), // the arena, entered by init
	station:        physics.Body_Ref,
	station_hp:     i32,
	phase:          Phase,
	_pad:           u8,
	waves:          u16, // waves started this match
	match_tick:     sim.Game_Time, // the tick the current match started
	over_tick:      sim.Game_Time, // the tick it ended
	next_wave_tick: sim.Game_Time,
	next_rock_tick: sim.Game_Time,
	rocks_left:     u32, // of the current wave
	spawner:        u32, // the next rock_spawn marker, in turn
	score:          u32, // gems picked this match
	gems_dropped:   u32, // small rocks destroyed, for GEM_DROP_EVERY
	players:        sim.Players(Ship, sim.No_Profile, Input, PLAYERS),
	gates:          [MAX_GATES]Gate,
	rocks:          sim.Table(Rock, MAX_ROCKS),
	bullets:        sim.Table(Bullet, MAX_BULLETS),
	gems:           sim.Table(Gem, MAX_GEMS),
}

// lobby: ships fly, no rocks; `start` begins a match. match: waves of rocks. over: the station's HP reached 0; after
// OVER_HOLD_TICKS, or on `restart`, the world resets and the lobby begins again.
Phase :: enum u8 {
	Lobby,
	Match,
	Over,
}

// A player's ship (their data in sim.Players): zeroed when someone new joins, kept while they are away. Its body
// exists only while the player is present (destroyed when they leave, made again at their slot's spawn when they come
// back).
Ship :: struct {
	body:           physics.Body_Ref,
	fire_cooldown:  sim.Timer, // no shot while it runs (FIRE_EVERY_TICKS)
	boost_cooldown: sim.Timer, // no boost while it runs (BOOST_COOLDOWN_TICKS)
	gate_cooldown:  sim.Timer, // no warp while it runs (GATE_CHARGE_TICKS)
	thrust:         bool, // thrusting this tick (the view's flame)
	warp:           u8, // bumped where the ship is moved (a gate, the reset): its view snaps (godot.View_Item.warp)
	_pad:           [2]u8,
	shots:          u32,
	gems:           u32,
}

Rock_Size :: enum u8 {
	Small,
	Medium,
	Large,
}

// A rock's body is tagged with its handle's key, so a bullet's ray names it.
Rock :: struct {
	body:     physics.Body_Ref,
	hit_tick: sim.Game_Time, // the last bullet hit (the view's flash)
	size:     Rock_Size,
	variant:  u8, // its shape, 0 ..< ROCK_VARIANTS
	hp:       u8,
	_pad:     u8,
}

// Bullets are no bodies: each tick casts a ray along its path.
Bullet :: struct {
	pos:   [2]f32,
	vel:   [2]f32,
	owner: sim.Player, // who fired it (their colour; whether present or not)
	ttl:   u16, // ticks left
	_pad:  u16,
}

Gem :: struct {
	pos:        [2]f32,
	vel:        [2]f32,
	spawn_tick: sim.Game_Time,
}

// A gate's state (its place and pair are the level's: World.gates).
Gate :: struct {
	charge: sim.Timer, // no warp from it while it runs (GATE_CHARGE_TICKS)
}
