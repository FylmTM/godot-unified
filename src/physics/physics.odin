// The physics plug-in (src/physics/README.md, The plug-in): Box3D for games. A World is one Box3D world set up for
// determinism (one worker by default; a fixed creation order is the game's job) plus one saved snapshot per ring slot;
// it plugs into the sim harness as Extra state (save/restore/hash/image/load/check). Bodies, shapes and joints are
// referenced from the state block by refs, which leave out Box3D's world index so the block is identical across the
// worlds of one process and across machines. Games reach Box3D only through this package.
package physics

import "core:sync"

import box3d "box3d:bindings"
import "unified:dmath"
import "unified:sim"

// World options. Results are bit-identical for any worker count (unified-box3d tests it).
Settings :: struct {
	tick_hz:             int, // the game's (Game.tick_hz; sim.create refuses another): a step is 1 / tick_hz seconds; required
	substeps:            int, // solver substeps per step; 0: 4
	// Threads for Box3D's built-in scheduler; 0 or 1: none, the step runs on the caller's thread.
	workers:             i32,
	gravity:             Maybe([3]f32), // nil: Box3D's default
	hit_event_threshold: f32, // approach speed (m/s) above which contacts report hit events; 0: Box3D's default
	// The edge (m) of the cubic cells a level's shapes are baked into compounds by (create_with_levels); 0:
	// LEVEL_CELL_DEFAULT. Smaller cells overlap fewer moving bodies; larger ones make fewer static bodies.
	level_cell:          f32,
}

// What physics keeps about a body, by body index, beside Box3D's state and rolled back with it: its tag, whether it is
// alive, who owns it when no ref in the block does (the World, or the active level), and its warp epoch.
Body_Entry :: struct {
	tag:        u64,
	flags:      bit_set[Body_Flag;u8],
	warp:       u8, // bumped by every teleport of the body (body_warp)
	generation: u16, // a level body's Box3D generation (level_change destroys it by it); 0 otherwise
	_pad2:      [4]u8,
}

// What a body is besides its tag (Body_Entry.flags).
Body_Flag :: enum u8 {
	Alive,
	World, // the World's: made before `extra` (the anchor, a game's own bodies made in world_create)
	Level, // the active level's static geometry (level_change)
}

// One physics world (create): the Box3D world, its snapshots per ring slot, and physics' table by body index. A game
// keeps it in its World (outside the block) and plugs it into the harness with `extra`.
World :: struct {
	id:              box3d.WorldId,
	tick_hz:         int, // Settings.tick_hz
	dt:              f32, // seconds per step: 1 / tick_hz, as the sim's Tick.dt
	substeps:        int,
	// In-process snapshots (Box3D's world arena: a memcpy) and the body table, one per ring slot.
	ring:            [sim.MAX_RING_SIZE]box3d.WorldSnapshot, // slots past the sim's ring_size stay empty
	body_ring:       [sim.MAX_RING_SIZE][dynamic]Body_Entry,
	scratch:         box3d.WorldSnapshot, // the live state while `image` builds a past slot's image, and `load`'s backup
	image:           ^box3d.WorldState, // the last Box3D image `image` built
	image_bytes:     [dynamic]u8, // the last portable image: Box3D's, then the body table
	// Kept ticks (sim.snapshot_keep): a ring slot's snapshot bytes and body table, copied, imaged only when wanted.
	kept:            [sim.KEEP_SLOTS][dynamic]u8,
	kept_bodies:     [sim.KEEP_SLOTS][dynamic]Body_Entry,
	bodies:          [dynamic]Body_Entry, // by body index (rolled back: body_ring)
	// Every body's Box3D generation by body index (body_created), so physics can name any body in the table
	// (world_cast_ray_closest_rewound). Rolled back with the table (generation_ring) but neither hashed nor imaged: it
	// says nothing the Box3D world doesn't, and a loaded image rebuilds it from the world's shapes (rebuild_generations).
	generations:     [dynamic]u16,
	generation_ring: [sim.MAX_RING_SIZE][dynamic]u16,
	sealed:          bool, // `extra` was made: bodies created from now on are the block's
	level_entered:   bool, // level_change ran (a world with levels steps only after one: step)
	refs:            Ref_Layout, // the State's (extra)
	layouts:         [dynamic]Type_Layout, // destroy_refs' cache (a few types: a list, no map in tick code)
	owned:           [dynamic]bool, // check_refs' scratch
	visitors:        [dynamic]box3d.ShapeId, // shape_sensor_data's scratch
	body_shapes:     [dynamic]box3d.ShapeId, // world_cast_ray_closest_rewound's scratch
	sort_scratch:    [dynamic]u64, // sort_results' merge buffer (any result type: words, for alignment)
	anchor:          box3d.BodyId, // the World's first body (world_anchor)
	workers:         i32, // Box3D's worker count (Settings.workers, at least 1)
	// The game's levels, parsed and built (create_with_levels), and the filter category of their shapes that have none.
	levels:          [dynamic]Baked_Level,
	level_category:  u64,
	level_cell:      f32, // Settings.level_cell, resolved
	level_hulls:     [dynamic]^Hull_Data, // what build_level_shape built (shapes point at it)
	level_meshes:    [dynamic]^Mesh_Data,
}

// b3CreateWorld/b3DestroyWorld scan and modify Box3D's global world table and lazily initialise its
// contact registers, so worlds created from several threads (sessions, tests) are serialised.
@(private)
world_mutex: sync.Mutex

// Creates a world set up for determinism (Settings); `destroy` frees it. Mutex-guarded (Box3D's world table is global).
create :: proc(settings := Settings{}) -> ^World {
	assert(settings.tick_hz > 0, "physics: Settings.tick_hz is the game's tick rate (Game.tick_hz)")
	world := new(World)
	world.tick_hz = settings.tick_hz
	world.dt = 1 / f32(settings.tick_hz)
	world.substeps = settings.substeps if settings.substeps > 0 else 4
	sync.guard(&world_mutex)
	world_def := box3d.DefaultWorldDef()
	world.workers = dmath.max(1, settings.workers)
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

// The portable image in world.image_bytes: the size of Box3D's image (`size` bytes of world.image), the image, then
// the body table `bodies`.
@(private)
image_bytes :: proc(world: ^World, size: i32, bodies: []Body_Entry) -> []u8 {
	clear(&world.image_bytes)
	size_bytes := transmute([4]u8)u32le(u32(size))
	append(&world.image_bytes, ..size_bytes[:])
	append(
		&world.image_bytes,
		..(box3d.WorldState_GetData(world.image)[:box3d.WorldState_GetSize(world.image)])[:size],
	)
	append(&world.image_bytes, ..entries_bytes(bodies))
	return world.image_bytes[:]
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
	for &generations in world.generation_ring {
		delete(generations)
	}
	box3d.DestroyWorldSnapshot(&world.scratch)
	box3d.DestroyWorldState(world.image)
	box3d.DestroyWorld(world.id)
	// The geometry the world's shapes pointed at, now that they are gone.
	for &baked in world.levels do unbake_level(&baked)
	delete(world.levels)
	for hull in world.level_hulls do destroy_hull(hull)
	delete(world.level_hulls)
	for mesh in world.level_meshes do destroy_mesh(mesh)
	delete(world.level_meshes)
	delete_layout(world.refs)
	for cached in world.layouts {
		delete_layout(cached.layout)
	}
	delete(world.layouts)
	delete(world.bodies)
	delete(world.owned)
	delete(world.visitors)
	delete(world.body_shapes)
	delete(world.generations)
	delete(world.sort_scratch)
	delete(world.image_bytes)
	for k in 0 ..< sim.KEEP_SLOTS {
		delete(world.kept[k])
		delete(world.kept_bodies[k])
	}
	free(world)
}

// Advances the world one tick (Settings: 1 / tick_hz seconds in `substeps` solver substeps). A world with levels
// (create_with_levels) steps only after its init entered one (asserted: else it runs with no static geometry).
step :: proc(world: ^World) {
	assert(
		world.level_entered || len(world.levels) == 0,
		"physics: the game has levels but its init entered none (physics.level_change(t, world, Level_Id.X))",
	)
	box3d.World_Step(world.id, world.dt, i32(world.substeps))
}

// The Extra that makes the world part of the rollback state of a block of type State: a physics game's Game.extra
// returns it (`extra = proc(world: ^World) -> sim.Extra {return physics.extra(world.phys, State)}`). It saves,
// restores, hashes, images, loads and checks the world. Every ref in State (fields, arrays, table items) is found
// once by RTTI, for check_refs. The harness asks for it right after world_create: the bodies made before (the
// anchor, a game's own) are the World's, the active level's are the level's (level_change), and every other one must
// be owned by a Body_Ref in the block.
extra :: proc(world: ^World, $State: typeid) -> sim.Extra {
	delete_layout(world.refs)
	world.refs = layout_of(type_info_of(State))
	world.sealed = true
	return {
		data = world,
		tick_hz = world.tick_hz,
		save = proc(data: rawptr, slot: int) {
			world := (^World)(data)
			box3d.World_SaveSnapshot(world.id, &world.ring[slot])
			entries := &world.body_ring[slot]
			resize(entries, len(world.bodies))
			copy(entries[:], world.bodies[:])
			generations := &world.generation_ring[slot]
			resize(generations, len(world.generations))
			copy(generations[:], world.generations[:])
		},
		restore = proc(data: rawptr, slot: int) -> bool {
			world := (^World)(data)
			if !box3d.World_RestoreSnapshot(world.id, &world.ring[slot]) do return false
			resize(&world.bodies, len(world.body_ring[slot]))
			copy(world.bodies[:], world.body_ring[slot][:])
			resize(&world.generations, len(world.generation_ring[slot]))
			copy(world.generations[:], world.generation_ring[slot][:])
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
		// A portable image of the slot's tick (late join, desync reports): Box3D's canonical image with its geometry,
		// its size first, then the slot's body table. When the world is not at the slot's tick (`live` false) the slot
		// is put in the world for the time it takes and the live state put back after: most of the cost.
		image = proc(data: rawptr, slot: int, live: bool) -> []u8 {
			world := (^World)(data)
			if !live {
				box3d.World_SaveSnapshot(world.id, &world.scratch)
				box3d.World_RestoreSnapshot(world.id, &world.ring[slot])
			}
			size := box3d.World_SaveImage(world.id, world.image, true)
			if !live {
				box3d.World_RestoreSnapshot(world.id, &world.scratch)
			}
			return image_bytes(world, size, world.body_ring[slot][:])
		},
		// A ring slot's save copied aside (two memcpys), for an image later (image_kept).
		keep = proc(data: rawptr, slot: int, index: int) {
			world := (^World)(data)
			snapshot := &world.ring[slot]
			resize(&world.kept[index], snapshot.size)
			copy(world.kept[index][:], snapshot.data[:snapshot.size])
			resize(&world.kept_bodies[index], len(world.body_ring[slot]))
			copy(world.kept_bodies[index][:], world.body_ring[slot][:])
		},
		// A kept copy's image, as `image` of the slot it was kept from: the copy is put in the world for the time it
		// takes (Box3D's restore only reads the snapshot's bytes) and the live state put back after.
		image_kept = proc(data: rawptr, index: int) -> []u8 {
			world := (^World)(data)
			kept := box3d.WorldSnapshot {
				data     = raw_data(world.kept[index]),
				size     = len(world.kept[index]),
				capacity = len(world.kept[index]),
			}
			box3d.World_SaveSnapshot(world.id, &world.scratch)
			box3d.World_RestoreSnapshot(world.id, &kept)
			size := box3d.World_SaveImage(world.id, world.image, true)
			box3d.World_RestoreSnapshot(world.id, &world.scratch)
			return image_bytes(world, size, world.kept_bodies[index][:])
		},
		size = proc(data: rawptr, slot: int) -> int {
			world := (^World)(data)
			return(
				world.ring[slot].size +
				len(world.body_ring[slot]) * size_of(Body_Entry) +
				len(world.generation_ring[slot]) * size_of(u16) \
			)
		},
		// A corrupt image can be found halfway through the load and leave the world half-written, so the world is
		// saved first and put back on failure. Loads are rare (late join). The body table comes from another machine
		// too: an entry with unknown flags or padding, a dead entry that isn't zero, or a level body Box3D doesn't
		// hold (level_change would destroy it by its index) refuses the image, never a crash later.
		load = proc(data: rawptr, bytes: []u8) -> bool {
			world := (^World)(data)
			if len(bytes) < 4 do return false
			size := int((^u32le)(raw_data(bytes))^)
			table := bytes[4:]
			if size > len(table) || (len(table) - size) % size_of(Body_Entry) != 0 do return false
			entries := make([]Body_Entry, (len(table) - size) / size_of(Body_Entry), context.temp_allocator)
			copy(entries_bytes(entries), table[size:])
			box3d.World_SaveSnapshot(world.id, &world.scratch)
			if !box3d.World_LoadImage(world.id, raw_data(table[:size]), i32(len(table[:size]))) ||
			   !entries_valid(world, entries) {
				box3d.World_RestoreSnapshot(world.id, &world.scratch)
				return false
			}
			resize(&world.bodies, len(entries))
			copy(world.bodies[:], entries)
			rebuild_generations(world)
			return true
		},
		check = proc(data: rawptr, state: rawptr) -> string {
			return check_refs((^World)(data), state)
		},
	}
}

// The generations of a loaded world's bodies, from its shapes (a loaded image holds Box3D's ids, physics' table holds
// no generation but a level body's): every shape a query can find names its body. A body without one keeps 0, which
// names no live body; no ray can hit it.
@(private)
rebuild_generations :: proc(world: ^World) {
	clear(&world.generations)
	resize(&world.generations, len(world.bodies))
	every := box3d.QueryFilter {
		categoryBits = max(u64),
		maskBits     = max(u64),
	}
	bounds := box3d.World_GetBounds(world.id)
	box3d.World_OverlapAABB(world.id, bounds, every, proc "c" (shape: box3d.ShapeId, user: rawptr) -> bool {
			world := (^World)(user)
			body := box3d.Shape_GetBody(shape)
			index := int(body.index1) - 1
			if index >= 0 && index < len(world.generations) do world.generations[index] = body.generation
			return true
		}, world)
}

// Whether a loaded body table fits the loaded Box3D world (the image's load): known flags, zero padding, a dead entry
// zero, every level body a static body alive in Box3D at its generation. (One the block also owns: check_refs.)
@(private)
entries_valid :: proc(world: ^World, entries: []Body_Entry) -> bool {
	for entry, index in entries {
		if transmute(u8)entry.flags >> len(Body_Flag) != 0 || entry._pad2 != {} { 	// a bit of no flag, padding
			return false
		}
		if .Alive not_in entry.flags {
			if entry != {} do return false
			continue
		}
		if .Level not_in entry.flags do continue
		id := body_id(world, Body_Ref{index1 = i32(index + 1), generation = entry.generation})
		if !box3d.Body_IsValid(id) || box3d.Body_GetType(id) != .staticBody do return false
	}
	return true
}

// The body table's entries as bytes (plain data, little-endian, padding zeroed by every write).
@(private)
entries_bytes :: proc(entries: []Body_Entry) -> []u8 {
	return ([^]u8)(raw_data(entries))[:len(entries) * size_of(Body_Entry)]
}
