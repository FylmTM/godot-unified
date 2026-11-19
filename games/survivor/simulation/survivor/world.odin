package survivor

import "unified:dmath"
import "unified:level"
import "unified:physics"
import "unified:sim"

// Shape categories (filter bits, reported by every query). The level tags its walls and pillars (their bodies'
// `unified_category` metadata); the rest of its geometry is CAT_STATIC. An item's body is tagged with its index.
CAT_STATIC :: u64(1 << 0)
CAT_CRATE :: u64(1 << 1)
CAT_BARREL :: u64(1 << 2)
CAT_PLAYER :: u64(1 << 3)
CAT_PILLAR :: u64(1 << 4)
CAT_WALL :: u64(1 << 5)
CAT_LEVEL :: CAT_STATIC | CAT_PILLAR | CAT_WALL

MAX_PILLARS :: 16

// The world outside the block: the physics world, what the sim reads of the level, and per-tick scratch.
World :: struct {
	phys:        ^physics.World,
	// The level's pillars on the ground plane (x, z), which enemies are pushed out of, and how far the walls' inner
	// faces are from the centre, which enemies stay inside.
	pillars:     sim.List(Box2, MAX_PILLARS),
	arena_inner: f32,
	// Where the level puts things: each slot's start spot (its `spawn` markers, in scene order) and each item (its
	// `item` markers, in scene order: the item's index, as in State.items).
	spawns:      [PLAYERS][3]f32,
	items:       sim.List(Item_Spot, MAX_ITEMS),
	scratch:     Scratch,
}

// A box on the ground plane: its centre and half size (x, z).
Box2 :: struct {
	center: [2]f32,
	half:   [2]f32,
}

// An item's place in the level, where its body is created (at the start, at a reset, when a barrel comes back):
// resting on the floor.
Item_Spot :: struct {
	pos:  [3]f32,
	rot:  [4]f32,
	kind: Item_Kind,
}

// Per-tick scratch (rebuilt every tick, never snapshotted): the enemy grid and the items' positions.
Scratch :: struct {
	grid:    Enemy_Grid,
	new_vel: [MAX_ENEMIES][2]f32,
	items:   [MAX_ITEMS][2]f32, // each alive item's position (x, z) this tick
}

// What the keyed rolls are for (sim.roll_below, sim.roll_f32).
Roll :: enum u8 {
	Spawn_Direction,
	Spawn_Jitter_X,
	Spawn_Jitter_Z,
	Spawn_Kind,
	Upgrade_Offer,
}

// The physics world with the level's static geometry (src/level/README.md); the pillars and walls the enemies keep to;
// the start spots and the items from the level's markers.
world_create :: proc(seed: u64, levels: []sim.Level_File, _: sim.No_Setup) -> ^World {
	world := new(World)
	problem: string
	world.phys, problem = physics.create_with_levels(
		{tick_hz = TICK_HZ, workers = PHYSICS_WORKERS},
		levels,
		CAT_STATIC,
	)
	assert(problem == "", problem)
	arena := physics.level_data(world.phys, Level_Id.Arena)
	world.arena_inner = ARENA_HALF
	for &body in arena.bodies {
		if body.category != CAT_PILLAR && body.category != CAT_WALL do continue
		assert(len(body.shapes) == 1 && body.shapes[0].kind == .Box, "survivor: a pillar or wall is one box")
		box := Box2{body.pos.xz + body.shapes[0].pos.xz, body.shapes[0].half.xz}
		if body.category == CAT_PILLAR {
			added := sim.append(&world.pillars, box)
			assert(added, "survivor: too many pillars")
		} else if box.half.x > box.half.y { 	// along x: a north or south wall
			world.arena_inner = dmath.min(world.arena_inner, abs(box.center.y) - box.half.y)
		} else {
			world.arena_inner = dmath.min(world.arena_inner, abs(box.center.x) - box.half.x)
		}
	}
	spawn_count := 0
	for &marker in arena.markers {
		switch marker.kind {
		case "spawn":
			assert(spawn_count < PLAYERS, "survivor: more spawn markers than slots")
			world.spawns[spawn_count] = marker.pos
			spawn_count += 1
		case "item":
			// prop_view.gd's export_enum: the names, lowercased
			kind, known := level.prop_enum(&marker, "kind", Item_Kind.Crate)
			assert(known, "survivor: an item marker's kind is no Item_Kind")
			added := sim.append(&world.items, Item_Spot{marker.pos, marker.rot, kind})
			assert(added, "survivor: more item markers than MAX_ITEMS")
		}
	}
	assert(spawn_count == PLAYERS, "survivor: the level needs a spawn marker per slot")
	return world
}

// Frees what world_create made: the physics world (the level with it) and the World itself.
world_destroy :: proc(world: ^World) {
	physics.destroy(world.phys)
	free(world)
}

// The tick-0 state: the arena's static geometry, the lobby, the `play` tuning, the level's items with their bodies; players join when they are
// first present (update_players).
init :: proc(t: ^Tick) {
	physics.level_change(t, t.world.phys, Level_Id.Arena)
	t.state.phase = .Lobby
	t.state.tuning = TUNINGS[.Play]
	for i in 0 ..< int(t.world.items.count) {
		item_reset(t.state, t.world, i)
	}
}

// GAME_STRESS's tick 0: init with the `stress` tuning.
init_stress :: proc(t: ^Tick) {
	init(t)
	t.state.tuning = TUNINGS[.Stress]
}

// Puts item i back as the world starts it: alive, full HP for a barrel, with a new body at its spot, tagged with i.
// The caller destroys any old body first.
item_reset :: proc(state: ^State, world: ^World, i: int) {
	item := &state.items[i]
	spot := &sim.slice(&world.items)[i]
	item.alive = true
	item.hp = spot.kind == .Barrel ? BARREL_HP : 0
	item.respawn_tick = 0
	body_def := physics.body_def(.Dynamic, spot.pos, spot.rot)
	if spot.kind == .Barrel {
		shape_def := physics.shape_def(CAT_BARREL)
		shape_def.density = 1
		segment := physics.Capsule{{0, -BARREL_HALF_HEIGHT, 0}, {0, BARREL_HALF_HEIGHT, 0}, BARREL_RADIUS}
		item.body, _ = physics.create_capsule(world.phys, body_def, shape_def, segment, u64(i))
	} else {
		shape_def := physics.shape_def(CAT_CRATE)
		shape_def.density = 1
		item.body, _ = physics.create_box(world.phys, body_def, shape_def, CRATE_HALF, u64(i))
	}
}

// Fresh progress (no body, not alive): a new player's, and everyone's at a reset. The body must be gone.
character_reset :: proc(character: ^Character) {
	character^ = {
		fire_interval = FIRE_INTERVAL_TICKS,
		level         = 1,
		speed         = PLAYER_SPEED,
	}
}

// A body at the start spot of `slot` (the level's spawn marker), with full HP.
character_spawn :: proc(world: ^World, character: ^Character, slot: int) {
	character.alive = true
	character.hp = PLAYER_HP
	character.respawn = 0
	character.pos = world.spawns[slot]
	body_def := physics.body_def(.Dynamic, world.spawns[slot])
	body_def.motion_locks = {
		angular_x = true,
		angular_y = true,
		angular_z = true,
	}
	body_def.enable_sleep = false
	segment := physics.Capsule{{0, -PLAYER_RADIUS, 0}, {0, PLAYER_RADIUS, 0}, PLAYER_RADIUS}
	character.body, _ = physics.create_capsule(world.phys, body_def, physics.shape_def(CAT_PLAYER), segment)
}

// The player left: the body goes (an absent player owns nothing outside the block), the progress stays for their
// return.
character_leave :: proc(world: ^World, character: ^Character) {
	physics.destroy_body(world.phys, &character.body)
	character.alive = false
	character.respawn = 0
	character.dash_ticks = 0
}

// After the physics step: the players' positions for the next tick.
read_back :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character in sim.next(&players) {
		if character.alive {
			character.pos = physics.body_position(t.world.phys, character.body)
		}
	}
}
