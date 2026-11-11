// The physics plug-in: a thin layer over Box3D (unified:b3). A World is one Box3D world set up for
// determinism (one worker by default, fixed creation order is the game's job) plus RING saved images; it
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

// A body owned elsewhere (the platform a mover stands on, a held item): same bits as Body_Ref, but
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
	// Create the static anchor body movers attach their joints to (it is created first, so it
	// shifts the indices of every body created after it).
	anchor:        bool,
}

World :: struct {
	id:         b3.World_Id,
	// In-process snapshots (Box3D's world arena: a memcpy), one per ring slot.
	ring:       [sim.RING]b3.World_Snapshot,
	scratch:    b3.World_Snapshot, // the live state while `image` builds a past slot's image, and `load`'s backup
	image:      ^b3.World_State, // the last portable image `image` built
	// Offsets of every Body_Ref / Joint_Ref in the state block, in memory order (the hash order).
	refs:       []int,
	joint_refs: []int,
	anchor:     b3.Body_Id, // Settings.anchor
}

// b3CreateWorld/b3DestroyWorld scan and modify Box3D's global world table and lazily initialise its
// contact registers, so worlds created from several threads (sessions, tests) are serialised.
@(private)
world_mutex: sync.Mutex

create :: proc(settings := Settings{}) -> ^World {
	w := new(World)
	sync.guard(&world_mutex)
	wd := b3.default_world_def()
	wd.worker_count = u32(max(1, settings.workers))
	if g, ok := settings.gravity.?; ok {
		wd.gravity = g
	}
	if settings.hit_threshold > 0 {
		wd.hit_event_threshold = settings.hit_threshold
	}
	w.id = b3.create_world(&wd)
	if settings.anchor {
		bd := b3.default_body_def()
		bd.name = "anchor"
		w.anchor = b3.create_body(w.id, &bd)
	}
	w.image = b3.create_world_state()
	return w
}

destroy :: proc(w: ^World) {
	sync.guard(&world_mutex)
	for &r in w.ring {
		b3.destroy_world_snapshot(&r)
	}
	b3.destroy_world_snapshot(&w.scratch)
	b3.destroy_world_state(w.image)
	b3.destroy_world(w.id)
	delete(w.refs)
	delete(w.joint_refs)
	free(w)
}

// A zero ref asserts: Box3D (built without its validation) would index body -1 and corrupt memory.
// Advances the world one tick: `substeps` solver substeps (games go through this, not b3World_Step).
step :: proc(w: ^World, dt: f32, substeps: int) {
	b3.world_step(w.id, dt, i32(substeps))
}

body_id :: proc(w: ^World, r: Body_Ref, loc := #caller_location) -> b3.Body_Id {
	assert(r.index1 != 0, "physics: a zero Body_Ref (no body)", loc)
	return {index1 = r.index1, world0 = w.id.index1 - 1, generation = r.generation}
}

link_id :: proc(w: ^World, l: Body_Link) -> b3.Body_Id {
	return {index1 = l.index1, world0 = w.id.index1 - 1, generation = l.generation}
}

joint_id :: proc(w: ^World, r: Joint_Ref) -> b3.Joint_Id {
	return {index1 = r.index1, world0 = w.id.index1 - 1, generation = r.generation}
}

ref_of :: proc "contextless" (id: b3.Body_Id) -> Body_Ref {
	return {index1 = id.index1, generation = id.generation}
}

link_of :: proc "contextless" (id: b3.Body_Id) -> Body_Link {
	return {index1 = id.index1, generation = id.generation}
}

// The link to a body the block owns (for queries that skip it, holds, ...).
link :: proc "contextless" (r: Body_Ref) -> Body_Link {
	return {index1 = r.index1, generation = r.generation}
}

joint_ref_of :: proc "contextless" (id: b3.Joint_Id) -> Joint_Ref {
	return {index1 = id.index1, generation = id.generation}
}

// Whether a (possibly stale) link names a live body. A zero link is not valid.
body_valid :: proc(w: ^World, l: Body_Link) -> bool {
	return l.index1 != 0 && b3.body_is_valid(link_id(w, l))
}

joint_valid :: proc(w: ^World, r: Joint_Ref) -> bool {
	return r.index1 != 0 && b3.joint_is_valid(joint_id(w, r))
}

// Destroys the joint (if it is still alive: destroying a body destroys its joints) and clears the ref.
destroy_joint :: proc(w: ^World, r: ^Joint_Ref) {
	if joint_valid(w, r^) {
		b3.destroy_joint(joint_id(w, r^), true)
	}
	r^ = {}
}

// Destroys the body and clears the reference.
destroy_body :: proc(w: ^World, r: ^Body_Ref) {
	if r.index1 != 0 {
		b3.destroy_body(body_id(w, r^))
	}
	r^ = {}
}

// The Extra that makes the world part of the rollback state of a block of type S: every Body_Ref
// in S (fields, arrays, table items) is found once by RTTI; the checksum covers each referenced
// body (position, rotation, linear and angular velocity) in the block's memory order.
extra :: proc(w: ^World, $S: typeid) -> sim.Extra {
	refs := make([dynamic]int)
	collect_refs(type_info_of(S), 0, &refs, Body_Ref)
	delete(w.refs)
	w.refs = refs[:]
	jrefs := make([dynamic]int)
	collect_refs(type_info_of(S), 0, &jrefs, Joint_Ref)
	delete(w.joint_refs)
	w.joint_refs = jrefs[:]
	return {
		name = "physics",
		data = w,
		save = proc(data: rawptr, slot: int) {
			w := (^World)(data)
			b3.world_save_snapshot(w.id, &w.ring[slot])
		},
		restore = proc(data: rawptr, slot: int) -> bool {
			w := (^World)(data)
			return b3.world_restore_snapshot(w.id, &w.ring[slot])
		},
		// On the netcode's checksum ticks (sim.DEEP_CHECKSUM_EVERY): the whole world, every body, contact, warm
		// start, island and tree (the canonical image's hash). On other ticks: the referenced bodies' poses and
		// velocities, in the block's order (cheap; tests and traces checksum every tick).
		hash = proc(data: rawptr, state: rawptr, tick: u32, out: ^[dynamic]u8) {
			w := (^World)(data)
			if tick % sim.DEEP_CHECKSUM_EVERY == 0 {
				h := transmute([8]u8)u64le(b3.world_hash_state(w.id))
				append(out, ..h[:])
				return
			}
			base := ([^]u8)(state)
			for off in w.refs {
				r := (^Body_Ref)(&base[off])^
				if r.index1 != 0 {
					hash_body(w, r, out)
				}
			}
		},
		// A portable image of the slot's tick, with its geometry (late join): the slot is put in the world for
		// the time it takes, then the live state is put back.
		image = proc(data: rawptr, slot: int) -> []u8 {
			w := (^World)(data)
			b3.world_save_snapshot(w.id, &w.scratch)
			b3.world_restore_snapshot(w.id, &w.ring[slot])
			n := b3.world_save_image(w.id, w.image, true)
			b3.world_restore_snapshot(w.id, &w.scratch)
			return b3.world_state_get_data(w.image)[:n]
		},
		// A corrupt image can be found halfway through the load and leave the world half-written, so the world is
		// saved first and put back on failure. Loads are rare (late join).
		load = proc(data: rawptr, bytes: []u8) -> bool {
			w := (^World)(data)
			b3.world_save_snapshot(w.id, &w.scratch)
			if b3.world_load_image(w.id, bytes) do return true
			b3.world_restore_snapshot(w.id, &w.scratch)
			return false
		},
	}
}

// Every Body_Ref and Joint_Ref in the block names a live body or joint (or is zero). Tests run it
// after every restore. Needs `extra(w, S)` first (it finds the refs).
check_refs :: proc(w: ^World, state: rawptr) -> bool {
	base := ([^]u8)(state)
	for off in w.refs {
		r := (^Body_Ref)(&base[off])^
		if r.index1 != 0 && !b3.body_is_valid(body_id(w, r)) {
			return false
		}
	}
	for off in w.joint_refs {
		r := (^Joint_Ref)(&base[off])^
		if r.index1 != 0 && !b3.joint_is_valid(joint_id(w, r)) {
			return false
		}
	}
	return true
}

// The offsets of every field of type `want` (a distinct type: Body_Link is not Body_Ref) in a type.
@(private)
collect_refs :: proc(ti: ^runtime.Type_Info, base: int, out: ^[dynamic]int, want: typeid) {
	if ti.id == want {
		append(out, base)
		return
	}
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		collect_refs(v.base, base, out, want)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			collect_refs(v.types[i], base + int(v.offsets[i]), out, want)
		}
	case runtime.Type_Info_Array:
		if !contains_ref(v.elem, want) {
			return
		}
		for k in 0 ..< v.count {
			collect_refs(v.elem, base + k * v.elem_size, out, want)
		}
	case runtime.Type_Info_Enumerated_Array:
		if !contains_ref(v.elem, want) {
			return
		}
		for k in 0 ..< v.count {
			collect_refs(v.elem, base + k * v.elem_size, out, want)
		}
	}
}

@(private)
contains_ref :: proc(ti: ^runtime.Type_Info, want: typeid) -> bool {
	if ti.id == want {
		return true
	}
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		return contains_ref(v.base, want)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			if contains_ref(v.types[i], want) {
				return true
			}
		}
	case runtime.Type_Info_Array:
		return contains_ref(v.elem, want)
	case runtime.Type_Info_Enumerated_Array:
		return contains_ref(v.elem, want)
	}
	return false
}

// Appends a body's position, rotation, linear and angular velocity as 13 f32 LE (−0.0 → +0.0).
hash_body :: proc(w: ^World, r: Body_Ref, out: ^[dynamic]u8) {
	id := body_id(w, r)
	p := b3.body_get_position(id)
	q := b3.body_get_rotation(id)
	v := b3.body_get_linear_velocity(id)
	a := b3.body_get_angular_velocity(id)
	vals := [13]f32{p.x, p.y, p.z, q.x, q.y, q.z, q.w, v.x, v.y, v.z, a.x, a.y, a.z}
	for f in vals {
		bits := transmute(u32)f
		if bits == 0x8000_0000 {
			bits = 0
		}
		b := transmute([4]u8)u32le(bits)
		append(out, ..b[:])
	}
}
