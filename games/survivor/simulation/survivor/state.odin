// Survivor (spec/GAME.md): constants, input, the pointer-free state block and its tables.
package survivor

import "core:fmt"

import "unified:physics"
import "unified:sim"

TICK_HZ :: 64
DT: f32 : 1.0 / TICK_HZ // exact
SUBSTEPS :: 4
MAX_PLAYERS :: 4
MAX_ENEMIES :: 1200
MAX_PROJECTILES :: 512
MAX_GEMS :: 1024
ITEM_COUNT :: 40

// Time constants are written in seconds and converted to ticks at compile time; a value that is not
// a whole number of ticks does not compile.
PLAYER_RESPAWN_S :: 3.0
BARREL_RESPAWN_S :: 10.0
DASH_S :: 0.125
DASH_COOLDOWN_S :: 1.5
CONTACT_COOLDOWN_S :: 0.5
FIRE_INTERVAL_S :: 0.3125
FIRE_INTERVAL_MIN_S :: 0.09375
FIRE_LEVELUP_S :: 0.03125 // fire interval reduction per "fire rate" level-up
SPAWN_EVERY_S :: 0.3125
WAVE_S :: 10.0
PROJECTILE_LIFE_S :: 1.0
CLIMB_CHECK_S :: 0.125
OVER_HOLD_S :: 5.0

RESPAWN_TICKS :: i32(PLAYER_RESPAWN_S * TICK_HZ)
BARREL_RESPAWN_TICKS :: u32(BARREL_RESPAWN_S * TICK_HZ)
DASH_TICKS :: i32(DASH_S * TICK_HZ)
DASH_COOLDOWN_TICKS :: i32(DASH_COOLDOWN_S * TICK_HZ)
CONTACT_COOLDOWN_TICKS :: u16(CONTACT_COOLDOWN_S * TICK_HZ)
FIRE_INTERVAL_TICKS :: i32(FIRE_INTERVAL_S * TICK_HZ)
FIRE_INTERVAL_MIN_TICKS :: i32(FIRE_INTERVAL_MIN_S * TICK_HZ)
FIRE_LEVELUP_TICKS :: i32(FIRE_LEVELUP_S * TICK_HZ)
SPAWN_EVERY_TICKS :: u32(SPAWN_EVERY_S * TICK_HZ)
WAVE_TICKS :: u32(WAVE_S * TICK_HZ)
PROJECTILE_LIFE_TICKS :: i32(PROJECTILE_LIFE_S * TICK_HZ)
CLIMB_CHECK_TICKS :: u32(CLIMB_CHECK_S * TICK_HZ)
OVER_HOLD_TICKS :: u32(OVER_HOLD_S * TICK_HZ)

PLAYER_HP :: 100
PLAYER_SPEED :: 6.0
BARREL_HP :: 30
START_RADIUS :: 3.5 // the lobby's start circle at the arena centre (m)

BUTTON_DASH :: u8(1 << 0)

// One player's input for one tick (4 bytes on the wire and in the log). Presence (joined or not)
// comes from the relay in sim.Inputs.present, not from the input.
Input :: struct {
	move_x:  i8,
	move_z:  i8,
	buttons: u8,
	choice:  u8,
}

Inputs :: sim.Inputs(Input, MAX_PLAYERS)

// Angle table for k·45° (GAME.md: use the table, not trig).
RING_C := [8]f32{1, 0.70710677, 0, -0.70710677, -1, -0.70710677, 0, 0.70710677}
RING_S := [8]f32{0, 0.70710677, 1, 0.70710677, 0, -0.70710677, -1, -0.70710677}

Body_Ref :: physics.Body_Ref

Player :: struct {
	body:             Body_Ref,
	pos:              [3]f32, // read back after each physics step
	hp:               i32,
	respawn:          i32,
	dash_ticks:       i32,
	dash_cooldown:    i32,
	fire_cooldown:    i32,
	fire_interval:    i32,
	damage_bonus:     i32,
	speed:            f32,
	level:            i32,
	xp:               i32,
	pending_levelups: i32,
	active:           bool, // present (joined) in the game
	alive:            bool,
	prev_buttons:     u8,
	_pad:             u8,
}

Item_Kind :: enum u8 {
	Crate,
	Barrel,
}

// Crates and barrels, one per grid spot (GAME.md "World").
Item :: struct {
	body:         Body_Ref,
	hp:           i32,
	respawn_tick: u32, // barrels: tick at which a destroyed barrel comes back (0: none pending)
	kind:         Item_Kind,
	alive:        bool,
	_pad:         u16,
}

Enemy_Kind :: enum u8 {
	Grunt,
	Runner,
	Brute,
}

Enemy :: struct {
	spawn_tick:       u32, // for the view (age-based effects)
	hit_tick:         u32, // last tick it took damage (0: never), for hit flashes
	pos:              [2]f32, // x, z
	vel:              [2]f32,
	hp:               i32,
	speed:            f32,
	radius:           f32,
	damage:           i32,
	contact_cooldown: u16,
	kind:             Enemy_Kind,
	climbing:         bool,
}

Projectile :: struct {
	pos:    [3]f32,
	vel:    [3]f32,
	life:   i32,
	damage: i32,
}

Gem :: struct {
	pos:        [2]f32,
	value:      i32,
	spawn_tick: u32,
}

// lobby: present players gather in the start circle, no enemies; the match starts on the tick a
// player's centre leaves the circle. match: waves. over: every present player died at once; after
// OVER_HOLD_S the world resets and the lobby begins again.
Phase :: enum u8 {
	Lobby,
	Match,
	Over,
}

// The whole simulation state: one pointer-free block (checked by sim.create).
State :: struct {
	rng:           sim.Rng,
	seed:          u32,
	enemy_cap:     u32, // 1200; bench lowers it to hold a fixed population
	kills:         u32,
	explosions:    u32,
	match_tick:    u32, // the tick the current match started (0: lobby)
	over_tick:     u32, // the tick it ended (0: not over)
	wave:          u32, // 0-based wave of the current match
	matches:       u32, // matches started since the session began
	circle_radius: f32, // the start circle while in the lobby, 0 otherwise
	phase:         Phase,
	endless:       bool, // never leave the match (bench: hold a fixed population)
	_pad:          [2]u8,
	players:       [MAX_PLAYERS]Player,
	items:         [ITEM_COUNT]Item,
	enemies:       sim.Table(Enemy, MAX_ENEMIES),
	projectiles:   sim.Table(Projectile, MAX_PROJECTILES),
	gems:          sim.Table(Gem, MAX_GEMS),
}

// A JSON fragment describing the state (for the CLI output; temp-allocated).
summary :: proc(s: ^State) -> string {
	levels: [MAX_PLAYERS]i32
	alive := 0
	for p in 0 ..< MAX_PLAYERS {
		levels[p] = s.players[p].level
		if s.players[p].alive {
			alive += 1
		}
	}
	return fmt.tprintf(
		`"phase":"%v","matches":%d,"wave":%d,"enemies":%d,"projectiles":%d,"gems":%d,"kills":%d,"explosions":%d,"players_alive":%d,"levels":%v`,
		s.phase,
		s.matches,
		s.wave,
		s.enemies.count,
		s.projectiles.count,
		s.gems.count,
		s.kills,
		s.explosions,
		alive,
		levels,
	)
}
