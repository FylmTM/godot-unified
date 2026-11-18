// The physics plug-in (src/physics/SPEC.md): Box3D for games. A World is one Box3D world set up for determinism (one
// worker by default; a fixed creation order is the game's job) plus one saved snapshot per ring slot; it plugs into
// the sim harness as Extra state (save/restore/hash/image/load/check). Bodies, shapes and joints are referenced from
// the state block by refs, which leave out Box3D's world index so the block is identical across the worlds of one
// process and across machines. Games reach Box3D only through this package.
package physics

import "core:sync"

import box3d "box3d:bindings"
import "unified:sim"

// World options. Results are bit-identical for any worker count (unified-box3d tests it).
Settings :: struct {
	// Threads for Box3D's built-in scheduler; 0 or 1: none, the step runs on the caller's thread.
	workers:             i32,
	gravity:             Maybe([3]f32), // nil: Box3D's default
	hit_event_threshold: f32, // approach speed (m/s) above which contacts report hit events; 0: Box3D's default
}

// What physics keeps about a body, by body index, beside Box3D's state and rolled back with it: its tag, and whether
// it is alive and the World's (made before `extra`, so no ref in the block owns it).
Body_Entry :: struct {
	tag:   u64,
	flags: bit_set[Body_Flag;u8],
	_pad:  [7]u8,
}

Body_Flag :: enum u8 {
	Alive,
	World, // the World's: level geometry, the anchor, platforms made in world_create
}

World :: struct {
	id:          box3d.WorldId,
	// In-process snapshots (Box3D's world arena: a memcpy) and the body table, one per ring slot.
	ring:        [sim.MAX_RING_SIZE]box3d.WorldSnapshot, // slots past the sim's ring_size stay empty
	body_ring:   [sim.MAX_RING_SIZE][dynamic]Body_Entry,
	scratch:     box3d.WorldSnapshot, // the live state while `image` builds a past slot's image, and `load`'s backup
	image:       ^box3d.WorldState, // the last Box3D image `image` built
	image_bytes: [dynamic]u8, // the last portable image: Box3D's, then the body table
	bodies:      [dynamic]Body_Entry, // by body index (rolled back: body_ring)
	sealed:      bool, // `extra` was made: bodies created from now on are the block's
	refs:        Ref_Layout, // the State's (extra)
	layouts:     [dynamic]Type_Layout, // destroy_refs' cache (a few types: a list, no map in tick code)
	owned:       [dynamic]bool, // check_refs' scratch
	visitors:    [dynamic]box3d.ShapeId, // shape_sensor_data's scratch
	anchor:      box3d.BodyId, // the World's first body (world_anchor)
	workers:     i32, // Box3D's worker count (Settings.workers, at least 1)
}

// b3CreateWorld/b3DestroyWorld scan and modify Box3D's global world table and lazily initialise its
// contact registers, so worlds created from several threads (sessions, tests) are serialised.
@(private)
world_mutex: sync.Mutex

// Creates a world set up for determinism (Settings); `destroy` frees it. Mutex-guarded (Box3D's world table is global).
create :: proc(settings := Settings{}) -> ^World {
	world := new(World)
	sync.guard(&world_mutex)
	world_def := box3d.DefaultWorldDef()
	world.workers = max(1, settings.workers)
	world_def.workerCount = u32(world.workers)
	if gravity, ok := settings.gravity.?; ok {
		world_def.gravity = transmute(box3d.Vec3)gravity
	}
	if settings.hit_event_threshold > 0 {
		world_def.hitEventThreshold = settings.hit_event_threshold
	}
	world.id = box3d.CreateWorld(&world_def)
	// The static body joints attach to when they hold a body to the world (world_anchor; every character's): the
	// World's first body, body 0.
	anchor_def := box3d.DefaultBodyDef()
	anchor_def.name = "anchor"
	world.anchor = box3d.CreateBody(world.id, &anchor_def)
	body_created(world, world.anchor, 0)
	world.image = box3d.CreateWorldState()
	return world
}

// Destroys the world with its snapshots and image.
destroy :: proc(world: ^World) {
	sync.guard(&world_mutex)
	for &snapshot in world.ring {
		box3d.DestroyWorldSnapshot(&snapshot)
	}
	for &entries in world.body_ring {
		delete(entries)
	}
	box3d.DestroyWorldSnapshot(&world.scratch)
	box3d.DestroyWorldState(world.image)
	box3d.DestroyWorld(world.id)
	delete_layout(world.refs)
	for cached in world.layouts {
		delete_layout(cached.layout)
	}
	delete(world.layouts)
	delete(world.bodies)
	delete(world.owned)
	delete(world.visitors)
	delete(world.image_bytes)
	free(world)
}

// Advances the world one tick: `substeps` solver substeps (`t.dt` for `dt`).
step :: proc(world: ^World, dt: f32, substeps: int) {
	box3d.World_Step(world.id, dt, i32(substeps))
}

// The Extra that makes the world part of the rollback state of a block of type State: a physics game's Game.extra
// returns it (`extra = proc(world: ^World) -> sim.Extra {return physics.extra(world.phys, State)}`). It saves,
// restores, hashes, images, loads and checks the world. Every ref in State (fields, arrays, table items) is found
// once by RTTI, for check_refs. The harness asks for it right after world_create: the bodies made before (level
// geometry, the anchor, platforms) are the World's, every later one must be owned by a Body_Ref in the block.
extra :: proc(world: ^World, $State: typeid) -> sim.Extra {
	delete_layout(world.refs)
	world.refs = layout_of(type_info_of(State))
	world.sealed = true
	return {
		data = world,
		save = proc(data: rawptr, slot: int) {
			world := (^World)(data)
			box3d.World_SaveSnapshot(world.id, &world.ring[slot])
			entries := &world.body_ring[slot]
			resize(entries, len(world.bodies))
			copy(entries[:], world.bodies[:])
		},
		restore = proc(data: rawptr, slot: int) -> bool {
			world := (^World)(data)
			if !box3d.World_RestoreSnapshot(world.id, &world.ring[slot]) do return false
			resize(&world.bodies, len(world.body_ring[slot]))
			copy(world.bodies[:], world.body_ring[slot][:])
			return true
		},
		// On the netcode's checksum ticks (sim.DEEP_CHECKSUM_EVERY): the whole world, every body, contact, warm
		// start, island and tree (the canonical image's hash), and the body table. On other ticks: every awake body
		// (id, pose and velocities) and which bodies are awake, a fraction of the cost (tests and traces checksum
		// every tick).
		hash = proc(data: rawptr, tick: u32, out: ^[dynamic]u8) {
			world := (^World)(data)
			if tick % sim.DEEP_CHECKSUM_EVERY == 0 {
				hash_bytes := transmute([8]u8)u64le(box3d.World_HashState(world.id))
				append(out, ..hash_bytes[:])
				table := transmute([8]u8)u64le(sim.hash_bytes(entries_bytes(world.bodies[:])))
				append(out, ..table[:])
			} else {
				hash_bytes := transmute([8]u8)u64le(box3d.World_HashAwakeBodies(world.id))
				append(out, ..hash_bytes[:])
			}
		},
		// A portable image of the slot's tick (late join): Box3D's canonical image with its geometry (the slot is put
		// in the world for the time it takes, then the live state is put back), its size first, then the slot's
		// body table.
		image = proc(data: rawptr, slot: int) -> []u8 {
			world := (^World)(data)
			box3d.World_SaveSnapshot(world.id, &world.scratch)
			box3d.World_RestoreSnapshot(world.id, &world.ring[slot])
			size := box3d.World_SaveImage(world.id, world.image, true)
			box3d.World_RestoreSnapshot(world.id, &world.scratch)
			clear(&world.image_bytes)
			size_bytes := transmute([4]u8)u32le(u32(size))
			append(&world.image_bytes, ..size_bytes[:])
			append(
				&world.image_bytes,
				..(box3d.WorldState_GetData(world.image)[:box3d.WorldState_GetSize(world.image)])[:size],
			)
			append(&world.image_bytes, ..entries_bytes(world.body_ring[slot][:]))
			return world.image_bytes[:]
		},
		size = proc(data: rawptr, slot: int) -> int {
			world := (^World)(data)
			return world.ring[slot].size + len(world.body_ring[slot]) * size_of(Body_Entry)
		},
		// A corrupt image can be found halfway through the load and leave the world half-written, so the world is
		// saved first and put back on failure. Loads are rare (late join).
		load = proc(data: rawptr, bytes: []u8) -> bool {
			world := (^World)(data)
			if len(bytes) < 4 do return false
			size := int((^u32le)(raw_data(bytes))^)
			table := bytes[4:]
			if size > len(table) || (len(table) - size) % size_of(Body_Entry) != 0 do return false
			box3d.World_SaveSnapshot(world.id, &world.scratch)
			if !box3d.World_LoadImage(world.id, raw_data(table[:size]), i32(len(table[:size]))) {
				box3d.World_RestoreSnapshot(world.id, &world.scratch)
				return false
			}
			entries := table[size:]
			resize(&world.bodies, len(entries) / size_of(Body_Entry))
			copy(entries_bytes(world.bodies[:]), entries)
			return true
		},
		check = proc(data: rawptr, state: rawptr) -> string {
			return check_refs((^World)(data), state)
		},
	}
}

// The body table's entries as bytes (plain data, little-endian, padding zeroed by every write).
@(private)
entries_bytes :: proc(entries: []Body_Entry) -> []u8 {
	return ([^]u8)(raw_data(entries))[:len(entries) * size_of(Body_Entry)]
}
