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
	sensor:     physics.Shape_Ref, // plates, switches, locks: the volume's sensor (a body of the World's)
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
	spawns:           [PLAYERS][3]f32, // by slot
	start:            Volume, // walking in starts a run (zero: no route)
	finish:           Volume, // the trophy in it ends the run
	overlaps:         [dynamic]physics.Overlap, // scratch
	contacts:         [dynamic]physics.Contact_Event, // scratch
	character_def:    physics.Character_Def, // the players' (world_create)
}

// Builds the world from the level (src/level/SPEC.md): static geometry, then the markers the sim uses.
// Bodies the block owns (items, platforms, bells) are created by init, in this order.
world_create :: proc(seed: u64, content: []u8) -> ^World {
	world := new(World)
	loaded, ok := level.load(content)
	assert(ok, "friendslop: the level file is missing or not a level (src/level/SPEC.md)")
	world.level = loaded
	world.character_def = physics.CHARACTER_DEFAULT
	world.character_def.radius = PLAYER_RADIUS
	world.character_def.half_height = PLAYER_HALF_HEIGHT
	world.character_def.category = CAT_PLAYER
	world.character_def.hit_events = true
	world.character_def.sensor_events = true // plates and switches see players
	world.character_def.max_speed = WALK_SPEED
	world.character_def.pogo_rest = POGO_REST
	world.phys = physics.create({
		tick_hz             = TICK_HZ,
		hit_event_threshold = HIT_EVENT_SPEED,
		workers             = PHYSICS_WORKERS,
	})
	problem := physics.create_static(world.phys, &world.level, CAT_STATIC)
	assert(problem == "", problem) // a hole in the level's collision
	world.spawns = DEFAULT_SPAWNS
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
			kind := level.prop_enum(&marker, "kind", Item_Kind.Crate) // item.gd's export_enum: the names, lowercased
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
			def.mode = level.prop_enum(&marker, "mode", Platform_Mode.Ping_Pong) // platform.gd's export_enum
			seconds := level.prop_f32(&marker, "seconds", 2)
			wait := level.prop_f32(&marker, "wait", 0.5)
			def.path.ease = level.prop_bool(&marker, "smooth", true) ? .Smooth : .Linear
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
	for i in 0 ..< world.trigger_count {
		create_trigger_sensor(world, i)
	}

	return world
}

// The sensor of a plate, switch or lock (bells are bodies of the block: init): a static box over its volume that
// sees the bodies with sensor events on (items, characters). A plate's reaches PLATE_REACH above it (what stands on
// it); a plate sees items, and players unless it is items_only; a switch sees players; a lock sees items.
@(private)
create_trigger_sensor :: proc(world: ^World, index: int) {
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
	physics.destroy(world.phys)
	level.destroy(&world.level)
	delete(world.overlaps)
	delete(world.contacts)
	free(world)
}

// The tick-0 state: the hub, every item, platform and bell with its body; players join when present.
init :: proc(t: ^Tick) {
	t.state.phase = .Hub
	t.state.checkpoint = -1
	for i in 0 ..< t.world.item_count {
		t.state.items[i] = {
			body  = create_item_body(t.world, i),
			alive = true,
		}
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
	for i in 0 ..< t.world.trigger_count {
		def := &t.world.triggers[i]
		if def.kind != .Bell do continue
		shape_def := physics.shape_def(CAT_TRIGGER)
		shape_def.enable_hit_events = true
		t.state.bells[i], _ = physics.create_sphere(
			t.world.phys,
			physics.body_def(.Static, def.volume.pos),
			shape_def,
			def.radius,
			u64(i),
		)
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
