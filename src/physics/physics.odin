// The physics plug-in: a thin layer over the Box3D fork. A World is one Box3D world set up for
// determinism (one worker, fixed creation order is the game's job) plus RING saved images; it
// plugs into the sim harness as Extra state (save/restore/hash/image/load). Bodies are referenced
// from the state block by Body_Ref, which leaves out Box3D's world index so the block is identical
// across the worlds of one process and across machines.
package physics

import "base:runtime"
import "core:sync"

import b3 "../box3d"
import "../sim"

// A body as stored in the block: Box3D's body index + 1 and generation. Zero: no body.
Body_Ref :: struct {
	index1:     i32,
	generation: u16,
	_pad:       u16,
}

// Determinism is fixed (one worker, no threads); the rest are world options.
Settings :: struct {
	gravity: Maybe([3]f32), // nil: Box3D's default
}

World :: struct {
	id:    b3.WorldId,
	cache: ^b3.WorldStateCache,
	ring:  [sim.RING]^b3.WorldState,
	// Offsets of every Body_Ref in the state block, in memory order (the hash order).
	refs:  []int,
}

// b3CreateWorld/b3DestroyWorld scan and modify Box3D's global world table and lazily initialise its
// contact registers, so worlds created from several threads (sessions, tests) are serialised.
@(private)
world_mutex: sync.Mutex

create :: proc(settings := Settings{}) -> ^World {
	w := new(World)
	sync.guard(&world_mutex)
	wd := b3.DefaultWorldDef()
	wd.workerCount = 1
	if g, ok := settings.gravity.?; ok {
		wd.gravity = {g.x, g.y, g.z}
	}
	w.id = b3.CreateWorld(&wd)
	w.cache = b3.CreateWorldStateCache()
	for &r in w.ring {
		r = b3.CreateWorldState()
	}
	return w
}

destroy :: proc(w: ^World) {
	sync.guard(&world_mutex)
	for r in w.ring {
		b3.DestroyWorldState(r)
	}
	b3.DestroyWorldStateCache(w.cache)
	b3.DestroyWorld(w.id)
	delete(w.refs)
	free(w)
}

body_id :: proc(w: ^World, r: Body_Ref) -> b3.BodyId {
	return {index1 = r.index1, world0 = w.id.index1 - 1, generation = r.generation}
}

ref_of :: proc(id: b3.BodyId) -> Body_Ref {
	return {index1 = id.index1, generation = id.generation}
}

// Destroys the body and clears the reference.
destroy_body :: proc(w: ^World, r: ^Body_Ref) {
	if r.index1 != 0 {
		b3.DestroyBody(body_id(w, r^))
	}
	r^ = {}
}

// The Extra that makes the world part of the rollback state of a block of type S: every Body_Ref
// in S (fields, arrays, table items) is found once by RTTI; the checksum covers each referenced
// body (position, rotation, linear and angular velocity) in the block's memory order.
extra :: proc(w: ^World, $S: typeid) -> sim.Extra {
	refs := make([dynamic]int)
	collect_refs(type_info_of(S), 0, &refs)
	delete(w.refs)
	w.refs = refs[:]
	return {name = "physics", data = w, save = proc(data: rawptr, slot: int) {
			w := (^World)(data)
			b3.World_SaveState(w.id, w.cache, w.ring[slot])
		}, restore = proc(data: rawptr, slot: int) -> bool {
			w := (^World)(data)
			return b3.World_RestoreState(w.id, w.cache, w.ring[slot])
		}, hash = proc(data: rawptr, state: rawptr, out: ^[dynamic]u8) {
			w := (^World)(data)
			base := ([^]u8)(state)
			for off in w.refs {
				r := (^Body_Ref)(&base[off])^
				if r.index1 != 0 {
					hash_body(w, r, out)
				}
			}
		}, image = proc(data: rawptr, slot: int) -> []u8 {
			w := (^World)(data)
			return b3.WorldState_GetData(w.ring[slot])[:b3.WorldState_GetSize(w.ring[slot])]
		}, load = proc(data: rawptr, bytes: []u8) -> bool {
			w := (^World)(data)
			return b3.World_RestoreStateFromBytes(w.id, w.cache, bytes)
		}}
}

@(private)
collect_refs :: proc(ti: ^runtime.Type_Info, base: int, out: ^[dynamic]int) {
	if ti.id == Body_Ref {
		append(out, base)
		return
	}
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		collect_refs(v.base, base, out)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			collect_refs(v.types[i], base + int(v.offsets[i]), out)
		}
	case runtime.Type_Info_Array:
		if !contains_ref(v.elem) {
			return
		}
		for k in 0 ..< v.count {
			collect_refs(v.elem, base + k * v.elem_size, out)
		}
	case runtime.Type_Info_Enumerated_Array:
		if !contains_ref(v.elem) {
			return
		}
		for k in 0 ..< v.count {
			collect_refs(v.elem, base + k * v.elem_size, out)
		}
	}
}

@(private)
contains_ref :: proc(ti: ^runtime.Type_Info) -> bool {
	if ti.id == Body_Ref {
		return true
	}
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		return contains_ref(v.base)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			if contains_ref(v.types[i]) {
				return true
			}
		}
	case runtime.Type_Info_Array:
		return contains_ref(v.elem)
	case runtime.Type_Info_Enumerated_Array:
		return contains_ref(v.elem)
	}
	return false
}

// Appends a body's position, rotation, linear and angular velocity as 13 f32 LE (−0.0 → +0.0).
hash_body :: proc(w: ^World, r: Body_Ref, out: ^[dynamic]u8) {
	id := body_id(w, r)
	p := b3.Body_GetPosition(id)
	q := b3.Body_GetRotation(id)
	v := b3.Body_GetLinearVelocity(id)
	a := b3.Body_GetAngularVelocity(id)
	vals := [13]f32{p.x, p.y, p.z, q.v.x, q.v.y, q.v.z, q.s, v.x, v.y, v.z, a.x, a.y, a.z}
	for f in vals {
		bits := transmute(u32)f
		if bits == 0x8000_0000 {
			bits = 0
		}
		b := transmute([4]u8)u32le(bits)
		append(out, ..b[:])
	}
}

v3 :: #force_inline proc "contextless" (v: [3]f32) -> b3.Vec3 {
	return {v.x, v.y, v.z}
}
