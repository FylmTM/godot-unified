// Survivor-lite (spec/GAME.md): constants, the pointer-free state block and its tables.
package game

import "core:fmt"

DT: f32 : 0.016666668 // bits 0x3C888889 (checked in check_literals)
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
BUTTON_ABSENT :: u8(1 << 7)

// One player's input for one tick (4 bytes on the wire and in the log).
Input :: struct {
	move_x:  i8,
	move_z:  i8,
	buttons: u8,
	choice:  u8,
}

ABSENT_INPUT :: Input {
	buttons = BUTTON_ABSENT,
}

Inputs :: [MAX_PLAYERS]Input

// Angle table for k·45° (GAME.md: use the table, not trig).
RING_C := [8]f32{1, 0.70710677, 0, -0.70710677, -1, -0.70710677, 0, 0.70710677}
RING_S := [8]f32{0, 0.70710677, 1, 0.70710677, 0, -0.70710677, -1, -0.70710677}

// A physics body as stored in the block: Box3D's body index and generation, without the world
// index (that differs between the worlds of one process and between machines). index1 == 0: none.
Body_Ref :: struct {
	index1:     i32,
	generation: u16,
	_pad:       u16,
}

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
	active:           bool, // joined the game (has had a non-absent input, or active at start)
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
	using slot:       Slot,
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
	using slot: Slot,
	pos:        [3]f32,
	vel:        [3]f32,
	life:       i32,
	damage:     i32,
}

Gem :: struct {
	using slot: Slot,
	pos:        [2]f32,
	value:      i32,
}

// Common header of pooled entities: stable index, generation for handles, free-list link.
Slot :: struct {
	next_free:  i32,
	generation: u16,
	alive:      bool,
	_pad:       u8,
}

// Generational handle into a pool. Like Box3D's ids it stores index + 1, so the zero value
// `Handle{}` is the null handle and never matches a slot (not even slot 0 at generation 0).
Handle :: struct {
	index1:     u16, // slot index + 1; 0: null
	generation: u16,
}

// Fixed-capacity pool with a free list: indices are stable (no swap-remove, GAME.md §9), freed
// slots are reused LIFO, iteration is in index order over [0, high_water).
Pool :: struct($T: typeid, $N: int) {
	items:      [N]T,
	free_head:  i32,
	high_water: i32,
	count:      i32,
	_pad:       i32,
}

// The whole simulation state: one pointer-free block (checked at startup by pod.check in sim.create).
State :: struct {
	tick:        u32,
	rng:         u32,
	seed:        u32,
	enemy_cap:   u32, // 1200; bench lowers it to hold a fixed population
	kills:       u32,
	explosions:  u32,
	players:     [MAX_PLAYERS]Player,
	items:       [ITEM_COUNT]Item,
	enemies:     Pool(Enemy, MAX_ENEMIES),
	projectiles: Pool(Projectile, MAX_PROJECTILES),
	gems:        Pool(Gem, MAX_GEMS),
}

pool_init :: proc(p: ^Pool($T, $N)) {
	p.free_head = -1
}

// Allocates a slot (zeroed except for its header); returns -1 when the pool is full.
pool_alloc :: proc(p: ^Pool($T, $N)) -> i32 {
	idx: i32
	if p.free_head >= 0 {
		idx = p.free_head
		p.free_head = p.items[idx].next_free
	} else if p.high_water < i32(N) {
		idx = p.high_water
		p.high_water += 1
	} else {
		return -1
	}
	gen := p.items[idx].generation
	p.items[idx] = {}
	p.items[idx].generation = gen
	p.items[idx].alive = true
	p.items[idx].next_free = -1
	p.count += 1
	return idx
}

pool_free :: proc(p: ^Pool($T, $N), idx: i32) {
	it := &p.items[idx]
	assert(it.alive)
	gen := it.generation + 1
	it^ = {}
	it.generation = gen
	it.next_free = p.free_head
	p.free_head = idx
	p.count -= 1
}

#assert(MAX_ENEMIES < 0xFFFF && MAX_PROJECTILES < 0xFFFF && MAX_GEMS < 0xFFFF) // index + 1 fits in u16

pool_handle :: proc(p: ^Pool($T, $N), idx: i32) -> Handle {
	assert(idx >= 0 && idx < i32(N) && p.items[idx].alive)
	return {u16(idx + 1), p.items[idx].generation}
}

// The slot `h` refers to, or nil for the null handle, an out-of-range index or a stale handle
// (the slot was freed, or freed and reused).
pool_get :: proc(p: ^Pool($T, $N), h: Handle) -> ^T {
	if h.index1 == 0 || int(h.index1) > N {
		return nil
	}
	it := &p.items[h.index1 - 1]
	if !it.alive || it.generation != h.generation {
		return nil
	}
	return it
}

// xorshift32 (GAME.md: the state block's RNG; seed 0 -> 1).
xorshift32 :: proc(x: ^u32) -> u32 {
	v := x^
	v ~= v << 13
	v ~= v >> 17
	v ~= v << 5
	x^ = v
	return v
}

rng_next :: proc(s: ^State) -> u32 {
	return xorshift32(&s.rng)
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
