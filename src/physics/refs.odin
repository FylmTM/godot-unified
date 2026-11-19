// References (src/physics/README.md, References): how the block names bodies, shapes and joints (Box3D's ids without
// the world index, so blocks match across worlds and machines), the checked accessors, freeing what a value refers to
// (destroy_refs, despawn), and check_refs, which finds every ref in the block by RTTI.
package physics

import "base:runtime"
import "core:fmt"

import box3d "box3d:bindings"
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

// A filter joint (create_filter_joint).
Filter_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// A motor joint (create_motor_joint).
Motor_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// A mover joint (create_mover_joint).
Mover_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// A parallel joint (create_parallel_joint).
Parallel_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// A pogo joint (create_pogo_joint).
Pogo_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// A prismatic joint (create_prismatic_joint).
Prismatic_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// A revolute joint (create_revolute_joint).
Revolute_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// A spherical joint (create_spherical_joint).
Spherical_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// A weld joint (create_weld_joint).
Weld_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// A wheel joint (create_wheel_joint).
Wheel_Joint_Ref :: struct {
	using joint: Joint_Ref,
}

// The Box3D id of a body the block owns, in this world (the library's; games use the body_* procs). A
// zero ref asserts: Box3D's release library doesn't validate ids, so it would index body -1 and corrupt memory.
@(private)
body_id :: proc(world: ^World, ref: Body_Ref, loc := #caller_location) -> box3d.BodyId {
	assert(ref.index1 != 0, "physics: a zero Body_Ref (no body)", loc)
	return {index1 = ref.index1, world0 = world.id.index1 - 1, generation = ref.generation}
}

// The Box3D id of a linked body, in this world. Unchecked: the body may be gone (resolve first).
@(private)
link_id :: proc(world: ^World, body_link: Body_Link) -> box3d.BodyId {
	return {index1 = body_link.index1, world0 = world.id.index1 - 1, generation = body_link.generation}
}

// The Box3D id of a shape, in this world.
@(private)
shape_id :: proc(world: ^World, shape: Shape_Ref) -> box3d.ShapeId {
	return {index1 = shape.index1, world0 = world.id.index1 - 1, generation = shape.generation}
}

// The Box3D id of a joint (any joint ref), in this world.
@(private)
joint_id :: proc(world: ^World, joint: Joint_Ref) -> box3d.JointId {
	return {index1 = joint.index1, world0 = world.id.index1 - 1, generation = joint.generation}
}

// The block's reference to a body Box3D made (the world index dropped, so blocks match across worlds).
@(private)
ref_of :: proc "contextless" (id: box3d.BodyId) -> Body_Ref {
	return {index1 = id.index1, generation = id.generation}
}

// The link to a body Box3D made, for one the block doesn't own (query and event results, grounds).
@(private)
link_of :: proc "contextless" (id: box3d.BodyId) -> Body_Link {
	return {index1 = id.index1, generation = id.generation}
}

// The link to a body the block owns (for queries that skip it, joints, holds, ...).
link :: proc "contextless" (ref: Body_Ref) -> Body_Link {
	return {index1 = ref.index1, generation = ref.generation}
}

// The ref of a shape Box3D made.
@(private)
shape_ref_of :: proc "contextless" (id: box3d.ShapeId) -> Shape_Ref {
	return {index1 = id.index1, generation = id.generation}
}

// The untyped ref of a joint Box3D made.
@(private)
joint_ref_of :: proc "contextless" (id: box3d.JointId) -> Joint_Ref {
	return {index1 = id.index1, generation = id.generation}
}

// Whether a (possibly stale) link names a live body. A zero link is not valid; a link stale for long enough can name
// a live body again (README.md, Known limits).
body_valid :: proc(world: ^World, body_link: Body_Link) -> bool {
	return body_link.index1 != 0 && box3d.Body_IsValid(link_id(world, body_link))
}

// A ref to use now for a (possibly stale) link: not ok when the body is gone. Never keep it in the block (the block
// owns what its Body_Refs name; a link's body is someone else's).
resolve :: proc(world: ^World, body_link: Body_Link) -> (ref: Body_Ref, ok: bool) {
	if !body_valid(world, body_link) do return {}, false
	return {index1 = body_link.index1, generation = body_link.generation}, true
}

// Whether a shape ref names a live shape. Zero is not valid.
shape_valid :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return shape.index1 != 0 && box3d.Shape_IsValid(shape_id(world, shape))
}

// Whether a (possibly stale) joint ref names a live joint (destroying a body destroys its joints). Zero is not valid.
joint_valid :: proc(world: ^World, joint: Joint_Ref) -> bool {
	return joint.index1 != 0 && box3d.Joint_IsValid(joint_id(world, joint))
}

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
		if !box3d.Body_IsValid(body_id(world, ref)) {
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

// A type's ref layout, cached by destroy_refs.
@(private)
Type_Layout :: struct {
	type:   typeid,
	layout: Ref_Layout,
}

// Where a type's refs are (byte offsets), found by RTTI once per type.
@(private)
Ref_Layout :: struct {
	bodies: []int,
	shapes: []int,
	joints: []int, // typed or not: each starts with a Joint_Ref
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

@(private)
delete_layout :: proc(layout: Ref_Layout) {
	delete(layout.bodies)
	delete(layout.shapes)
	delete(layout.joints)
}
