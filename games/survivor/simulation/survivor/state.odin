package survivor

import "unified:physics"
import "unified:sim"

// How hard a session plays (the Setup's): HARD_* scale the match's pace.
Difficulty :: enum u8 {
	Normal,
	Hard,
}

// The session's choices (sim.Game's Setup): the host's menu and save file, the same on every peer, in Welcome, the
// input log and every snapshot.
Setup :: struct {
	difficulty: Difficulty,
	_pad:       [3]u8,
	best_wave:  u32, // the host's saved record at this difficulty (waves survived; 0: none): progress enters the sim here
}

// What a player plays as (the Profile's): ROLE_* perks on top of the shared start.
Role :: enum u8 {
	Gunner, // fires faster
	Bruiser, // hits harder
	Runner, // moves faster
}

// What a player chose before joining (sim.Game's Profile): on their join tick, before `tick` runs.
Profile :: struct {
	role: Role,
	_pad: [3]u8,
}

// The whole simulation state: one pointer-free block (checked by sim.create).
State :: struct {
	level:       sim.Active_Level(Level_Id), // the arena, entered by init
	phase:       Phase,
	_pad:        [3]u8,
	match_tick:  sim.Game_Time, // the tick the current match started (0: lobby)
	over_tick:   sim.Game_Time, // the tick it ended (0: not over)
	wave:        u32, // 0-based wave of the current match
	best_wave:   u32, // the most waves survived: the Setup's record, raised when a match ends past it
	tuning:      Tuning, // the match's pace: a preset (init), lowered by the bench
	players:     sim.Players(Character, Profile, Input, PLAYERS),
	items:       [MAX_ITEMS]Item, // the level's items by index (World.items: as many as it holds)
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
	respawn:          sim.Timer, // a dead player respawns when it runs out (PLAYER_RESPAWN_TICKS)
	dash:             sim.Timer, // dashing while it runs (DASH_TICKS)
	dash_cooldown:    sim.Timer, // no dash while it runs (DASH_COOLDOWN_TICKS)
	fire_cooldown:    sim.Timer, // no shot while it runs (fire_interval)
	fire_interval:    i32,
	damage_bonus:     i32,
	speed:            f32,
	level:            i32,
	xp:               i32,
	pending_levelups: i32,
	alive:            bool, // has a body (present, not dead)
	role:             Role, // the Profile's on the tick they joined or came back
	warp:             u8, // bumped by each spawn: the view (it lives while the player is dead) snaps to the new body
	_pad:             u8,
}

Item_Kind :: enum u8 {
	Crate,
	Barrel,
}

// A crate or barrel the level placed (its kind and spot: World.items); the body's index tag is the item's.
Item :: struct {
	body:         physics.Body_Ref,
	hp:           i32, // barrels
	respawn_tick: sim.Game_Time, // barrels: the tick a destroyed one comes back (0: none pending)
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
	spawn_tick:       sim.Game_Time, // for the view (age-based effects)
	hit_tick:         sim.Game_Time, // the last tick it took damage (0: never), for hit flashes
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
	spawn_tick: sim.Game_Time,
}
