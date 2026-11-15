// The world outside the block: the physics world (static geometry, then items and players, in
// games/survivor/SPEC.md creation order) and per-tick scratch; plus body creation, the events and the game
// descriptor.
package survivor

import "unified:b3"
import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Shape categories (filter bits) and user material ids (reported by ray casts).
CAT_STATIC :: u64(1 << 0)
CAT_CRATE :: u64(1 << 1)
CAT_BARREL :: u64(1 << 2)
CAT_PLAYER :: u64(1 << 3)
MAT_ITEM_BASE :: u64(1000) // item i -> 1000 + i

World :: struct {
	phys:    ^physics.World,
	scratch: Scratch,
	extras:  [1]sim.Extra,
}

Game :: sim.Game(State, Input, World, PLAYERS)
Sim :: sim.Sim(State, Input, World, PLAYERS)
Tick :: sim.Tick(State, Input, World, PLAYERS)

// Events (for the view; name = type name lowercased). Positions are in metres (sim units), on the ground
// (y = 0) for enemies and gems, the body's centre for players and barrels.
Player_Died :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

Player_Respawned :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

Enemy_Died :: struct {
	enemy:      sim.Handle(Enemy),
	position:   sim.Position,
	enemy_kind: Enemy_Kind,
	_pad:       [3]u8,
}

// Items are a fixed array, not a table: the subject is the item's view key, `entity` = item index + 1.
Barrel_Exploded :: struct {
	entity:   u64,
	position: sim.Position,
	_pad:     u32,
}

Gem_Collected :: struct {
	gem:      sim.Handle(Gem),
	position: sim.Position,
	xp:       i32, // the gem's value
	player:   u8, // who collected it
	_pad:     [3]u8,
}

Level_Up :: struct {
	position: sim.Position,
	level:    i32, // the new level
	player:   u8,
	_pad:     [3]u8,
}

// The match starts when `player` leaves the start circle.
Match_Started :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

Match_Over :: struct {
	duration_s: f32, // the match's length in seconds
}

Player_Joined :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

Player_Left :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

Event :: union {
	Player_Died,
	Player_Respawned,
	Enemy_Died,
	Barrel_Exploded,
	Gem_Collected,
	Level_Up,
	Match_Started,
	Match_Over,
	Player_Joined,
	Player_Left,
}

// The simulation's version (sim.Game.version, part of the netcode's compat): bump it when a rule or
// constant changes what a tick computes without changing the State or Input layout.
SIM_VERSION :: "2"

// The game as played (`play` tuning).
@(rodata)
GAME := Game {
	name = "survivor",
	version = SIM_VERSION,
	tick_hz = TICK_HZ,
	world_create = world_create,
	world_destroy = world_destroy,
	extras = proc(world: ^World) -> []sim.Extra {return world.extras[:]},
	init = init,
	tick = tick,
	events = Event,
	commands = Command,
}

// The same game with the `stress` tuning: what the headless binary, the end-to-end suite and the bench run.
@(rodata)
GAME_STRESS := Game {
	name = "survivor-stress",
	version = SIM_VERSION,
	tick_hz = TICK_HZ,
	world_create = world_create,
	world_destroy = world_destroy,
	extras = proc(world: ^World) -> []sim.Extra {return world.extras[:]},
	init = proc(state: ^State, world: ^World, seed: u64) {
		init(state, world, seed)
		set_tuning(state, .Stress)
	},
	tick = tick,
	events = Event,
	commands = Command,
}

// Start spots, inside the start circle.
@(rodata)
PLAYER_START := [PLAYERS][3]f32{{1.5, 1, 1.5}, {-1.5, 1, 1.5}, {1.5, 1, -1.5}, {-1.5, 1, -1.5}}

item_position :: proc(i: int) -> [3]f32 {
	// The two grid spots inside the start circle move to free lanes north and south.
	switch i {
	case 19:
		return {-2, 1, 12}
	case 20:
		return {2, 1, -12}
	}
	return {f32(i % 8) * 4 - 14, 1, f32(i / 8) * 4 - 8}
}

item_kind :: proc(i: int) -> Item_Kind {
	return i % 5 == 2 ? .Barrel : .Crate
}

body_id :: proc(world: ^World, ref: Body_Ref) -> b3.Body_Id {
	return physics.body_id(world.phys, ref)
}

@(private)
add_static_box :: proc(world: ^World, pos: [3]f32, half: [3]f32) {
	body_def := b3.default_body_def()
	body_def.position = pos
	body := physics.body_id(world.phys, physics.create_body(world.phys, &body_def))
	shape_def := b3.default_shape_def()
	shape_def.filter.category_bits = CAT_STATIC
	hull := b3.make_box_hull(half.x, half.y, half.z)
	b3.create_hull_shape(body, &shape_def, &hull.base)
}

// Creates the body of item i (a crate or a barrel) at its grid spot.
create_item_body :: proc(world: ^World, i: int) -> Body_Ref {
	body_def := b3.default_body_def()
	body_def.type = .Dynamic_Body
	body_def.position = item_position(i)
	ref := physics.create_body(world.phys, &body_def)
	body := physics.body_id(world.phys, ref)
	shape_def := b3.default_shape_def()
	shape_def.density = 1
	shape_def.base_material.user_material_id = MAT_ITEM_BASE + u64(i)
	if item_kind(i) == .Barrel {
		shape_def.filter.category_bits = CAT_BARREL
		capsule := b3.Capsule{{0, -0.3, 0}, {0, 0.3, 0}, 0.4}
		b3.create_capsule_shape(body, &shape_def, &capsule)
	} else {
		shape_def.filter.category_bits = CAT_CRATE
		hull := b3.make_box_hull(0.5, 0.5, 0.5)
		b3.create_hull_shape(body, &shape_def, &hull.base)
	}
	return ref
}

create_player_body :: proc(world: ^World, player: int) -> Body_Ref {
	body_def := b3.default_body_def()
	body_def.type = .Dynamic_Body
	body_def.position = PLAYER_START[player]
	body_def.motion_locks.angular_x = true
	body_def.motion_locks.angular_y = true
	body_def.motion_locks.angular_z = true
	body_def.enable_sleep = false
	ref := physics.create_body(world.phys, &body_def)
	body := physics.body_id(world.phys, ref)
	shape_def := b3.default_shape_def()
	shape_def.filter.category_bits = CAT_PLAYER
	capsule := b3.Capsule{{0, -0.45, 0}, {0, 0.45, 0}, 0.45}
	b3.create_capsule_shape(body, &shape_def, &capsule)
	return ref
}

destroy_body :: proc(world: ^World, ref: ^Body_Ref) {
	physics.destroy_body(world.phys, ref)
}

// The physics world with its static geometry (games/survivor/SPEC.md creation order: ground, walls, pillars).
world_create :: proc(seed: u64, _: []u8) -> ^World {
	world := new(World)
	world.phys = physics.create({workers = PHYSICS_WORKERS})
	world.extras[0] = physics.extra(world.phys, State)
	add_static_box(world, {0, -0.5, 0}, {ARENA_HALF, 0.5, ARENA_HALF}) // ground
	add_static_box(world, {30.5, 1.5, 0}, {0.5, 1.5, 31}) // walls: inner faces at x, z = ±30
	add_static_box(world, {-30.5, 1.5, 0}, {0.5, 1.5, 31})
	add_static_box(world, {0, 1.5, 30.5}, {31, 1.5, 0.5})
	add_static_box(world, {0, 1.5, -30.5}, {31, 1.5, 0.5})
	for k in 0 ..< 8 {
		add_static_box(world, {14 * dmath.DIR8_C[k], 1.5, 14 * dmath.DIR8_S[k]}, {1, 1.5, 1})
	}
	return world
}

world_destroy :: proc(world: ^World) {
	physics.destroy(world.phys)
	free(world)
}

// The tick-0 state: the lobby, items with their bodies; players join when they are first present.
init :: proc(state: ^State, world: ^World, seed: u64) {
	state.seed = u32(seed)
	state.rng = sim.rng_seed(seed)
	state.enemy_cap = MAX_ENEMIES
	state.phase = .Lobby
	state.circle_radius = START_RADIUS
	set_tuning(state, .Play)
	for i in 0 ..< ITEM_COUNT {
		item_reset(state, world, i)
	}
	for player in 0 ..< PLAYERS {
		player_reset_stats(state, player)
	}
}

item_reset :: proc(state: ^State, world: ^World, i: int) {
	item := &state.items[i]
	item.kind = item_kind(i)
	item.alive = true
	item.hp = item.kind == .Barrel ? BARREL_HP : 0
	item.respawn_tick = 0
	item.body = create_item_body(world, i)
}

// Fresh progress for `player` (no body, not alive; `active` is kept).
player_reset_stats :: proc(state: ^State, player: int) {
	character := &state.players[player]
	active := character.active
	character^ = {
		fire_interval = FIRE_INTERVAL_TICKS,
		level         = 1,
		speed         = PLAYER_SPEED,
		pos           = PLAYER_START[player],
		active        = active,
	}
}

player_activate :: proc(state: ^State, world: ^World, player: int) {
	state.players[player].active = true
	player_spawn(state, world, player)
}

player_spawn :: proc(state: ^State, world: ^World, player: int) {
	character := &state.players[player]
	character.alive = true
	character.hp = PLAYER_HP
	character.respawn = 0
	character.pos = PLAYER_START[player]
	character.body = create_player_body(world, player)
}

// The player leaves: body gone, progress reset (a rejoin starts fresh).
player_deactivate :: proc(state: ^State, world: ^World, player: int) {
	destroy_body(world, &state.players[player].body)
	state.players[player].active = false
	player_reset_stats(state, player)
}
