package friendslop

import "unified:dmath"
import "unified:level"
import "unified:physics"
import "unified:sim"

// Shape categories (filter bits): every query, contact and sensor reports the category of the shape it names, and
// the body's tag says which one: a player's player_key, an item's, a platform's or a trigger's index.
CAT_STATIC :: u64(1 << 0)
CAT_PLAYER :: u64(1 << 1)
CAT_ITEM :: u64(1 << 2)
CAT_PLATFORM :: u64(1 << 3)
CAT_TRIGGER :: u64(1 << 4)

Item_Kind :: enum u8 {
	Crate,
	Ball,
	Cube, // the weight cube for plates
	Key,
	Heavy, // too heavy for one: two handles
	Trophy,
}

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
	Lock, // a key item in it opens it (latched)
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
	volume:     Volume, // bells: only the position
	mass:       f32, // plates
	radius:     f32, // bells
	items_only: bool, // plates: players don't count
	marker:     int,
	sensor:     physics.Shape_Ref, // plates, switches, locks: the volume's sensor (create_trigger_body)
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

// The world outside the block: the physics world, the level and what the sim reads from its markers
// (games/friendslop/SPEC.md "Level"), and per-tick scratch.
World :: struct {
	phys:             ^physics.World,
	level:            level.Level,
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
	spawns:           [PLAYERS][3]f32, // by slot: a spawn marker each
	start:            Volume, // walking in starts a run (zero: no start marker, no route)
	finish:           Volume, // the trophy in it ends the run
	overlaps:         [dynamic]physics.Overlap, // scratch
	contacts:         [dynamic]physics.Contact_Event, // scratch
	character_def:    physics.Character_Def, // the players' (world_create)
}

// Builds the world from the level (src/level/SPEC.md): static geometry, then the markers the sim uses, and the
// triggers' static bodies. A property's default lives in its marker's script (game/levels/markers/), which the export
// writes whole: the sim reads the properties without defaults of its own and asserts what its rules need. The bodies
// the block owns (items, platforms) are created by init.
world_create :: proc(seed: u64, content: []u8) -> ^World {
	world := new(World)
	world.character_def = physics.CHARACTER_DEFAULT
	world.character_def.radius = PLAYER_RADIUS
	world.character_def.half_height = PLAYER_HALF_HEIGHT
	world.character_def.category = CAT_PLAYER
	world.character_def.hit_events = true
	world.character_def.sensor_events = true // plates and switches see players
	world.character_def.max_speed = WALK_SPEED
	world.character_def.pogo_rest = POGO_REST
	problem: string
	world.phys, world.level, problem = physics.create_with_level(
		{tick_hz = TICK_HZ, hit_event_threshold = HIT_EVENT_SPEED, workers = PHYSICS_WORKERS},
		content,
		CAT_STATIC,
	)
	assert(problem == "", problem) // no level, or a hole in its collision
	// Triggers first: platforms refer to them by marker index.
	trigger_of := make([]int, len(world.level.markers), context.temp_allocator)
	for &trigger in trigger_of do trigger = -1
	for &marker in world.level.markers {
		def := Trigger_Def {
			marker = marker.index,
		}
		switch marker.kind {
		case "plate":
			def.kind = .Plate
			def.volume = volume_of(&marker)
			def.mass = level.prop_f32(&marker, "mass")
			def.items_only = level.prop_bool(&marker, "items_only")
			assert(def.mass > 0, "friendslop: a plate's mass must be positive")
		case "bell":
			def.kind = .Bell
			def.volume.pos = marker.pos
			def.radius = level.prop_f32(&marker, "radius")
			assert(def.radius > 0, "friendslop: a bell's radius must be positive")
		case "switch":
			def.kind = .Switch
			def.volume = volume_of(&marker)
		case "lock":
			def.kind = .Lock
			def.volume = volume_of(&marker)
		case:
			continue
		}
		assert(world.trigger_count < MAX_TRIGGERS, "friendslop: too many triggers")
		trigger_of[marker.index] = world.trigger_count
		world.triggers[world.trigger_count] = def
		world.trigger_count += 1
	}
	spawned: [PLAYERS]bool
	for &marker in world.level.markers {
		switch marker.kind {
		case "spawn":
			slot := level.prop_int(&marker, "slot")
			assert(
				slot >= 0 && slot < PLAYERS && !spawned[slot],
				"friendslop: a spawn's slot is out of range or taken",
			)
			spawned[slot] = true
			world.spawns[slot] = marker.pos
		case "item":
			assert(world.item_count < MAX_ITEMS, "friendslop: too many items")
			kind, known := level.prop_enum(&marker, "kind", Item_Kind.Crate) // item.gd's export_enum: the names, lowercased
			assert(known, "friendslop: an item's kind is no Item_Kind")
			world.items[world.item_count] = {kind, marker.pos, marker.rot, marker.index}
			world.item_count += 1
		case "platform":
			assert(world.platform_count < MAX_PLATFORMS, "friendslop: too many platforms")
			def := &world.platforms[world.platform_count]
			def.origin = marker.pos
			def.rot = marker.rot
			def.half = volume_of(&marker).half
			def.marker = marker.index
			def.trigger = -1
			if ref := level.prop_ref(&marker, "trigger"); ref >= 0 do def.trigger = trigger_of[ref]
			known: bool
			def.mode, known = level.prop_enum(&marker, "mode", Platform_Mode.Ping_Pong) // platform.gd's export_enum
			assert(known, "friendslop: a platform's mode is no Platform_Mode")
			seconds := level.prop_f32(&marker, "seconds")
			wait := level.prop_f32(&marker, "wait")
			assert(seconds > 0 && wait >= 0, "friendslop: a platform needs seconds per leg, and no negative wait")
			def.path.ease = level.prop_bool(&marker, "smooth") ? .Smooth : .Linear
			def.path.mode = def.mode == .Loop ? .Loop : def.mode == .Ping_Pong ? .Ping_Pong : .Once
			point_count := dmath.min(len(marker.path), physics.MAX_PATH_POINTS)
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
			pad := Pad_Def{volume_of(&marker), level.prop_vec3(&marker, "launch")}
			assert(pad.launch != {}, "friendslop: a pad's launch is zero")
			world.pads[world.pad_count] = pad
			world.pad_count += 1
		case "bumper":
			assert(world.bumper_count < MAX_BUMPERS, "friendslop: too many bumpers")
			bumper := Bumper_Def{volume_of(&marker), level.prop_f32(&marker, "strength")}
			assert(bumper.strength > 0, "friendslop: a bumper's strength must be positive")
			world.bumpers[world.bumper_count] = bumper
			world.bumper_count += 1
		case "checkpoint":
			assert(world.checkpoint_count < MAX_CHECKPOINTS, "friendslop: too many checkpoints")
			checkpoint := Checkpoint_Def{level.prop_int(&marker, "index"), volume_of(&marker)}
			assert(checkpoint.index >= 0, "friendslop: a checkpoint's index is negative (-1 is the hub)")
			world.checkpoints[world.checkpoint_count] = checkpoint
			world.checkpoint_count += 1
		case "start":
			world.start = volume_of(&marker)
		case "finish":
			world.finish = volume_of(&marker)
		}
	}
	for has_spawn in spawned do assert(has_spawn, "friendslop: the level needs a spawn marker per slot")
	for i in 0 ..< world.trigger_count do create_trigger_body(world, i)
	return world
}

// A marker's volume: at the marker, its `size` property the half extents (positive: a rule tests points against it).
@(private)
volume_of :: proc(marker: ^level.Marker) -> Volume {
	half := level.prop_vec3(marker, "size")
	assert(half.x > 0 && half.y > 0 && half.z > 0, "friendslop: a marker's size must be positive")
	return {marker.pos, half}
}

// A trigger's static body, the World's (it never moves or changes). A plate, switch or lock is a sensor box over its
// volume that sees the bodies with sensor events on (items, characters): a plate's reaches PLATE_REACH above it (what
// stands on it) and sees items, and players unless it is items_only; a switch sees players; a lock sees items. A bell
// is a sphere that reports hits (apply_hits rings it).
//
// The rule picks the tool: a sensor where it needs who or what is in the volume (a plate's mass, a switch's player, a
// lock's key), a point test (in_volume) where it asks whether one known body is (pads, bumpers, checkpoints, the start
// and the finish).
@(private)
create_trigger_body :: proc(world: ^World, index: int) {
	def := &world.triggers[index]
	mask: u64
	volume := def.volume
	switch def.kind {
	case .Plate:
		mask = def.items_only ? CAT_ITEM : CAT_ITEM | CAT_PLAYER
		top := volume.pos.y + volume.half.y
		// top - PLATE_SINK .. top + PLATE_REACH
		volume = {
			{volume.pos.x, top + (PLATE_REACH - PLATE_SINK) / 2, volume.pos.z},
			{volume.half.x, (PLATE_REACH + PLATE_SINK) / 2, volume.half.z},
		}
	case .Switch:
		mask = CAT_PLAYER
	case .Lock:
		mask = CAT_ITEM
	case .Bell:
		shape_def := physics.shape_def(CAT_TRIGGER)
		shape_def.enable_hit_events = true
		physics.create_sphere(world.phys, physics.body_def(.Static, volume.pos), shape_def, def.radius, u64(index))
		return
	}
	shape_def := physics.shape_def(CAT_TRIGGER, mask)
	shape_def.is_sensor = true
	shape_def.enable_sensor_events = true
	_, def.sensor = physics.create_box(
		world.phys,
		physics.body_def(.Static, volume.pos),
		shape_def,
		volume.half,
		u64(index),
	)
}

// Frees what world_create made: the physics world, the loaded level, the scratch lists and the World itself.
world_destroy :: proc(world: ^World) {
	physics.destroy_with_level(world.phys, &world.level)
	delete(world.overlaps)
	delete(world.contacts)
	free(world)
}

// The tick-0 state: the hub, every item and platform with its body; players join when present.
init :: proc(t: ^Tick) {
	t.state.phase = .Hub
	t.state.checkpoint = -1
	for i in 0 ..< t.world.item_count {
		t.state.items[i].body = create_item_body(t.world, i)
	}
	for i in 0 ..< t.world.platform_count {
		def := &t.world.platforms[i]
		body_def := physics.body_def(.Kinematic, def.origin, def.rot)
		body_def.enable_sleep = false
		shape_def := physics.shape_def(CAT_PLATFORM)
		shape_def.base_material.friction = PLATFORM_FRICTION
		ref, _ := physics.create_box(t.world.phys, body_def, shape_def, def.half, u64(i))
		t.state.platforms[i] = {
			body    = ref,
			running = def.trigger < 0,
		}
	}
}

// What a body is, from a query's or a contact's category and tag: an item (its index) or a player (its handle).
Body_Kind :: enum u8 {
	Other,
	Item,
	Player,
}

Body :: struct {
	kind:   Body_Kind,
	item:   int, // .Item: the item index
	player: sim.Player, // .Player
}

body_of :: proc(category, tag: u64) -> Body {
	switch {
	case category & CAT_ITEM != 0:
		return {kind = .Item, item = int(tag)}
	case category & CAT_PLAYER != 0:
		return {kind = .Player, player = sim.player_of_key(tag)}
	}
	return {}
}

// Whether a point is inside an axis-aligned volume (pads, bumpers, checkpoints, start and finish).
in_volume :: proc(volume: Volume, point: [3]f32) -> bool {
	offset := point - volume.pos
	return abs(offset.x) <= volume.half.x && abs(offset.y) <= volume.half.y && abs(offset.z) <= volume.half.z
}
