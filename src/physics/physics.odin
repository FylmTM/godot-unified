// The physics plug-in (src/physics/SPEC.md): Box3D for games. A World is one Box3D world set up for determinism (one
// worker by default; a fixed creation order is the game's job) plus one saved snapshot per ring slot; it plugs into
// the sim harness as Extra state (save/restore/hash/image/load/check). Bodies, shapes and joints are referenced from
// the state block by refs, which leave out Box3D's world index so the block is identical across the worlds of one
// process and across machines. Games reach Box3D only through this package (`unified:b3` is its implementation).
package physics

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:sync"

import "unified:b3"
import "unified:sim"

// A body as stored in the block, which owns it: Box3D's body index + 1 and generation. Zero: no body. Accessors trust
// it (check_refs covers the block's).
Body_Ref :: struct {
	index1:     i32,
	generation: u16,
	_pad:       u16,
}

// A body owned elsewhere (the platform a character stands on, a held item, a query's hit): same bits as Body_Ref,
// but possibly stale: resolve(world, link) checks it and gives a ref to use now.
// (A struct of its own, not `distinct Body_Ref`: the RTTI walk must not see a Body_Ref in it.)
Body_Link :: struct {
	index1:     i32,
	generation: u16,
	_pad:       u16,
}

// A shape: Box3D's shape index + 1 and generation. Destroyed with its body. Results carry the shape they hit.
Shape_Ref :: struct {
	index1:     i32,
	generation: u16,
	_pad:       u16,
}

// A joint of any type: Box3D's joint index + 1 and generation. Zero: no joint. The block holds the typed refs below;
// an untyped one (body_joints' results) converts with joint_as. Found by RTTI for check_refs, not hashed (a joint's
// effect shows in its bodies one tick later).
Joint_Ref :: struct {
	index1:     i32,
	generation: u16,
	_pad:       u16,
}

// One ref type per Box3D joint type, so a setter of another type does not compile (the release library doesn't
// check a joint's type). Each is a Joint_Ref (`using`): the generic joint procs take any of them.
Distance_Joint_Ref :: struct {
	using joint: Joint_Ref,
}
Filter_Joint_Ref :: struct {
	using joint: Joint_Ref,
}
Motor_Joint_Ref :: struct {
	using joint: Joint_Ref,
}
Mover_Joint_Ref :: struct {
	using joint: Joint_Ref,
}
Parallel_Joint_Ref :: struct {
	using joint: Joint_Ref,
}
Pogo_Joint_Ref :: struct {
	using joint: Joint_Ref,
}
Prismatic_Joint_Ref :: struct {
	using joint: Joint_Ref,
}
Revolute_Joint_Ref :: struct {
	using joint: Joint_Ref,
}
Spherical_Joint_Ref :: struct {
	using joint: Joint_Ref,
}
Weld_Joint_Ref :: struct {
	using joint: Joint_Ref,
}
Wheel_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// World options. Results are bit-identical for any worker count (unified-box3d tests it).
Settings :: struct {
	// Threads for Box3D's built-in scheduler; 0 or 1: none, the step runs on the caller's thread.
	workers:       i32,
	gravity:       Maybe([3]f32), // nil: Box3D's default
	hit_threshold: f32, // approach speed (m/s) above which contacts report hit events; 0: Box3D's default
	// Create the static anchor body characters attach their joints to (it is created first, so it
	// shifts the indices of every body created after it).
	anchor:        bool,
}

// What physics keeps about a body, by body index, beside Box3D's state and rolled back with it: its tag, and whether
// it is alive and the World's (made before `extra`, so no ref in the block owns it).
Body_Entry :: struct {
	tag:        u64,
	generation: u16,
	flags:      bit_set[Body_Flag;u8],
	_pad:       [5]u8,
}

Body_Flag :: enum u8 {
	Alive,
	World, // the World's: level geometry, the anchor, platforms made in world_create
}

// A type's ref layout, cached by destroy_refs.
Type_Layout :: struct {
	type:   typeid,
	layout: Ref_Layout,
}

// Where a type's refs are (byte offsets), found by RTTI once per type.
Ref_Layout :: struct {
	bodies: []int,
	shapes: []int,
	joints: []int, // typed or not: each starts with a Joint_Ref
}

World :: struct {
	id:          b3.World_Id,
	// In-process snapshots (Box3D's world arena: a memcpy) and the body table, one per ring slot.
	ring:        [sim.MAX_RING_SIZE]b3.World_Snapshot, // slots past the sim's ring_size stay empty
	body_ring:   [sim.MAX_RING_SIZE][dynamic]Body_Entry,
	scratch:     b3.World_Snapshot, // the live state while `image` builds a past slot's image, and `load`'s backup
	image:       ^b3.World_State, // the last Box3D image `image` built
	image_bytes: [dynamic]u8, // the last portable image: Box3D's, then the body table
	bodies:      [dynamic]Body_Entry, // by body index (rolled back: body_ring)
	sealed:      bool, // `extra` was made: bodies created from now on are the block's
	refs:        Ref_Layout, // the State's (extra)
	layouts:     [dynamic]Type_Layout, // destroy_refs' cache (a few types: a list, no map in tick code)
	owned:       [dynamic]bool, // check_refs' scratch
	visitors:    [dynamic]b3.Shape_Id, // shape_sensor_data's scratch
	anchor:      b3.Body_Id, // Settings.anchor
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
	world_def := b3.default_world_def()
	world.workers = max(1, settings.workers)
	world_def.worker_count = u32(world.workers)
	if gravity, ok := settings.gravity.?; ok {
		world_def.gravity = gravity
	}
	if settings.hit_threshold > 0 {
		world_def.hit_event_threshold = settings.hit_threshold
	}
	world.id = b3.create_world(&world_def)
	if settings.anchor {
		body_def := b3.default_body_def()
		body_def.name = "anchor"
		world.anchor = b3.create_body(world.id, &body_def)
		body_created(world, world.anchor, 0)
	}
	world.image = b3.create_world_state()
	return world
}

// Destroys the world with its snapshots and image.
destroy :: proc(world: ^World) {
	sync.guard(&world_mutex)
	for &snapshot in world.ring {
		b3.destroy_world_snapshot(&snapshot)
	}
	for &entries in world.body_ring {
		delete(entries)
	}
	b3.destroy_world_snapshot(&world.scratch)
	b3.destroy_world_state(world.image)
	b3.destroy_world(world.id)
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

@(private)
delete_layout :: proc(layout: Ref_Layout) {
	delete(layout.bodies)
	delete(layout.shapes)
	delete(layout.joints)
}

// Advances the world one tick: `substeps` solver substeps (`t.dt` for `dt`).
step :: proc(world: ^World, dt: f32, substeps: int) {
	b3.world_step(world.id, dt, i32(substeps))
}

// ---- refs and ids

// The Box3D id of a body the block owns, in this world (the library's and tests/b3's; games use the body_* procs). A
// zero ref asserts: Box3D's release library doesn't validate ids, so it would index body -1 and corrupt memory.
body_id :: proc(world: ^World, ref: Body_Ref, loc := #caller_location) -> b3.Body_Id {
	assert(ref.index1 != 0, "physics: a zero Body_Ref (no body)", loc)
	return {index1 = ref.index1, world0 = world.id.index1 - 1, generation = ref.generation}
}

// The Box3D id of a linked body, in this world. Unchecked: the body may be gone (resolve first).
link_id :: proc(world: ^World, body_link: Body_Link) -> b3.Body_Id {
	return {index1 = body_link.index1, world0 = world.id.index1 - 1, generation = body_link.generation}
}

// The Box3D id of a shape, in this world.
shape_id :: proc(world: ^World, shape: Shape_Ref) -> b3.Shape_Id {
	return {index1 = shape.index1, world0 = world.id.index1 - 1, generation = shape.generation}
}

// The Box3D id of a joint (any joint ref), in this world.
joint_id :: proc(
	world: ^World,
	joint: $J,
) -> b3.Joint_Id where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return {index1 = joint.index1, world0 = world.id.index1 - 1, generation = joint.generation}
}

// The block's reference to a body Box3D made (the world index dropped, so blocks match across worlds).
ref_of :: proc "contextless" (id: b3.Body_Id) -> Body_Ref {
	return {index1 = id.index1, generation = id.generation}
}

// The link to a body Box3D made, for one the block doesn't own (query and event results, grounds).
link_of :: proc "contextless" (id: b3.Body_Id) -> Body_Link {
	return {index1 = id.index1, generation = id.generation}
}

// The link to a body the block owns (for queries that skip it, joints, holds, ...).
link :: proc "contextless" (ref: Body_Ref) -> Body_Link {
	return {index1 = ref.index1, generation = ref.generation}
}

// The ref of a shape Box3D made.
shape_ref_of :: proc "contextless" (id: b3.Shape_Id) -> Shape_Ref {
	return {index1 = id.index1, generation = id.generation}
}

// The untyped ref of a joint Box3D made.
joint_ref_of :: proc "contextless" (id: b3.Joint_Id) -> Joint_Ref {
	return {index1 = id.index1, generation = id.generation}
}

// Whether a (possibly stale) link names a live body. A zero link is not valid. Box3D's generations are u16 and
// reused last-in-first-out, so a link 65,536 reuses old names a live body again (SPEC.md, known limits).
body_valid :: proc(world: ^World, body_link: Body_Link) -> bool {
	return body_link.index1 != 0 && b3.body_is_valid(link_id(world, body_link))
}

// A ref to use now for a (possibly stale) link: not ok when the body is gone. Never keep it in the block (the block
// owns what its Body_Refs name; a link's body is someone else's).
resolve :: proc(world: ^World, body_link: Body_Link) -> (ref: Body_Ref, ok: bool) {
	if !body_valid(world, body_link) do return {}, false
	return {index1 = body_link.index1, generation = body_link.generation}, true
}

// Whether a shape ref names a live shape. Zero is not valid.
shape_valid :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return shape.index1 != 0 && b3.shape_is_valid(shape_id(world, shape))
}

// Whether a (possibly stale) joint ref names a live joint (destroying a body destroys its joints). Zero is not valid.
joint_valid :: proc(
	world: ^World,
	joint: $J,
) -> bool where J == Joint_Ref ||
	intrinsics.type_is_subtype_of(J, Joint_Ref) {
	return joint.index1 != 0 && b3.joint_is_valid(joint_id(world, joint))
}

// Destroys the joint (if it is still alive: destroying a body destroys its joints) and clears the ref.
destroy_joint :: proc(world: ^World, joint: ^$J) where J == Joint_Ref || intrinsics.type_is_subtype_of(J, Joint_Ref) {
	if joint_valid(world, joint^) {
		b3.destroy_joint(joint_id(world, joint^), true)
	}
	joint^ = {}
}

// Creates a body from a definition and returns the block's reference to it, tagged `tag` (the game's: an entity's
// handle_key, a player's player_key; every query and event reports it). Box3D hands out indices in creation order,
// so a game creates the bodies its block owns in a fixed order. The def's user_data stays unset (a pointer); a name
// is copied into the world (its state: hashed, imaged).
create_body :: proc(world: ^World, def: ^Body_Def, tag: u64 = 0, loc := #caller_location) -> Body_Ref {
	assert(def.user_data == nil, "physics: a body def's user_data stays unset (a pointer in rollback state)", loc)
	id := b3.create_body(world.id, def)
	body_created(world, id, tag)
	return ref_of(id)
}

// Destroys the body (its shapes and joints with it), if it is still alive, and clears the reference. Checked: Box3D's
// release library doesn't check generations, so a stale ref would destroy whatever body reuses its index.
destroy_body :: proc(world: ^World, ref: ^Body_Ref) {
	if body_valid(world, link(ref^)) {
		b3.destroy_body(body_id(world, ref^))
		if int(ref.index1) <= len(world.bodies) do world.bodies[ref.index1 - 1] = {}
	}
	ref^ = {}
}

// A body's tag (create_body's; 0 when untagged or gone).
body_tag :: proc(world: ^World, ref: Body_Ref) -> u64 {
	return tag_of(world, ref.index1)
}

// Retags a body.
body_set_tag :: proc(world: ^World, ref: Body_Ref, tag: u64) {
	if int(ref.index1) > len(world.bodies) do resize(&world.bodies, int(ref.index1))
	world.bodies[ref.index1 - 1].tag = tag
}

// Records a body physics made (every body is made through physics: create_body, the character, the level).
@(private)
body_created :: proc(world: ^World, id: b3.Body_Id, tag: u64) {
	index := int(id.index1) - 1
	if index >= len(world.bodies) do resize(&world.bodies, index + 1)
	world.bodies[index] = {
		tag        = tag,
		generation = id.generation,
		flags      = world.sealed ? {.Alive} : {.Alive, .World},
	}
}

@(private)
tag_of :: proc(world: ^World, index1: i32) -> u64 {
	index := int(index1) - 1
	return world.bodies[index].tag if index >= 0 && index < len(world.bodies) else 0
}

// ---- items: freeing what a value refers to

// Destroys every joint and body a plain value (a table item, a player's data) refers to, and zeroes those refs and
// its shape refs: joints first, then bodies (their shapes go with them). The value's layout is found by RTTI once.
destroy_refs :: proc(world: ^World, value: ^$T) {
	layout: Ref_Layout
	found := false
	for cached in world.layouts {
		if cached.type == T {
			layout, found = cached.layout, true
			break
		}
	}
	if !found {
		layout = layout_of(type_info_of(T))
		append(&world.layouts, Type_Layout{T, layout})
	}
	base := ([^]u8)(value)
	for offset in layout.joints {
		destroy_joint(world, (^Joint_Ref)(&base[offset]))
	}
	for offset in layout.bodies {
		destroy_body(world, (^Body_Ref)(&base[offset]))
	}
	for offset in layout.shapes {
		(^Shape_Ref)(&base[offset])^ = {}
	}
}

// Frees a table item and everything physics it refers to (destroy_refs, then sim.despawn); false when the handle is
// stale.
despawn :: proc(world: ^World, table: ^sim.Table($T, $N), handle: sim.Handle(T)) -> bool {
	item := sim.get(table, handle)
	if item == nil do return false
	destroy_refs(world, item)
	return sim.despawn(table, handle)
}

// Despawns every item of a table and frees what physics each refers to (destroy_refs, then sim.despawn_all).
despawn_all :: proc(world: ^World, table: ^sim.Table($T, $N)) {
	items := sim.iterate(table)
	for item in sim.next(&items) do destroy_refs(world, item)
	sim.despawn_all(table)
}

// ---- the plug-in

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
			b3.world_save_snapshot(world.id, &world.ring[slot])
			entries := &world.body_ring[slot]
			resize(entries, len(world.bodies))
			copy(entries[:], world.bodies[:])
		},
		restore = proc(data: rawptr, slot: int) -> bool {
			world := (^World)(data)
			if !b3.world_restore_snapshot(world.id, &world.ring[slot]) do return false
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
				hash_bytes := transmute([8]u8)u64le(b3.world_hash_state(world.id))
				append(out, ..hash_bytes[:])
				table := transmute([8]u8)u64le(sim.hash_bytes(entries_bytes(world.bodies[:])))
				append(out, ..table[:])
			} else {
				hash_bytes := transmute([8]u8)u64le(b3.world_hash_awake_bodies(world.id))
				append(out, ..hash_bytes[:])
			}
		},
		// A portable image of the slot's tick (late join): Box3D's canonical image with its geometry (the slot is put
		// in the world for the time it takes, then the live state is put back), its size first, then the slot's
		// body table.
		image = proc(data: rawptr, slot: int) -> []u8 {
			world := (^World)(data)
			b3.world_save_snapshot(world.id, &world.scratch)
			b3.world_restore_snapshot(world.id, &world.ring[slot])
			size := b3.world_save_image(world.id, world.image, true)
			b3.world_restore_snapshot(world.id, &world.scratch)
			clear(&world.image_bytes)
			size_bytes := transmute([4]u8)u32le(u32(size))
			append(&world.image_bytes, ..size_bytes[:])
			append(&world.image_bytes, ..b3.world_state_get_data(world.image)[:size])
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
			b3.world_save_snapshot(world.id, &world.scratch)
			if !b3.world_load_image(world.id, table[:size]) {
				b3.world_restore_snapshot(world.id, &world.scratch)
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

// "" when every body, shape and joint ref in the block names something alive (or is zero) and no body is an orphan
// (alive, not the World's, and owned by no Body_Ref in the block: a despawn that forgot its body); else the first
// problem. The Extra's check, so scenarios.rollback_every_tick runs it after every restore. Needs `extra` first.
check_refs :: proc(world: ^World, state: rawptr) -> string {
	base := ([^]u8)(state)
	resize(&world.owned, len(world.bodies))
	for &owned in world.owned do owned = false
	for offset in world.refs.bodies {
		ref := (^Body_Ref)(&base[offset])^
		if ref.index1 == 0 do continue
		if !b3.body_is_valid(body_id(world, ref)) {
			return fmt.tprintf("the Body_Ref at block offset %d (body %d) names no live body", offset, ref.index1 - 1)
		}
		if int(ref.index1) > len(world.owned) do resize(&world.owned, int(ref.index1))
		world.owned[ref.index1 - 1] = true
	}
	for offset in world.refs.shapes {
		ref := (^Shape_Ref)(&base[offset])^
		if ref.index1 != 0 && !shape_valid(world, ref) {
			return fmt.tprintf("the Shape_Ref at block offset %d names no live shape", offset)
		}
	}
	for offset in world.refs.joints {
		ref := (^Joint_Ref)(&base[offset])^
		if ref.index1 != 0 && !joint_valid(world, ref) {
			return fmt.tprintf("the joint ref at block offset %d names no live joint", offset)
		}
	}
	for entry, index in world.bodies {
		if .Alive in entry.flags && .World not_in entry.flags && !world.owned[index] {
			return fmt.tprintf(
				"body %d (tag %d) is an orphan: alive, but no Body_Ref in the block owns it (physics.despawn or destroy_refs frees an item's bodies)",
				index,
				entry.tag,
			)
		}
	}
	return ""
}

// The offsets of a type's body, shape and joint refs.
@(private)
layout_of :: proc(type_info: ^runtime.Type_Info) -> Ref_Layout {
	bodies, shapes, joints: [dynamic]int
	collect_refs(type_info, 0, &bodies, Body_Ref)
	collect_refs(type_info, 0, &shapes, Shape_Ref)
	collect_refs(type_info, 0, &joints, Joint_Ref)
	return {bodies[:], shapes[:], joints[:]}
}

// The offsets of every field of type `want` (a distinct type: Body_Link is not Body_Ref) in a type. A typed joint ref
// holds a Joint_Ref at its start, so collecting Joint_Ref finds every joint.
@(private)
collect_refs :: proc(type_info: ^runtime.Type_Info, base: int, out: ^[dynamic]int, want: typeid) {
	if type_info.id == want {
		append(out, base)
		return
	}
	#partial switch variant in type_info.variant {
	case runtime.Type_Info_Named:
		collect_refs(variant.base, base, out, want)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(variant.field_count) {
			collect_refs(variant.types[i], base + int(variant.offsets[i]), out, want)
		}
	case runtime.Type_Info_Array:
		if !contains_ref(variant.elem, want) {
			return
		}
		for k in 0 ..< variant.count {
			collect_refs(variant.elem, base + k * variant.elem_size, out, want)
		}
	case runtime.Type_Info_Enumerated_Array:
		if !contains_ref(variant.elem, want) {
			return
		}
		for k in 0 ..< variant.count {
			collect_refs(variant.elem, base + k * variant.elem_size, out, want)
		}
	}
}

@(private)
contains_ref :: proc(type_info: ^runtime.Type_Info, want: typeid) -> bool {
	if type_info.id == want {
		return true
	}
	#partial switch variant in type_info.variant {
	case runtime.Type_Info_Named:
		return contains_ref(variant.base, want)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(variant.field_count) {
			if contains_ref(variant.types[i], want) {
				return true
			}
		}
	case runtime.Type_Info_Array:
		return contains_ref(variant.elem, want)
	case runtime.Type_Info_Enumerated_Array:
		return contains_ref(variant.elem, want)
	}
	return false
}
