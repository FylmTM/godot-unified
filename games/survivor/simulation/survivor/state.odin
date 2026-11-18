package survivor

import "unified:physics"
import "unified:sim"

// The whole simulation state: one pointer-free block (checked by sim.create).
State :: struct {
	phase:       Phase,
	_pad:        [3]u8,
	match_tick:  u32, // the tick the current match started (0: lobby)
	over_tick:   u32, // the tick it ended (0: not over)
	wave:        u32, // 0-based wave of the current match
	tuning:      Tuning, // the match's pace: a preset (init), lowered by the bench
	players:     sim.Players(Character, Input, PLAYERS),
	items:       [MAX_ITEMS]Item, // the level's items by index (World.items: item_count of them)
	enemies:     sim.Table(Enemy, MAX_ENEMIES),
	projectiles: sim.Table(Projectile, MAX_PROJECTILES),
	gems:        sim.Table(Gem, MAX_GEMS),
}

// lobby: present players gather in the start circle, no enemies; the match starts on the tick a player's centre leaves
// the circle. match: waves. over: every present player died at once; after OVER_HOLD_S the world resets and the lobby
// begins again.
Phase :: enum u8 {
	Lobby,
	Match,
	Over,
}

// A player's character and progress (the State's sim.Players data): zeroed for someone new, kept while they are away
// (a returning player keeps their level and upgrades). An absent or dead player has no body.
Character :: struct {
	body:             physics.Body_Ref,
	pos:              [3]f32, // the body's centre, read back after each physics step
	hp:               i32,
	respawn:          i32, // ticks until a dead player respawns
	dash_ticks:       i32,
	dash_cooldown:    i32,
	fire_cooldown:    i32,
	fire_interval:    i32,
	damage_bonus:     i32,
	speed:            f32,
	level:            i32,
	xp:               i32,
	pending_levelups: i32,
	alive:            bool, // has a body (present, not dead)
	_pad:             [3]u8,
}

Item_Kind :: enum u8 {
	Crate,
	Barrel,
}

// A crate or barrel the level placed (its kind and spot: World.items); the body's index tag is the item's.
Item :: struct {
	body:         physics.Body_Ref,
	hp:           i32, // barrels
	respawn_tick: u32, // barrels: the tick a destroyed one comes back (0: none pending)
	alive:        bool,
	_pad:         [3]u8,
}

Enemy_Kind :: enum u8 {
	Grunt,
	Runner,
	Brute,
}

// Enemies are no physics bodies: they move on the ground plane (x, z), pushed out of the pillars and kept inside the
// walls by the sim itself.
Enemy :: struct {
	spawn_tick:       u32, // for the view (age-based effects)
	hit_tick:         u32, // the last tick it took damage (0: never), for hit flashes
	pos:              [2]f32, // x, z
	vel:              [2]f32,
	hp:               i32,
	speed:            f32,
	radius:           f32,
	damage:           i32,
	contact_cooldown: u16,
	kind:             Enemy_Kind,
	climbing:         bool, // standing on a crate or barrel: slowed
}

Projectile :: struct {
	pos:    [3]f32,
	vel:    [3]f32,
	life:   i32,
	damage: i32,
}

Gem :: struct {
	pos:        [2]f32, // x, z
	value:      i32,
	spawn_tick: u32,
}
