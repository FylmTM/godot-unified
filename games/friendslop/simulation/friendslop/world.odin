// The World (outside the block): the physics world, the level file and what the sim reads from its
// markers (spec/friendslop.md "Level"), body creation, and the game descriptor.
package friendslop

import b3 "unified:box3d"
import "unified:level"
import "unified:physics"
import "unified:sim"

// Shape categories (filter bits) and user materials (how hits and rays tell entities apart).
CAT_STATIC :: u64(1 << 0)
CAT_PLAYER :: u64(1 << 1)
CAT_ITEM :: u64(1 << 2)
CAT_PLATFORM :: u64(1 << 3)
CAT_TRIGGER :: u64(1 << 4)
MAT_PLAYER :: u64(100) // + slot
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
	handles:     u8, // grab points: 1 = the centre, 2 = ±x ends
	throwable:   bool,
}

ITEM_SPECS := [Item_Kind]Item_Spec {
	.Crate = {
		half = {0.35, 0.35, 0.35},
		radius = 0.35,
		mass = 10,
		lift = 3,
		friction = 0.6,
		restitution = 0.1,
		handles = 1,
		throwable = true,
	},
	.Ball = {radius = 0.3, mass = 3, lift = 3, friction = 0.5, restitution = 0.6, handles = 1, throwable = true},
	.Cube = {
		half = {0.4, 0.4, 0.4},
		radius = 0.4,
		mass = 20,
		lift = 2,
		friction = 0.7,
		restitution = 0,
		handles = 1,
		throwable = true,
	},
	.Key = {
		half = {0.15, 0.25, 0.15},
		radius = 0.25,
		mass = 3,
		lift = 3,
		friction = 0.6,
		restitution = 0.1,
		handles = 1,
		throwable = true,
	},
	.Heavy = {
		half = {0.7, 0.4, 0.45},
		radius = 0.7,
		mass = 50,
		lift = 0.6,
		friction = 0.6,
		restitution = 0,
		handles = 2,
		throwable = false,
	},
	.Trophy = {
		half = {0.25, 0.4, 0.25},
		radius = 0.4,
		mass = 5,
		lift = 3,
		friction = 0.6,
		restitution = 0.1,
		handles = 1,
		throwable = true,
	},
}

// Holding a friend: the spring's cap is 2.5× a player's weight (a soft spring needs headroom to accelerate
// the body, not just hold it: 1.4× only drags a friend along the floor).
PLAYER_LIFT :: 2.5

Plat_Mode :: enum u8 {
	Ping_Pong,
	Loop,
	Once,
	Follow, // moves forward while its trigger is active, back while not (gates, bridges, ramps)
}

Trigger_Kind :: enum u8 {
	Plate, // pressed while the mass on it reaches `mass`
	Bell, // rung by an item hitting it fast enough (latched)
	Switch, // a player touches it (latched)
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
	mode:    Plat_Mode,
	trigger: int, // trigger index (-1: none)
	marker:  int,
}

Trigger_Def :: struct {
	kind:   Trigger_Kind,
	vol:    Volume,
	mass:   f32, // plates
	radius: f32, // bells
	marker: int,
}

Pad_Def :: struct {
	vol:    Volume,
	launch: [3]f32, // the velocity given (y up, plus a push)
}

Bumper_Def :: struct {
	vol:      Volume,
	strength: f32,
}

Checkpoint_Def :: struct {
	index: int,
	vol:   Volume,
}

World :: struct {
	phys:          ^physics.World,
	extras:        [1]sim.Extra,
	lvl:           level.Level,
	movers:        [MAX_PLAYERS]physics.Mover_Def,
	items:         [MAX_ITEMS]Item_Def,
	n_items:       int,
	platforms:     [MAX_PLATFORMS]Platform_Def,
	n_platforms:   int,
	triggers:      [MAX_TRIGGERS]Trigger_Def,
	n_triggers:    int,
	pads:          [MAX_PADS]Pad_Def,
	n_pads:        int,
	bumpers:       [MAX_BUMPERS]Bumper_Def,
	n_bumpers:     int,
	checkpoints:   [MAX_CHECKPOINTS]Checkpoint_Def,
	n_checkpoints: int,
	spawns:        [MAX_PLAYERS][3]f32,
	start:         Volume, // walking in starts a run (zero: no route)
	finish:        Volume, // the trophy in it ends the run
	links:         [dynamic]physics.Body_Link, // scratch
	hits:          [dynamic]physics.Hit_Event, // scratch
}

Game :: sim.Game(State, Input, World, MAX_PLAYERS)
Sim :: sim.Sim(State, Input, World, MAX_PLAYERS)

GAME := Game {
	name = "friendslop",
	version = "1",
	tick_hz = TICK_HZ,
	world_create = world_create,
	world_destroy = world_destroy,
	extras = proc(w: ^World) -> []sim.Extra {return w.extras[:]},
	init = init,
	tick = tick,
	event_names = EVENT_NAMES,
}

MOVER := physics.Mover_Def {
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

// Builds the world from the level (spec/level.md): static geometry, then the markers the sim uses.
// Bodies the block owns (items, platforms, bells) are created by init, in this order.
world_create :: proc(seed: u64, content: []u8) -> ^World {
	w := new(World)
	lvl, ok := level.load(content)
	assert(ok, "friendslop: the level file is missing or not a level (spec/level.md)")
	w.lvl = lvl
	w.phys = physics.create({anchor = true, hit_threshold = 2})
	w.extras[0] = physics.extra(w.phys, State)
	physics.create_static(w.phys, &w.lvl, CAT_STATIC)
	for p in 0 ..< MAX_PLAYERS {
		w.movers[p] = MOVER
		w.movers[p].material = MAT_PLAYER + u64(p)
		w.spawns[p] = {f32(p) * 1.5 - 2.25, 1.2, 0}
	}
	// Triggers first: platforms refer to them by marker index.
	trigger_of := make([]int, len(w.lvl.markers), context.temp_allocator)
	for &t in trigger_of do t = -1
	for &m in w.lvl.markers {
		kind: Trigger_Kind
		switch m.kind {
		case "plate":
			kind = .Plate
		case "bell":
			kind = .Bell
		case "switch":
			kind = .Switch
		case:
			continue
		}
		assert(w.n_triggers < MAX_TRIGGERS, "friendslop: too many triggers")
		trigger_of[m.index] = w.n_triggers
		w.triggers[w.n_triggers] = {
			kind   = kind,
			vol    = {m.pos, level.prop_vec3(&m, "size", {0.75, 0.25, 0.75})},
			mass   = level.prop_f32(&m, "mass", 15),
			radius = level.prop_f32(&m, "radius", 0.5),
			marker = m.index,
		}
		w.n_triggers += 1
	}
	for &m in w.lvl.markers {
		switch m.kind {
		case "spawn":
			slot := level.prop_int(&m, "slot")
			if slot >= 0 && slot < MAX_PLAYERS do w.spawns[slot] = m.pos
		case "item":
			assert(w.n_items < MAX_ITEMS, "friendslop: too many items")
			kind := Item_Kind.Crate
			name := level.prop_string(&m, "kind", "crate")
			for n, k in ITEM_KIND_NAMES {
				if n == name do kind = k
			}
			w.items[w.n_items] = {kind, m.pos, m.rot, m.index}
			w.n_items += 1
		case "platform":
			assert(w.n_platforms < MAX_PLATFORMS, "friendslop: too many platforms")
			d := &w.platforms[w.n_platforms]
			d.origin = m.pos
			d.rot = m.rot
			d.half = level.prop_vec3(&m, "size", {1.5, 0.25, 1.5})
			d.marker = m.index
			d.trigger = -1
			if r := level.prop_ref(&m, "trigger"); r >= 0 do d.trigger = trigger_of[r]
			switch level.prop_string(&m, "mode", "ping_pong") {
			case "loop":
				d.mode = .Loop
			case "once":
				d.mode = .Once
			case "follow":
				d.mode = .Follow
			case:
				d.mode = .Ping_Pong
			}
			seconds := level.prop_f32(&m, "seconds", 2)
			wait := level.prop_f32(&m, "wait", 0.5)
			d.path.ease = level.prop_bool(&m, "smooth", true) ? .Smooth : .Linear
			d.path.mode = d.mode == .Loop ? .Loop : d.mode == .Ping_Pong ? .Ping_Pong : .Once
			n := min(len(m.path), physics.MAX_PATH_POINTS)
			if n == 0 {
				d.path.points[0] = m.pos
				n = 1
			}
			for i in 0 ..< n {
				if len(m.path) > 0 do d.path.points[i] = m.path[i]
				d.path.seconds[i] = seconds
				d.path.wait_s[i] = d.mode == .Follow ? 0 : wait
			}
			d.path.count = u8(n)
			w.n_platforms += 1
		case "pad":
			assert(w.n_pads < MAX_PADS, "friendslop: too many pads")
			w.pads[w.n_pads] = {
				vol    = {m.pos, level.prop_vec3(&m, "size", {0.75, 0.3, 0.75})},
				launch = level.prop_vec3(&m, "launch", {0, 12, 0}),
			}
			w.n_pads += 1
		case "bumper":
			assert(w.n_bumpers < MAX_BUMPERS, "friendslop: too many bumpers")
			w.bumpers[w.n_bumpers] = {
				vol      = {m.pos, level.prop_vec3(&m, "size", {0.6, 0.8, 0.6})},
				strength = level.prop_f32(&m, "strength", 9),
			}
			w.n_bumpers += 1
		case "checkpoint":
			assert(w.n_checkpoints < MAX_CHECKPOINTS, "friendslop: too many checkpoints")
			w.checkpoints[w.n_checkpoints] = {
				index = level.prop_int(&m, "index", w.n_checkpoints + 1),
				vol   = {m.pos, level.prop_vec3(&m, "size", {2, 2, 2})},
			}
			w.n_checkpoints += 1
		case "start":
			w.start = {m.pos, level.prop_vec3(&m, "size", {2, 2, 0.5})}
		case "finish":
			w.finish = {m.pos, level.prop_vec3(&m, "size", {1, 1, 1})}
		}
	}
	return w
}

world_destroy :: proc(w: ^World) {
	physics.destroy(w.phys)
	level.destroy(&w.lvl)
	delete(w.links)
	delete(w.hits)
	free(w)
}

// The tick-0 state: the hub, every item, platform and bell with its body; players join when present.
init :: proc(s: ^State, w: ^World, seed: u64) {
	s.phase = .Hub
	s.checkpoint = -1
	for i in 0 ..< w.n_items {
		s.items[i] = {
			body  = create_item_body(w, i),
			alive = true,
		}
	}
	for i in 0 ..< w.n_platforms {
		d := &w.platforms[i]
		bd := b3.DefaultBodyDef()
		bd.type = .kinematicBody
		bd.position = physics.v3(d.origin)
		bd.rotation = physics.quat(d.rot)
		bd.enableSleep = false
		id := b3.CreateBody(w.phys.id, &bd)
		sd := b3.DefaultShapeDef()
		sd.filter.categoryBits = CAT_PLATFORM
		sd.baseMaterial.userMaterialId = MAT_PLATFORM + u64(i)
		sd.baseMaterial.friction = 0.8
		h := b3.MakeBoxHull(d.half.x, d.half.y, d.half.z)
		b3.CreateHullShape(id, &sd, &h.base)
		s.platforms[i] = {
			body    = physics.ref_of(id),
			running = d.trigger < 0,
		}
	}
	for i in 0 ..< w.n_triggers {
		d := &w.triggers[i]
		if d.kind != .Bell do continue
		bd := b3.DefaultBodyDef()
		bd.position = physics.v3(d.vol.pos)
		id := b3.CreateBody(w.phys.id, &bd)
		sd := b3.DefaultShapeDef()
		sd.filter.categoryBits = CAT_TRIGGER
		sd.baseMaterial.userMaterialId = MAT_TRIGGER + u64(i)
		sd.enableHitEvents = true
		sp := b3.Sphere{{}, d.radius}
		b3.CreateSphereShape(id, &sd, &sp)
		s.bodies[i] = physics.ref_of(id)
	}
}

create_item_body :: proc(w: ^World, i: int) -> Body_Ref {
	d := &w.items[i]
	spec := &ITEM_SPECS[d.kind]
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.position = physics.v3(d.pos)
	bd.rotation = physics.quat(d.rot)
	id := b3.CreateBody(w.phys.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.filter.categoryBits = CAT_ITEM
	sd.baseMaterial.userMaterialId = MAT_ITEM + u64(i)
	sd.baseMaterial.friction = spec.friction
	sd.baseMaterial.restitution = spec.restitution
	sd.enableHitEvents = true
	if spec.half == {} {
		r := spec.radius
		sd.density = spec.mass / (4.0 / 3.0 * 3.1415927 * r * r * r)
		sp := b3.Sphere{{}, r}
		b3.CreateSphereShape(id, &sd, &sp)
	} else {
		hx, hy, hz := spec.half.x, spec.half.y, spec.half.z
		sd.density = spec.mass / (8 * hx * hy * hz)
		h := b3.MakeBoxHull(hx, hy, hz)
		b3.CreateHullShape(id, &sd, &h.base)
	}
	return physics.ref_of(id)
}

// The grab point `handle` of item i, in the item's local frame.
item_handle :: proc(kind: Item_Kind, handle: int) -> [3]f32 {
	spec := &ITEM_SPECS[kind]
	if spec.handles < 2 do return {}
	x := spec.half.x + 0.05
	return {handle == 0 ? -x : x, 0, 0}
}

in_volume :: proc(v: Volume, p: [3]f32) -> bool {
	d := p - v.pos
	return abs(d.x) <= v.half.x && abs(d.y) <= v.half.y && abs(d.z) <= v.half.z
}
