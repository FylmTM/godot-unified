package drift

import "unified:dmath"
import "unified:level"
import "unified:physics"
import "unified:sim"

// Shape categories (filter bits, reported by every query). A rock's body is tagged with its handle's key.
CAT_STATIC :: u64(1 << 0)
CAT_SHIP :: u64(1 << 1)
CAT_ROCK :: u64(1 << 2)
CAT_STATION :: u64(1 << 3)
CAT_BULLET :: u64(1 << 4) // rays only

// The plane's up (its y points down): a ship's heading when it spawns.
UP :: [2]f32{0, -1}

// The station's hexagon at radius 1: corners at k × 60°, cos and sin as exact constants.
@(rodata)
HEXAGON := [6][2]f32{{1, 0}, {0.5, 0.8660254}, {-0.5, 0.8660254}, {-1, 0}, {-0.5, -0.8660254}, {0.5, -0.8660254}}

// The world outside the block: the physics world and what the sim reads of the level's markers.
World :: struct {
	phys:     ^physics.World,
	spawns:   [PLAYERS][2]f32, // by slot
	station:  [2]f32,
	gates:    sim.List(Gate_Def, MAX_GATES),
	spawners: sim.List(Spawner_Def, MAX_SPAWNERS),
}

Gate_Def :: struct {
	pos:  [2]f32,
	pair: int, // the gate it warps to (-1: none)
}

// A rock_spawn marker: where a wave's rocks come from, and the way they drift.
Spawner_Def :: struct {
	pos: [2]f32,
	dir: [2]f32, // unit
}

// What the keyed rolls are for (sim.roll_below_at, sim.roll_f32_at).
Roll :: enum u8 {
	Rock_Turn,
	Rock_Spin,
	Rock_Variant,
}

// The physics world with the level's static geometry (src/level/README.md, 2D levels), then its markers: a `spawn` per
// slot, the `station`, `gate`s (`pair`: the other gate) and `rock_spawn`s (`dir`: the drift direction). The bodies the
// block owns (the station, ships, rocks) are made by init and the tick.
world_create :: proc(seed: u64, levels: []sim.Level_File, _: sim.No_Setup) -> ^World {
	world := new(World)
	problem: string
	world.phys, problem = physics.create_with_levels(
		{tick_hz = TICK_HZ, gravity = [3]f32{0, 0, 0}, workers = PHYSICS_WORKERS},
		levels,
		CAT_STATIC,
	)
	assert(problem == "", problem) // a missing level, or a hole in its collision
	arena := physics.level_data(world.phys, Level_Id.Arena)
	assert(arena.px_per_m > 0, "drift: the level is not a 2D level (src/level/README.md)")

	spawned: [PLAYERS]bool
	gate_markers: [MAX_GATES]int // each gate's marker index
	for &marker in arena.markers {
		pos := marker.pos.xy
		switch marker.kind {
		case "spawn":
			slot := level.prop_int(&marker, "slot")
			assert(slot >= 0 && slot < PLAYERS && !spawned[slot], "drift: a spawn's slot is out of range or taken")
			spawned[slot] = true
			world.spawns[slot] = pos
		case "station":
			world.station = pos
		case "gate":
			// `pair` is the other gate's marker index until every gate is known
			gate_markers[world.gates.count] = marker.index
			added := sim.append(&world.gates, Gate_Def{pos, level.prop_ref(&marker, "pair")})
			assert(added, "drift: too many gates")
		case "rock_spawn":
			dir := dmath.normalize(level.prop_vec2(&marker, "dir", {0, 1}))
			if dir == {} do dir = {0, 1}
			added := sim.append(&world.spawners, Spawner_Def{pos, dir})
			assert(added, "drift: too many rock spawners")
		}
	}
	for slot_spawned in spawned do assert(slot_spawned, "drift: the level needs a spawn marker per slot")
	assert(world.spawners.count > 0, "drift: the level has no rock_spawn marker")
	for &gate in sim.slice(&world.gates) {
		pair_marker := gate.pair
		gate.pair = -1
		for marker_index, i in gate_markers[:world.gates.count] {
			if marker_index == pair_marker do gate.pair = i
		}
	}
	return world
}

// Frees what world_create made: the physics world (the level with it) and the World itself.
world_destroy :: proc(world: ^World) {
	physics.destroy(world.phys)
	free(world)
}

// The tick-0 state (GAME.init): the arena's static geometry, the station at full HP, its kinematic hexagon at the
// station marker, turning.
init :: proc(t: ^Tick) {
	physics.level_change(t, t.world.phys, Level_Id.Arena)
	t.state.station_hp = STATION_HP
	corners: [6][2]f32
	for corner, k in HEXAGON do corners[k] = corner * STATION_RADIUS
	t.state.station, _, _ = physics.create_polygon_2d(
		t.world.phys,
		physics.body_def_2d(.Kinematic, t.world.station),
		physics.shape_def(CAT_STATION),
		corners[:],
		BODY_DEPTH,
	)
	physics.body_set_angular_velocity_2d(t.world.phys, t.state.station, STATION_SPIN)
}

// A ship's body at `at`, nose up.
create_ship :: proc(world: ^World, ship: ^Ship, at: [2]f32) {
	body_def := physics.body_def_2d(.Dynamic, at, UP)
	body_def.linear_damping = SHIP_DAMPING
	shape_def := physics.shape_def(CAT_SHIP)
	shape_def.density = SHIP_DENSITY
	shape_def.base_material.restitution = SHIP_RESTITUTION
	shape_def.base_material.friction = SHIP_FRICTION
	ship.body, _ = physics.create_circle_2d(world.phys, body_def, shape_def, SHIP_RADIUS)
}

// A rock in the rocks table and its body (ok = false: the table is full), tagged with the rock's handle key, so a
// bullet's ray names it.
create_rock :: proc(
	t: ^Tick,
	size: Rock_Size,
	variant: int,
	pos, vel: [2]f32,
	spin: f32,
) -> (
	handle: sim.Handle(Rock),
	ok: bool,
) {
	rock: ^Rock
	rock, handle = sim.spawn(&t.state.rocks) or_return
	shape_def := physics.shape_def(CAT_ROCK)
	shape_def.density = ROCK_DENSITY
	shape_def.base_material.restitution = ROCK_RESTITUTION
	shape_def.base_material.friction = ROCK_FRICTION
	points := rock_points(variant, size)
	body, _, _ := physics.create_polygon_2d(
		t.world.phys,
		physics.body_def_2d(.Dynamic, pos),
		shape_def,
		points[:],
		BODY_DEPTH,
		sim.handle_key(handle),
	)
	rock^ = {
		body    = body,
		size    = size,
		variant = u8(variant),
		hp      = ROCK_STATS[size].hp,
	}
	physics.body_set_linear_velocity_2d(t.world.phys, body, vel)
	physics.body_set_angular_velocity_2d(t.world.phys, body, spin)
	return handle, true
}

// The 8 corners of a rock's hull for a shape variant at a size, in metres around its centre. The sim builds rock
// bodies from them and the GDExtension hands them to the view to draw the rock meshes.
rock_points :: proc(variant: int, size: Rock_Size) -> (points: [8][2]f32) {
	for k in 0 ..< 8 {
		points[k] = dmath.DIR8[k] * (ROCK_SHAPES[variant][k] * ROCK_STATS[size].radius)
	}
	return
}
