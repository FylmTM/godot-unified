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
	phys:         ^physics.World,
	level:        level.Level,
	// The level's pillars on the ground plane (x, z), which enemies are pushed out of, and how far the walls' inner
	// faces are from the centre, which enemies stay inside.
	pillars:      [MAX_PILLARS]Box2,
	pillar_count: int,
	arena_inner:  f32,
	scratch:      Scratch,
}

// A box on the ground plane: its centre and half size (x, z).
Box2 :: struct {
	center: [2]f32,
	half:   [2]f32,
}

// Per-tick scratch (rebuilt every tick, never snapshotted): the enemy grid and the items' positions.
Scratch :: struct {
	grid:    Grid,
	new_vel: [MAX_ENEMIES][2]f32,
	items:   [ITEM_COUNT][2]f32, // each alive item's position (x, z) this tick
}

// What the keyed rolls are for (sim.roll_below).
Roll :: enum u8 {
	Spawn_Direction,
	Spawn_Jitter,
	Spawn_Kind,
}

// Start spots by slot, inside the start circle.
@(rodata)
PLAYER_START := [PLAYERS][3]f32{{1.5, 1, 1.5}, {-1.5, 1, 1.5}, {1.5, 1, -1.5}, {-1.5, 1, -1.5}}

// The physics world with the level's static geometry (src/level/SPEC.md); the pillars and walls the enemies keep to.
world_create :: proc(seed: u64, content: []u8) -> ^World {
	world := new(World)
	loaded, ok := level.load(content)
	assert(ok, "survivor: the level file is missing or not a level (src/level/SPEC.md)")
	world.level = loaded
	world.phys = physics.create({tick_hz = TICK_HZ, workers = PHYSICS_WORKERS})
	problem := physics.create_static(world.phys, &world.level, CAT_STATIC)
	assert(problem == "", problem)
	world.arena_inner = ARENA_HALF
	for &body in world.level.bodies {
		if body.category != CAT_PILLAR && body.category != CAT_WALL do continue
		assert(len(body.shapes) == 1 && body.shapes[0].kind == .Box, "survivor: a pillar or wall is one box")
		box := Box2{body.pos.xz + body.shapes[0].pos.xz, body.shapes[0].half.xz}
		if body.category == CAT_PILLAR {
			assert(world.pillar_count < MAX_PILLARS, "survivor: too many pillars")
			world.pillars[world.pillar_count] = box
			world.pillar_count += 1
		} else if box.half.x > box.half.y { 	// along x: a north or south wall
			world.arena_inner = dmath.min(world.arena_inner, abs(box.center.y) - box.half.y)
		} else {
			world.arena_inner = dmath.min(world.arena_inner, abs(box.center.x) - box.half.x)
		}
	}
	return world
}

// Frees what world_create made: the physics world, the level and the World itself.
world_destroy :: proc(world: ^World) {
	physics.destroy(world.phys)
	level.destroy(&world.level)
	free(world)
}

// The tick-0 state: the lobby, the `play` tuning, items with their bodies; players join when they are first present
// (update_players).
init :: proc(t: ^Tick) {
	t.state.phase = .Lobby
	t.state.circle_radius = START_RADIUS
	t.state.tuning = TUNINGS[.Play]
	for i in 0 ..< ITEM_COUNT {
		item_reset(t.state, t.world, i)
	}
}

// GAME_STRESS's tick 0: init with the `stress` tuning.
init_stress :: proc(t: ^Tick) {
	init(t)
	t.state.tuning = TUNINGS[.Stress]
}

// The spawn spot of item i on the 5×8 grid: the body's centre. The extension and the tests read it too.
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

// Whether item i is a barrel or a crate (every fifth item from index 2 is a barrel).
item_kind :: proc(i: int) -> Item_Kind {
	return i % 5 == 2 ? .Barrel : .Crate
}

// Puts item i back as the world starts it: alive, full HP for a barrel, with a new body at its grid spot. The caller
// destroys any old body first.
item_reset :: proc(state: ^State, world: ^World, i: int) {
	item := &state.items[i]
	item.kind = item_kind(i)
	item.alive = true
	item.hp = item.kind == .Barrel ? BARREL_HP : 0
	item.respawn_tick = 0
	item.body = create_item_body(world, i)
}

// Creates the body of item i (a crate or a barrel) at its grid spot, tagged with i.
create_item_body :: proc(world: ^World, i: int) -> physics.Body_Ref {
	body_def := physics.body_def(.Dynamic, item_position(i))
	if item_kind(i) == .Barrel {
		shape_def := physics.shape_def(CAT_BARREL)
		shape_def.density = 1
		segment := physics.Capsule{{0, -BARREL_HALF_HEIGHT, 0}, {0, BARREL_HALF_HEIGHT, 0}, BARREL_RADIUS}
		ref, _ := physics.create_capsule(world.phys, body_def, shape_def, segment, u64(i))
		return ref
	}
	shape_def := physics.shape_def(CAT_CRATE)
	shape_def.density = 1
	ref, _ := physics.create_box(world.phys, body_def, shape_def, CRATE_HALF, u64(i))
	return ref
}

// Fresh progress (no body, not alive): a new player's, and everyone's at a reset. The body must be gone.
character_reset :: proc(character: ^Character) {
	character^ = {
		fire_interval = FIRE_INTERVAL_TICKS,
		level         = 1,
		speed         = PLAYER_SPEED,
	}
}

// A body at the start spot of `slot`, with full HP.
character_spawn :: proc(world: ^World, character: ^Character, slot: int) {
	character.alive = true
	character.hp = PLAYER_HP
	character.respawn = 0
	character.pos = PLAYER_START[slot]
	body_def := physics.body_def(.Dynamic, PLAYER_START[slot])
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
