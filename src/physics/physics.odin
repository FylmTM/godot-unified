// The physics plug-in: a thin layer over Box3D (unified:b3). A World is one Box3D world set up for
// determinism (one worker by default, fixed creation order is the game's job) plus one saved image per ring slot; it
// plugs into the sim harness as Extra state (save/restore/hash/image/load). Bodies are referenced
// from the state block by Body_Ref, which leaves out Box3D's world index so the block is identical
// across the worlds of one process and across machines.
package physics

import "base:runtime"
import "core:sync"

import "unified:b3"
import "unified:sim"

// A body as stored in the block: Box3D's body index + 1 and generation. Zero: no body.
Body_Ref :: struct {
	index1:     i32,
	generation: u16,
	_pad:       u16,
}

// A body owned elsewhere (the platform a character stands on, a held item): same bits as Body_Ref, but
// not hashed and possibly stale (body_valid before use).
// (A struct of its own, not `distinct Body_Ref`: the RTTI walk must not see a Body_Ref in it.)
Body_Link :: struct {
	index1:     i32,
	generation: u16,
	_pad:       u16,
}

// A joint as stored in the block: Box3D's joint index + 1 and generation. Zero: no joint. Found by
// RTTI for check_refs, not hashed (a joint's effect shows in its bodies one tick later).
Joint_Ref :: struct {
	index1:     i32,
	generation: u16,
	_pad:       u16,
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

World :: struct {
	id:         b3.World_Id,
	// In-process snapshots (Box3D's world arena: a memcpy), one per ring slot.
	ring:       [sim.MAX_RING_SIZE]b3.World_Snapshot, // slots past the sim's ring_size stay empty
	scratch:    b3.World_Snapshot, // the live state while `image` builds a past slot's image, and `load`'s backup
	image:      ^b3.World_State, // the last portable image `image` built
	// Offsets of every Body_Ref / Joint_Ref in the state block, in memory order (the hash order).
	refs:       []int,
	joint_refs: []int,
	anchor:     b3.Body_Id, // Settings.anchor
	workers:    i32, // Box3D's worker count (Settings.workers, at least 1)
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
	b3.destroy_world_snapshot(&world.scratch)
	b3.destroy_world_state(world.image)
	b3.destroy_world(world.id)
	delete(world.refs)
	delete(world.joint_refs)
	free(world)
}

// Advances the world one tick: `substeps` solver substeps (games go through this, not b3World_Step).
step :: proc(world: ^World, dt: f32, substeps: int) {
	b3.world_step(world.id, dt, i32(substeps))
}

// The Box3D id of a body the block owns, in this world. A zero ref asserts: Box3D's release library doesn't
// validate ids, so it would index body -1 and corrupt memory.
body_id :: proc(world: ^World, ref: Body_Ref, loc := #caller_location) -> b3.Body_Id {
	assert(ref.index1 != 0, "physics: a zero Body_Ref (no body)", loc)
	return {index1 = ref.index1, world0 = world.id.index1 - 1, generation = ref.generation}
}

// The Box3D id of a linked body, in this world. Unchecked: the body may be gone (body_valid first).
link_id :: proc(world: ^World, body_link: Body_Link) -> b3.Body_Id {
	return {index1 = body_link.index1, world0 = world.id.index1 - 1, generation = body_link.generation}
}

// The Box3D id of a joint the block holds, in this world.
joint_id :: proc(world: ^World, joint_ref: Joint_Ref) -> b3.Joint_Id {
	return {index1 = joint_ref.index1, world0 = world.id.index1 - 1, generation = joint_ref.generation}
}

// The block's reference to a body Box3D made (the world index dropped, so blocks match across worlds).
ref_of :: proc "contextless" (id: b3.Body_Id) -> Body_Ref {
	return {index1 = id.index1, generation = id.generation}
}

// The link to a body Box3D made, for one the block doesn't own (query and hit results, grounds).
link_of :: proc "contextless" (id: b3.Body_Id) -> Body_Link {
	return {index1 = id.index1, generation = id.generation}
}

// The link to a body the block owns (for queries that skip it, holds, ...).
link :: proc "contextless" (ref: Body_Ref) -> Body_Link {
	return {index1 = ref.index1, generation = ref.generation}
}

// The block's reference to a joint Box3D made.
joint_ref_of :: proc "contextless" (id: b3.Joint_Id) -> Joint_Ref {
	return {index1 = id.index1, generation = id.generation}
}

// Whether a (possibly stale) link names a live body. A zero link is not valid. Box3D's generations are u16 and
// reused last-in-first-out, so a link 65,536 reuses old names a live body again (SPEC.md, known limits).
body_valid :: proc(world: ^World, body_link: Body_Link) -> bool {
	return body_link.index1 != 0 && b3.body_is_valid(link_id(world, body_link))
}

// Whether a (possibly stale) joint ref names a live joint (destroying a body destroys its joints). Zero is not valid.
joint_valid :: proc(world: ^World, joint_ref: Joint_Ref) -> bool {
	return joint_ref.index1 != 0 && b3.joint_is_valid(joint_id(world, joint_ref))
}

// Destroys the joint (if it is still alive: destroying a body destroys its joints) and clears the ref.
destroy_joint :: proc(world: ^World, joint_ref: ^Joint_Ref) {
	if joint_valid(world, joint_ref^) {
		b3.destroy_joint(joint_id(world, joint_ref^), true)
	}
	joint_ref^ = {}
}

// Creates a body from a Box3D definition and returns the block's reference to it. Box3D hands out indices in
// creation order, so a game creates the bodies its block owns in a fixed order; shapes go on with unified:b3
// (`body_id(world, ref)`) or the `*_2d` helpers.
create_body :: proc(world: ^World, def: ^b3.Body_Def) -> Body_Ref {
	return ref_of(b3.create_body(world.id, def))
}

// Destroys the body, if it is still alive, and clears the reference. Checked like destroy_joint: Box3D's release
// library doesn't check generations, so a stale ref would destroy whatever body reuses its index.
destroy_body :: proc(world: ^World, ref: ^Body_Ref) {
	if body_valid(world, link(ref^)) {
		b3.destroy_body(body_id(world, ref^))
	}
	ref^ = {}
}

// The Extra that makes the world part of the rollback state of a block of type State (the game passes it to the
// harness): saves, restores, hashes, images and loads the world. Every Body_Ref and Joint_Ref in State (fields,
// arrays, table items) is found once by RTTI, for check_refs.
extra :: proc(world: ^World, $State: typeid) -> sim.Extra {
	refs := make([dynamic]int)
	collect_refs(type_info_of(State), 0, &refs, Body_Ref)
	delete(world.refs)
	world.refs = refs[:]
	joint_refs := make([dynamic]int)
	collect_refs(type_info_of(State), 0, &joint_refs, Joint_Ref)
	delete(world.joint_refs)
	world.joint_refs = joint_refs[:]
	return {
		name = "physics",
		data = world,
		save = proc(data: rawptr, slot: int) {
			world := (^World)(data)
			b3.world_save_snapshot(world.id, &world.ring[slot])
		},
		restore = proc(data: rawptr, slot: int) -> bool {
			world := (^World)(data)
			return b3.world_restore_snapshot(world.id, &world.ring[slot])
		},
		// On the netcode's checksum ticks (sim.DEEP_CHECKSUM_EVERY): the whole world, every body, contact, warm
		// start, island and tree (the canonical image's hash). On other ticks: every awake body (id, pose and
		// velocities) and which bodies are awake, a fraction of the cost (tests and traces checksum every tick).
		hash = proc(data: rawptr, _: rawptr, tick: u32, out: ^[dynamic]u8) {
			world := (^World)(data)
			deep := tick % sim.DEEP_CHECKSUM_EVERY == 0
			hash := deep ? b3.world_hash_state(world.id) : b3.world_hash_awake_bodies(world.id)
			hash_bytes := transmute([8]u8)u64le(hash)
			append(out, ..hash_bytes[:])
		},
		// A portable image of the slot's tick, with its geometry (late join): the slot is put in the world for
		// the time it takes, then the live state is put back.
		image = proc(data: rawptr, slot: int) -> []u8 {
			world := (^World)(data)
			b3.world_save_snapshot(world.id, &world.scratch)
			b3.world_restore_snapshot(world.id, &world.ring[slot])
			size := b3.world_save_image(world.id, world.image, true)
			b3.world_restore_snapshot(world.id, &world.scratch)
			return b3.world_state_get_data(world.image)[:size]
		},
		// A corrupt image can be found halfway through the load and leave the world half-written, so the world is
		// saved first and put back on failure. Loads are rare (late join).
		load = proc(data: rawptr, bytes: []u8) -> bool {
			world := (^World)(data)
			b3.world_save_snapshot(world.id, &world.scratch)
			if b3.world_load_image(world.id, bytes) do return true
			b3.world_restore_snapshot(world.id, &world.scratch)
			return false
		},
	}
}

// Every Body_Ref and Joint_Ref in the block names a live body or joint (or is zero). Tests run it
// after every restore. Needs `extra(world, State)` first (it finds the refs).
check_refs :: proc(world: ^World, state: rawptr) -> bool {
	base := ([^]u8)(state)
	for offset in world.refs {
		ref := (^Body_Ref)(&base[offset])^
		if ref.index1 != 0 && !b3.body_is_valid(body_id(world, ref)) {
			return false
		}
	}
	for offset in world.joint_refs {
		ref := (^Joint_Ref)(&base[offset])^
		if ref.index1 != 0 && !b3.joint_is_valid(joint_id(world, ref)) {
			return false
		}
	}
	return true
}

// The offsets of every field of type `want` (a distinct type: Body_Link is not Body_Ref) in a type.
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
