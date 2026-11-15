// The World (outside the block): the physics world, the level file and what the sim reads from its
// markers (games/friendslop/SPEC.md "Level"), body creation, and the game descriptor.
package friendslop

import "unified:b3"
import "unified:level"
import "unified:physics"
import "unified:sim"

// Shape categories (filter bits) and user materials (how hits and rays tell entities apart).
CAT_STATIC :: u64(1 << 0)
CAT_PLAYER :: u64(1 << 1)
CAT_ITEM :: u64(1 << 2)
CAT_PLATFORM :: u64(1 << 3)
CAT_TRIGGER :: u64(1 << 4)
MAT_PLAYER :: u64(100) // + the player's member index (Player.index)
MAT_ITEM :: u64(1000) // + item index
MAT_TRIGGER :: u64(2000) // + trigger index
MAT_PLATFORM :: u64(3000) // + platform index

GRAVITY :: 10.0 // Box3D's default, |g|

Item_Kind :: enum u8 {
	Crate,
	Ball,
	Cube, // the weight cube for plates
	Key,
	Heavy, // too heavy for one: two handles
	Trophy,
}

@(rodata)
ITEM_KIND_NAMES := [Item_Kind]string {
	.Crate  = "crate",
	.Ball   = "ball",
	.Cube   = "cube",
	.Key    = "key",
	.Heavy  = "heavy",
	.Trophy = "trophy",
}

Item_Spec :: struct {
	half:        [3]f32, // box half extents (zero: a sphere)
	radius:      f32, // sphere radius; for boxes, the grab reach bonus
	mass:        f32,
	lift:        f32, // one holder's spring force cap, in multiples of the item's weight
	friction:    f32,
	restitution: f32,
	grab_points: u8, // 1 = the centre, 2 = ±x ends
	throwable:   bool,
}

@(rodata)
ITEM_SPECS := [Item_Kind]Item_Spec {
	.Crate = {
		half        = {0.35, 0.35, 0.35},
		radius      = 0.35,
		mass        = 10,
		lift        = 3,
		friction    = 0.6,
		restitution = 0.1,
		grab_points = 1,
		throwable   = true,
	},
	.Ball = {
		radius      = 0.3,
		mass        = 3,
		lift        = 3,
		friction    = 0.5,
		restitution = 0.6,
		grab_points = 1,
		throwable   = true,
	},
	.Cube = {
		half        = {0.4, 0.4, 0.4},
		radius      = 0.4,
		mass        = 20,
		lift        = 2,
		friction    = 0.7,
		restitution = 0,
		grab_points = 1,
		throwable   = true,
	},
	.Key = {
		half        = {0.15, 0.25, 0.15},
		radius      = 0.25,
		mass        = 3,
		lift        = 3,
		friction    = 0.6,
		restitution = 0.1,
		grab_points = 1,
		throwable   = true,
	},
	.Heavy = {
		half        = {0.7, 0.4, 0.45},
		radius      = 0.7,
		mass        = 50,
		lift        = 0.6,
		friction    = 0.6,
		restitution = 0,
		grab_points = 2,
		throwable   = false,
	},
	.Trophy = {
		half        = {0.25, 0.4, 0.25},
		radius      = 0.4,
		mass        = 5,
		lift        = 3,
		friction    = 0.6,
		restitution = 0.1,
		grab_points = 1,
		throwable   = true,
	},
}

// Holding a friend: the spring's cap is 2.5× a player's weight (a soft spring needs headroom to accelerate
// the body, not just hold it: 1.4× only drags a friend along the floor).
PLAYER_LIFT :: 2.5

Platform_Mode :: enum u8 {
	Ping_Pong,
	Loop,
	Once,
	Follow, // moves forward while its trigger is active, back while not (gates, bridges, ramps)
}

Trigger_Kind :: enum u8 {
	Plate, // pressed while the mass on it reaches `mass` (players count unless items_only)
	Bell, // rung by an item hitting it fast enough (latched)
	Switch, // a player touches it (latched)
	Lock, // a key item's centre inside it opens it (latched)
}

Volume :: struct {
	pos:  [3]f32,
	half: [3]f32,
}

Item_Def :: struct {
	kind:   Item_Kind,
	pos:    [3]f32,
	rot:    [4]f32,
	marker: int,
}

Platform_Def :: struct {
	path:    physics.Path, // offsets from the marker are path point − first point
	origin:  [3]f32, // the marker's position: the body at phase 0
	rot:     [4]f32,
	half:    [3]f32,
	mode:    Platform_Mode,
	trigger: int, // trigger index (-1: none)
	marker:  int,
}

Trigger_Def :: struct {
	kind:       Trigger_Kind,
	volume:     Volume,
	mass:       f32, // plates
	radius:     f32, // bells
	items_only: bool, // plates: players don't count
	marker:     int,
}

Pad_Def :: struct {
	volume: Volume,
	launch: [3]f32, // the velocity given (y up, plus a push)
}

Bumper_Def :: struct {
	volume:   Volume,
	strength: f32,
}

Checkpoint_Def :: struct {
	index:  int,
	volume: Volume,
}

World :: struct {
	phys:             ^physics.World,
	extras:           [1]sim.Extra,
	level:            level.Level,
	character_defs:   [MEMBERS]physics.Character_Def, // by member index: each body's material names its player
	items:            [MAX_ITEMS]Item_Def,
	item_count:       int,
	platforms:        [MAX_PLATFORMS]Platform_Def,
	platform_count:   int,
	triggers:         [MAX_TRIGGERS]Trigger_Def,
	trigger_count:    int,
	pads:             [MAX_PADS]Pad_Def,
	pad_count:        int,
	bumpers:          [MAX_BUMPERS]Bumper_Def,
	bumper_count:     int,
	checkpoints:      [MAX_CHECKPOINTS]Checkpoint_Def,
	checkpoint_count: int,
	spawns:           [PLAYERS][3]f32, // by slot
	start:            Volume, // walking in starts a run (zero: no route)
	finish:           Volume, // the trophy in it ends the run
	links:            [dynamic]physics.Body_Link, // scratch
	hits:             [dynamic]physics.Hit_Event, // scratch
}

Game :: sim.Game(State, Input, World, PLAYERS)
Sim :: sim.Sim(State, Input, World, PLAYERS)

@(rodata)
GAME := Game {
	name = "friendslop",
	version = "2",
	tick_hz = TICK_HZ,
	world_create = world_create,
	world_destroy = world_destroy,
	extras = proc(world: ^World) -> []sim.Extra {return world.extras[:]},
	init = init,
	tick = tick,
	events = Event,
}

@(rodata)
CHARACTER_DEF := physics.Character_Def {
	radius                 = PLAYER_RADIUS,
	half_height            = PLAYER_HALF_HEIGHT,
	density                = 200,
	category               = CAT_PLAYER,
	hit_events             = true,
	max_speed              = WALK_SPEED,
	min_speed              = 0.1,
	stop_speed             = 3,
	accelerate             = 20,
	friction               = 8,
	air_steer              = 0.25,
	jump_speed             = 7,
	gravity_scale          = 1.5,
	max_ground_force       = 6000,
	max_air_force          = 1500,
	pogo_rest              = POGO_REST,
	pogo_hertz             = 3,
	pogo_damping           = 0.8,
	pogo_compression_scale = 100,
	pogo_tension_scale     = 100,
	min_ground_normal_y    = 0.7,
	slide_s                = 0.2,
	coyote_s               = 0.125,
	jump_buffer_s          = 0.125,
}

// Builds the world from the level (src/level/SPEC.md): static geometry, then the markers the sim uses.
// Bodies the block owns (items, platforms, bells) are created by init, in this order.
world_create :: proc(seed: u64, content: []u8) -> ^World {
	world := new(World)
	loaded, ok := level.load(content)
	assert(ok, "friendslop: the level file is missing or not a level (src/level/SPEC.md)")
	world.level = loaded
	world.phys = physics.create({
		anchor        = true,
		hit_threshold = 2,
		workers       = PHYSICS_WORKERS,
	})
	world.extras[0] = physics.extra(world.phys, State)
	physics.create_static(world.phys, &world.level, CAT_STATIC)
	for index in 0 ..< MEMBERS {
		world.character_defs[index] = CHARACTER_DEF
		world.character_defs[index].material = MAT_PLAYER + u64(index)
	}
	for slot in 0 ..< PLAYERS do world.spawns[slot] = {f32(slot) * 1.5 - 2.25, 1.2, 0}
	// Triggers first: platforms refer to them by marker index.
	trigger_of := make([]int, len(world.level.markers), context.temp_allocator)
	for &trigger in trigger_of do trigger = -1
	for &marker in world.level.markers {
		kind: Trigger_Kind
		switch marker.kind {
		case "plate":
			kind = .Plate
		case "bell":
			kind = .Bell
		case "switch":
			kind = .Switch
		case "lock":
			kind = .Lock
		case:
			continue
		}
		assert(world.trigger_count < MAX_TRIGGERS, "friendslop: too many triggers")
		trigger_of[marker.index] = world.trigger_count
		world.triggers[world.trigger_count] = {
			kind       = kind,
			volume     = {marker.pos, level.prop_vec3(&marker, "size", {0.75, 0.25, 0.75})},
			mass       = level.prop_f32(&marker, "mass", 15),
			radius     = level.prop_f32(&marker, "radius", 0.5),
			items_only = level.prop_bool(&marker, "items_only"),
			marker     = marker.index,
		}
		world.trigger_count += 1
	}
	for &marker in world.level.markers {
		switch marker.kind {
		case "spawn":
			slot := level.prop_int(&marker, "slot")
			if slot >= 0 && slot < PLAYERS do world.spawns[slot] = marker.pos
		case "item":
			assert(world.item_count < MAX_ITEMS, "friendslop: too many items")
			kind := Item_Kind.Crate
			name := level.prop_string(&marker, "kind", "crate")
			for kind_name, candidate in ITEM_KIND_NAMES {
				if kind_name == name do kind = candidate
			}
			world.items[world.item_count] = {kind, marker.pos, marker.rot, marker.index}
			world.item_count += 1
		case "platform":
			assert(world.platform_count < MAX_PLATFORMS, "friendslop: too many platforms")
			def := &world.platforms[world.platform_count]
			def.origin = marker.pos
			def.rot = marker.rot
			def.half = level.prop_vec3(&marker, "size", {1.5, 0.25, 1.5})
			def.marker = marker.index
			def.trigger = -1
			if ref := level.prop_ref(&marker, "trigger"); ref >= 0 do def.trigger = trigger_of[ref]
			switch level.prop_string(&marker, "mode", "ping_pong") {
			case "loop":
				def.mode = .Loop
			case "once":
				def.mode = .Once
			case "follow":
				def.mode = .Follow
			case:
				def.mode = .Ping_Pong
			}
			seconds := level.prop_f32(&marker, "seconds", 2)
			wait := level.prop_f32(&marker, "wait", 0.5)
			def.path.ease = level.prop_bool(&marker, "smooth", true) ? .Smooth : .Linear
			def.path.mode = def.mode == .Loop ? .Loop : def.mode == .Ping_Pong ? .Ping_Pong : .Once
			point_count := min(len(marker.path), physics.MAX_PATH_POINTS)
			if point_count == 0 {
				def.path.points[0] = marker.pos
				point_count = 1
			}
			for i in 0 ..< point_count {
				if len(marker.path) > 0 do def.path.points[i] = marker.path[i]
				def.path.seconds[i] = seconds
				def.path.wait_s[i] = def.mode == .Follow ? 0 : wait
			}
			def.path.count = u8(point_count)
			world.platform_count += 1
		case "pad":
			assert(world.pad_count < MAX_PADS, "friendslop: too many pads")
			world.pads[world.pad_count] = {
				volume = {marker.pos, level.prop_vec3(&marker, "size", {0.75, 0.3, 0.75})},
				launch = level.prop_vec3(&marker, "launch", {0, 12, 0}),
			}
			world.pad_count += 1
		case "bumper":
			assert(world.bumper_count < MAX_BUMPERS, "friendslop: too many bumpers")
			world.bumpers[world.bumper_count] = {
				volume   = {marker.pos, level.prop_vec3(&marker, "size", {0.6, 0.8, 0.6})},
				strength = level.prop_f32(&marker, "strength", 9),
			}
			world.bumper_count += 1
		case "checkpoint":
			assert(world.checkpoint_count < MAX_CHECKPOINTS, "friendslop: too many checkpoints")
			world.checkpoints[world.checkpoint_count] = {
				index  = level.prop_int(&marker, "index", world.checkpoint_count + 1),
				volume = {marker.pos, level.prop_vec3(&marker, "size", {2, 2, 2})},
			}
			world.checkpoint_count += 1
		case "start":
			world.start = {marker.pos, level.prop_vec3(&marker, "size", {2, 2, 0.5})}
		case "finish":
			world.finish = {marker.pos, level.prop_vec3(&marker, "size", {1, 1, 1})}
		}
	}
	return world
}

// Frees what world_create made: the physics world, the loaded level, the scratch lists and the World itself.
world_destroy :: proc(world: ^World) {
	physics.destroy(world.phys)
	level.destroy(&world.level)
	delete(world.links)
	delete(world.hits)
	free(world)
}

// The tick-0 state: the hub, every item, platform and bell with its body; players join when present.
init :: proc(state: ^State, world: ^World, seed: u64) {
	state.phase = .Hub
	state.checkpoint = -1
	for i in 0 ..< world.item_count {
		state.items[i] = {
			body  = create_item_body(world, i),
			alive = true,
		}
	}
	for i in 0 ..< world.platform_count {
		def := &world.platforms[i]
		body_def := b3.default_body_def()
		body_def.type = .Kinematic_Body
		body_def.position = def.origin
		body_def.rotation = def.rot
		body_def.enable_sleep = false
		ref := physics.create_body(world.phys, &body_def)
		id := physics.body_id(world.phys, ref)
		shape_def := b3.default_shape_def()
		shape_def.filter.category_bits = CAT_PLATFORM
		shape_def.base_material.user_material_id = MAT_PLATFORM + u64(i)
		shape_def.base_material.friction = 0.8
		hull := b3.make_box_hull(def.half.x, def.half.y, def.half.z)
		b3.create_hull_shape(id, &shape_def, &hull.base)
		state.platforms[i] = {
			body    = ref,
			running = def.trigger < 0,
		}
	}
	for i in 0 ..< world.trigger_count {
		def := &world.triggers[i]
		if def.kind != .Bell do continue
		body_def := b3.default_body_def()
		body_def.position = def.volume.pos
		ref := physics.create_body(world.phys, &body_def)
		id := physics.body_id(world.phys, ref)
		shape_def := b3.default_shape_def()
		shape_def.filter.category_bits = CAT_TRIGGER
		shape_def.base_material.user_material_id = MAT_TRIGGER + u64(i)
		shape_def.enable_hit_events = true
		sphere := b3.Sphere{{}, def.radius}
		b3.create_sphere_shape(id, &shape_def, &sphere)
		state.bodies[i] = ref
	}
}

// Creates an item's dynamic body at its level placement (a sphere or a box, its density set from the item's mass),
// with hit events on and its index as the user material so hits and rays know which item it is.
create_item_body :: proc(world: ^World, index: int) -> Body_Ref {
	def := &world.items[index]
	spec := &ITEM_SPECS[def.kind]
	body_def := b3.default_body_def()
	body_def.type = .Dynamic_Body
	body_def.position = def.pos
	body_def.rotation = def.rot
	ref := physics.create_body(world.phys, &body_def)
	id := physics.body_id(world.phys, ref)
	shape_def := b3.default_shape_def()
	shape_def.filter.category_bits = CAT_ITEM
	shape_def.base_material.user_material_id = MAT_ITEM + u64(index)
	shape_def.base_material.friction = spec.friction
	shape_def.base_material.restitution = spec.restitution
	shape_def.enable_hit_events = true
	if spec.half == {} {
		radius := spec.radius
		shape_def.density = spec.mass / (4.0 / 3.0 * 3.1415927 * radius * radius * radius)
		sphere := b3.Sphere{{}, radius}
		b3.create_sphere_shape(id, &shape_def, &sphere)
	} else {
		half := spec.half
		shape_def.density = spec.mass / (8 * half.x * half.y * half.z)
		hull := b3.make_box_hull(half.x, half.y, half.z)
		b3.create_hull_shape(id, &shape_def, &hull.base)
	}
	return ref
}

// The offset of an item's grab point `point` in the item's local frame.
grab_point_offset :: proc(kind: Item_Kind, point: int) -> [3]f32 {
	spec := &ITEM_SPECS[kind]
	if spec.grab_points < 2 do return {}
	x := spec.half.x + 0.05
	return {point == 0 ? -x : x, 0, 0}
}

// Whether a point is inside an axis-aligned volume (pads, bumpers, plates, switches, checkpoints, start and finish).
in_volume :: proc(volume: Volume, point: [3]f32) -> bool {
	offset := point - volume.pos
	return abs(offset.x) <= volume.half.x && abs(offset.y) <= volume.half.y && abs(offset.z) <= volume.half.z
}
