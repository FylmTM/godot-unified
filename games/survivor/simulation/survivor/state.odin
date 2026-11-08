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

PLAYER_HP :: 100
RESPAWN_TICKS :: 180
BARREL_HP :: 30
BARREL_RESPAWN_TICKS :: 600

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
	pos:   [2]f32,
	value: i32,
}

// The whole simulation state: one pointer-free block (checked by sim.create).
State :: struct {
	rng:         sim.Rng,
	seed:        u32,
	enemy_cap:   u32, // 1200; bench lowers it to hold a fixed population
	kills:       u32,
	explosions:  u32,
	players:     [MAX_PLAYERS]Player,
	items:       [ITEM_COUNT]Item,
	enemies:     sim.Table(Enemy, MAX_ENEMIES),
	projectiles: sim.Table(Projectile, MAX_PROJECTILES),
	gems:        sim.Table(Gem, MAX_GEMS),
}

rng_next :: proc(s: ^State) -> u32 {
	return sim.rng_next(&s.rng)
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
		`"enemies":%d,"projectiles":%d,"gems":%d,"kills":%d,"explosions":%d,"players_alive":%d,"levels":%v`,
		s.enemies.count,
		s.projectiles.count,
		s.gems.count,
		s.kills,
		s.explosions,
		alive,
		levels,
	)
}
