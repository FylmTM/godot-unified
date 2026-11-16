// The World (outside the block): the physics world locked to the plane, the level and what the sim reads from
// its markers, body creation, and the game descriptor.
package drift

import "unified:b3"
import "unified:dmath"
import "unified:level"
import "unified:physics"
import "unified:sim"

// Shape categories (filter bits) and user materials (how rays tell entities apart).
CAT_STATIC :: u64(1 << 0)
CAT_SHIP :: u64(1 << 1)
CAT_ROCK :: u64(1 << 2)
CAT_STATION :: u64(1 << 3)
CAT_BULLET :: u64(1 << 4) // rays only
MAT_ROCK :: u64(1000) // + rock index
MAT_STATION :: u64(2000)

Gate_Def :: struct {
	pos:  [2]f32,
	pair: int, // gate index
}

Spawner_Def :: struct {
	pos: [2]f32,
	dir: [2]f32, // unit
}

World :: struct {
	phys:          ^physics.World,
	extras:        [1]sim.Extra,
	level_data:    level.Level,
	spawns:        [PLAYERS][2]f32, // by slot
	station:       [2]f32,
	gates:         [MAX_GATES]Gate_Def,
	gate_count:    int,
	spawners:      [MAX_SPAWNERS]Spawner_Def,
	spawner_count: int,
}

Game :: sim.Game(State, Input, World, Event, Cmd, PLAYERS)
Sim :: sim.Sim(State, Input, World, Event, Cmd, PLAYERS)
Tick :: sim.Tick(State, Input, World, Event, Cmd, PLAYERS)

@(rodata)
GAME := Game {
	name = "drift",
	version = "2",
	tick_hz = TICK_HZ,
	world_create = world_create,
	world_destroy = world_destroy,
	extras = proc(world: ^World) -> []sim.Extra {return world.extras[:]},
	init = init,
	tick = tick,
}

// What the keyed rolls are for (sim.roll_below, sim.roll_f32).
Roll :: enum u8 {
	Rock_Turn,
	Rock_Spin,
	Rock_Variant,
}

// Builds the world from the level (src/level/SPEC.md, 2D levels): static geometry, then the markers. Bodies the block owns (the station, ships, rocks) are created by init and the tick.
world_create :: proc(seed: u64, content: []u8) -> ^World {
	world := new(World)
	loaded, ok := level.load(content)
	assert(ok && loaded.px_per_m > 0, "drift: the level file is missing or not a 2D level (src/level/SPEC.md)")
	world.level_data = loaded
	world.phys = physics.create({gravity = [3]f32{0, 0, 0}, workers = PHYSICS_WORKERS})
	world.extras[0] = physics.extra(world.phys, State)
	_, problem := physics.create_static(world.phys, &world.level_data, CAT_STATIC)
	assert(problem == "", problem) // a hole in the level's collision
	for slot in 0 ..< PLAYERS do world.spawns[slot] = {f32(slot) * 2 - 3, 6}
	spawn_count := 0
	for &marker in world.level_data.markers {
		pos := [2]f32{marker.pos.x, marker.pos.y}
		switch marker.kind {
		case "spawn":
			if spawn_count < PLAYERS {
				world.spawns[spawn_count] = pos
				spawn_count += 1
			}
		case "station":
			world.station = pos
		case "gate":
			assert(world.gate_count < MAX_GATES, "drift: too many gates")
			world.gates[world.gate_count] = {pos, level.prop_ref(&marker, "pair")} // a marker index for now
			world.gate_count += 1
		case "rock_spawn":
			assert(world.spawner_count < MAX_SPAWNERS, "drift: too many rock spawners")
			dir := dmath.normalize2(level.prop_vec2(&marker, "dir", {0, 1}))
			if dir == {} do dir = {0, 1}
			world.spawners[world.spawner_count] = {pos, dir}
			world.spawner_count += 1
		}
	}
	assert(world.spawner_count > 0, "drift: the level has no rock_spawn marker")
	// gate pairs: marker index -> gate index
	for i in 0 ..< world.gate_count {
		pair := -1
		gate_index := 0
		for &marker in world.level_data.markers {
			if marker.kind != "gate" do continue
			if marker.index == world.gates[i].pair do pair = gate_index
			gate_index += 1
		}
		world.gates[i].pair = pair
	}
	return world
}

// Frees what world_create made: the physics world, the loaded level and the World itself.
world_destroy :: proc(world: ^World) {
	physics.destroy(world.phys)
	level.destroy(&world.level_data)
	free(world)
}

// The 8 corners of a rock's hull for a shape variant at a size, in metres around its centre. The sim builds rock
// bodies from them and the GDExtension hands them to the view to draw the rock meshes.
rock_points :: proc(variant: int, size: Rock_Size) -> (points: [8][2]f32) {
	radius := ROCK_RADIUS[size]
	for k in 0 ..< 8 {
		reach := ROCK_SHAPES[variant][k] * radius
		points[k] = {dmath.DIR8_C[k] * reach, dmath.DIR8_S[k] * reach}
	}
	return
}

// The station's hexagon (corners at k × 60°: cos/sin from exact constants).
@(rodata)
HEX_C := [6]f32{1, 0.5, -0.5, -1, -0.5, 0.5}
@(rodata)
HEX_S := [6]f32{0, 0.8660254, 0.8660254, 0, -0.8660254, -0.8660254}

// Sets up the tick-0 state (GAME.init): gives the station full HP and creates its turning kinematic hexagon at the
// station marker.
init :: proc(t: ^Tick) {
	t.state.station_hp = STATION_HP
	body_def := physics.body_def_2d(.Kinematic_Body, t.world.station)
	ref := physics.create_body(t.world.phys, &body_def)
	body := physics.body_id(t.world.phys, ref)
	shape_def := b3.default_shape_def()
	shape_def.filter.category_bits = CAT_STATION
	shape_def.base_material.user_material_id = MAT_STATION
	corners: [6][2]f32
	for k in 0 ..< 6 do corners[k] = {HEX_C[k] * STATION_RADIUS, HEX_S[k] * STATION_RADIUS}
	physics.polygon_2d(body, &shape_def, corners[:], ROCK_DEPTH)
	t.state.station = ref
	physics.set_velocity_2d(t.world.phys, t.state.station, {}, STATION_SPIN)
}

// A ship's body at `at`, nose up.
create_ship :: proc(world: ^World, ship: ^Ship, at: [2]f32) {
	body_def := physics.body_def_2d(.Dynamic_Body, at, {0, -1})
	body_def.linear_damping = SHIP_DAMPING
	body_def.is_bullet = false
	ref := physics.create_body(world.phys, &body_def)
	body := physics.body_id(world.phys, ref)
	shape_def := b3.default_shape_def()
	shape_def.density = SHIP_DENSITY
	shape_def.base_material.restitution = 0.5
	shape_def.base_material.friction = 0.1
	shape_def.filter.category_bits = CAT_SHIP
	physics.circle_2d(body, &shape_def, SHIP_RADIUS)
	ship.body = ref
}

// A rock in the rocks table and its body (ok = false: the table is full). Its shapes carry its slot index as
// the user material, so a bullet's ray finds it.
create_rock :: proc(
	state: ^State,
	world: ^World,
	size: Rock_Size,
	variant: int,
	pos, vel: [2]f32,
	spin: f32,
) -> (
	handle: sim.Handle(Rock),
	ok: bool,
) {
	rock: ^Rock
	rock, handle = sim.spawn(&state.rocks) or_return
	body_def := physics.body_def_2d(.Dynamic_Body, pos)
	ref := physics.create_body(world.phys, &body_def)
	body := physics.body_id(world.phys, ref)
	shape_def := b3.default_shape_def()
	shape_def.density = 1
	shape_def.base_material.restitution = 0.4
	shape_def.base_material.friction = 0.3
	shape_def.base_material.user_material_id = MAT_ROCK + u64(handle.index)
	shape_def.filter.category_bits = CAT_ROCK
	points := rock_points(variant, size)
	physics.polygon_2d(body, &shape_def, points[:], ROCK_DEPTH)
	rock^ = {
		body    = ref,
		size    = size,
		variant = u8(variant),
		hp      = ROCK_HP[size],
	}
	physics.set_velocity_2d(world.phys, rock.body, vel, spin)
	return handle, true
}
