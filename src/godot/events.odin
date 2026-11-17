// Sim events on the Godot side (src/godot/SPEC.md "Events"): the game's event union, read by RTTI once at install.
// The session thread feeds every simulated tick's events to the view's tracker (each identified by its tick, kind,
// subject and index among equal ones) and posts them as kind + bytes, positions in sim units; the main thread makes
// each an object of its class (sim_classes.odin) and hands it to the subject's view and to the `sim_event` signal, as
// Emitted, Confirmed or Cancelled. field_variant converts a field by type for the event classes and for the views'
// and the session's data, mapping a sim.Position to view units (Glue.view_scale).
package godot

import "base:runtime"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"
import "unified:view"

// One event kind (a variant of the game's Event union), read by RTTI.
Event_Layout :: struct {
	name:              string, // the type name without `Event_`, lowercased ("coin_picked")
	type:              ^runtime.Type_Info,
	player:            int, // offset of the first sim.Player field, -1: none
	subject:           int, // offset of the first sim.Handle(T) field, or of a u64 field named `entity`; -1: none
	subject_is_handle: bool,
}

// What the tracker identifies and the session thread posts: one event of one simulated tick.
@(private)
Tick_Event :: struct {
	tick:   u32,
	nth:    u32, // among the tick's events of the same kind and subject
	player: u64, // the subject player's key (sim.player_key; 0: none)
	entity: u64, // the subject key (a handle's key, or the `entity` field), 0: none
	raw:    sim.Raw_Event,
}

@(private)
tick_event_id :: proc(event: Tick_Event) -> view.Event_Id {
	return {
		tick   = event.tick,
		kind   = u32(event.raw.kind),
		entity = event.entity,
		player = event.player,
		nth    = event.nth,
	}
}

// Which units a sim.Position's bytes are in: .Sim (from the sim: events, view and session data, constants; the host
// maps them to view units) or .View (a command object: what the script set, read back as set).
Units :: enum u8 {
	Sim,
	View,
}

// Sim units to view units (Glue.view_scale): where the host makes a Godot value from a point.
@(private)
to_view :: #force_inline proc "contextless" (point: [3]f32) -> [3]f32 {
	return point * api.view_scale
}

// View units to sim units: a point a script set (a command's sim.Position).
@(private)
to_sim :: #force_inline proc "contextless" (point: [3]f32) -> [3]f32 {
	return point / api.view_scale
}

// The layouts of a game's event union, by kind (allocated for the process's lifetime).
event_layouts :: proc(events: typeid) -> []Event_Layout {
	context.allocator = runtime.heap_allocator()
	variants := sim.union_variants(events)
	layouts := make([]Event_Layout, len(variants))
	for variant, kind in variants {
		layout := &layouts[kind]
		layout^ = {
			name    = strings.clone(sim.variant_name(variant, sim.EVENT_PREFIX)),
			type    = variant,
			player  = -1,
			subject = -1,
		}
		info := runtime.type_info_base(variant).variant.(runtime.Type_Info_Struct)
		for i in 0 ..< int(info.field_count) {
			field, offset := info.types[i], int(info.offsets[i])
			name := info.names[i]
			switch {
			case field.id == sim.Player:
				if layout.player < 0 do layout.player = offset
			case is_handle(field):
				if layout.subject < 0 do layout.subject, layout.subject_is_handle = offset, true
			case name == "entity" && field.id == u64:
				if layout.subject < 0 do layout.subject = offset
			}
		}
	}
	return layouts
}

// The offsets of a struct's sim.Position fields, in nested structs too (what crosses between sim and view units).
@(private)
position_offsets :: proc(type: ^runtime.Type_Info, base: int, out: ^[dynamic]int) {
	info, is_struct := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	if !is_struct do return
	for i in 0 ..< int(info.field_count) {
		field, offset := info.types[i], base + int(info.offsets[i])
		if field.id == sim.Position {
			append(out, offset)
		} else if !is_handle(field) && field.id != sim.Player {
			position_offsets(field, offset, out)
		}
	}
}

// A sim.Handle(T): its RTTI names it "Handle($T=...)" in package sim.
@(private)
is_handle :: proc(type: ^runtime.Type_Info) -> bool {
	named, ok := type.variant.(runtime.Type_Info_Named)
	return ok && named.pkg == "sim" && strings.has_prefix(named.name, "Handle(") && type.size == 8
}

@(private)
is_integer :: proc(type: ^runtime.Type_Info) -> bool {
	_, ok := runtime.type_info_base(type).variant.(runtime.Type_Info_Integer)
	return ok
}

@(private)
read_uint :: proc(bytes: []u8) -> u64 {
	value: u64
	for i := len(bytes) - 1; i >= 0; i -= 1 do value = value << 8 | u64(bytes[i])
	return value
}

// The event's subject: its player's key (its first sim.Player field; 0: none) and its key (a handle's key or the
// `entity` field, 0: none).
event_subject :: proc(layout: ^Event_Layout, data: []u8) -> (player: u64, entity: u64) {
	if layout.player >= 0 {
		player = player_key_of(data[layout.player:][:size_of(sim.Player)])
	}
	if layout.subject >= 0 {
		bytes := data[layout.subject:][:8]
		if layout.subject_is_handle {
			index, generation := read_uint(bytes[:4]), read_uint(bytes[4:])
			entity = generation << 32 | index // sim.handle_key
		} else {
			entity = read_uint(bytes)
		}
	}
	return
}

// ---- the main thread: fields converted by type (field_variant, below)

// The key of a sim.Player's bytes (sim.player_key: 0 for nobody).
@(private)
player_key_of :: proc(bytes: []u8) -> u64 {
	return sim.player_key({index = u16(read_uint(bytes[:2])), id = u16(read_uint(bytes[2:4]))})
}

// A nested struct's fields into a Dictionary (fields named `_...` are padding, left out).
@(private)
struct_fields :: proc(dict: ^gd.Dictionary, type: ^runtime.Type_Info, data: []u8, units: Units) {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	for i in 0 ..< int(info.field_count) {
		name := info.names[i]
		if strings.has_prefix(name, "_") do continue
		field := info.types[i]
		value := field_variant(field, data[info.offsets[i]:][:field.size], units)
		dict_put(dict, name, &value)
	}
}

// Moves `value` into dict[key].
@(private)
dict_put :: proc(dict: ^gd.Dictionary, key: string, value: ^gd.Variant) {
	key_variant := gd.to_variant(key)
	defer gdi.variant_destroy(&key_variant)
	slot := (^gd.Variant)(gdi.dictionary_operator_index(dict, &key_variant))
	gdi.variant_destroy(slot)
	slot^ = value^
	value^ = {}
}

// A Godot math value from a field's bytes (copied: the frame's data has no alignment).
@(private)
math_variant :: proc($T: typeid, bytes: []u8) -> gd.Variant {
	value: T
	copy(([^]u8)(&value)[:size_of(T)], bytes)
	return gd.to_variant(value)
}

@(private)
f32_at :: proc(bytes: []u8, i: int) -> f32 {
	return transmute(f32)u32(read_uint(bytes[i * 4:][:4]))
}

// A field's value: a handle becomes its key (int), a sim.Player its key (sim.player_key, int: 0 for nobody), a
// sim.Position a Vector2 (2D) or Vector3 (in view units already),
// one of Godot's math types (gd.Color, gd.Vector4, gd.Quaternion, ...: a view's data may use them, the extension
// imports gdext) itself, an enum its value (an int: its Enum* class names the members), a bit_set an Array of
// ints, [2]f32 / [3]f32 / [4]f32 a Vector2 / Vector3 / Color, another array an Array, a nested struct a Dictionary,
// a string a String (constants), other numbers int or float.
@(private)
field_variant :: proc(type: ^runtime.Type_Info, bytes: []u8, units: Units) -> gd.Variant {
	if type.id == sim.Position {
		point := [3]f32{f32_at(bytes, 0), f32_at(bytes, 1), f32_at(bytes, 2)}
		if units == .Sim do point = to_view(point)
		if api.is_2d do return gd.to_variant(gd.Vector2{point.x, point.y})
		return gd.to_variant(gd.Vector3{point.x, point.y, point.z})
	}
	switch type.id {
	case gd.Vector2:
		return math_variant(gd.Vector2, bytes)
	case gd.Vector2i:
		return math_variant(gd.Vector2i, bytes)
	case gd.Rect2:
		return math_variant(gd.Rect2, bytes)
	case gd.Rect2i:
		return math_variant(gd.Rect2i, bytes)
	case gd.Vector3:
		return math_variant(gd.Vector3, bytes)
	case gd.Vector3i:
		return math_variant(gd.Vector3i, bytes)
	case gd.Transform2D:
		return math_variant(gd.Transform2D, bytes)
	case gd.Vector4:
		return math_variant(gd.Vector4, bytes)
	case gd.Vector4i:
		return math_variant(gd.Vector4i, bytes)
	case gd.Plane:
		return math_variant(gd.Plane, bytes)
	case gd.Quaternion:
		return math_variant(gd.Quaternion, bytes)
	case gd.AABB:
		return math_variant(gd.AABB, bytes)
	case gd.Basis:
		return math_variant(gd.Basis, bytes)
	case gd.Transform3D:
		return math_variant(gd.Transform3D, bytes)
	case gd.Projection:
		return math_variant(gd.Projection, bytes)
	case gd.Color:
		return math_variant(gd.Color, bytes)
	}
	if is_handle(type) {
		index, generation := read_uint(bytes[:4]), read_uint(bytes[4:])
		return gd.to_variant(i64(generation << 32 | index))
	}
	if type.id == sim.Player do return gd.to_variant(i64(player_key_of(bytes)))
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Integer:
		return gd.to_variant(read_int(bytes, info.signed))
	case runtime.Type_Info_Float:
		if type.size == 4 do return gd.to_variant(f64(f32_at(bytes, 0)))
		return gd.to_variant(transmute(f64)read_uint(bytes))
	case runtime.Type_Info_Boolean:
		return gd.to_variant(bytes[0] != 0)
	case runtime.Type_Info_Enum:
		backing := runtime.type_info_base(info.base).variant.(runtime.Type_Info_Integer)
		return gd.to_variant(read_int(bytes, backing.signed))
	case runtime.Type_Info_String:
		text := (^string)(raw_data(bytes))^ // constants only: their strings live as long as the process
		return gd.to_variant(text)
	case runtime.Type_Info_Bit_Set:
		bits := read_uint(bytes)
		array := typed_array(type)
		for bit in 0 ..< type.size * 8 {
			if bits & (1 << uint(bit)) == 0 do continue
			gd.array_push(&array, i64(bit) + info.lower)
		}
		value := gd.to_variant(array)
		gd.Array_destroy(&array)
		return value
	case runtime.Type_Info_Array:
		if info.elem.id == f32 {
			switch info.count {
			case 2:
				return gd.to_variant(gd.Vector2{f32_at(bytes, 0), f32_at(bytes, 1)})
			case 3:
				return gd.to_variant(gd.Vector3{f32_at(bytes, 0), f32_at(bytes, 1), f32_at(bytes, 2)})
			case 4:
				return gd.to_variant(gd.Color{f32_at(bytes, 0), f32_at(bytes, 1), f32_at(bytes, 2), f32_at(bytes, 3)})
			}
		}
		array := typed_array(type)
		for i in 0 ..< info.count {
			element := field_variant(info.elem, bytes[i * info.elem_size:][:info.elem.size], units)
			gd.Array_push_back(&array, element)
			gdi.variant_destroy(&element)
		}
		value := gd.to_variant(array)
		gd.Array_destroy(&array)
		return value
	case runtime.Type_Info_Enumerated_Array:
		// [Enum]T: an Array by the enum's order
		array := typed_array(type)
		for i in 0 ..< info.count {
			element := field_variant(info.elem, bytes[i * info.elem_size:][:info.elem.size], units)
			gd.Array_push_back(&array, element)
			gdi.variant_destroy(&element)
		}
		value := gd.to_variant(array)
		gd.Array_destroy(&array)
		return value
	case runtime.Type_Info_Struct:
		dict := gd.dict_new()
		struct_fields(&dict, type, bytes, units)
		value := gd.to_variant(dict)
		gd.Dictionary_destroy(&dict)
		return value
	}
	return gd.variant_nil()
}

// The element type of an array field as GDScript types it (Array[int], Array[Vector2], Array[Dictionary] for
// structs...); NIL: untyped (an array of arrays: GDScript has no nested typed arrays).
array_element_kind :: proc(type: ^runtime.Type_Info) -> gdi.VariantType {
	element: gdi.VariantType
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Bit_Set:
		return .INT
	case runtime.Type_Info_Array:
		element = field_kind(info.elem)
	case runtime.Type_Info_Enumerated_Array:
		element = field_kind(info.elem)
	case:
		return .NIL
	}
	return element == .ARRAY ? .NIL : element
}

// A new Array for an array field, typed by its elements when it can be.
@(private)
typed_array :: proc(type: ^runtime.Type_Info) -> gd.Array {
	array := gd.array_new()
	if element := array_element_kind(type); element != .NIL do gd.array_set_typed(&array, element)
	return array
}

// The property hint of a field: a typed Array names its element type.
field_hint :: proc(type: ^runtime.Type_Info) -> (gd.Property_Hint, string) {
	if field_kind(type) != .ARRAY do return .NONE, ""
	element := array_element_kind(type)
	if element == .NIL do return .NONE, ""
	return .ARRAY_TYPE, variant_type_name(element)
}

// A Variant type's name in GDScript ("int", "Vector2"...).
@(private)
variant_type_name :: proc(kind: gdi.VariantType) -> string {
	#partial switch kind {
	case .BOOL:
		return "bool"
	case .INT:
		return "int"
	case .FLOAT:
		return "float"
	case .STRING:
		return "String"
	case .STRING_NAME:
		return "StringName"
	case .DICTIONARY:
		return "Dictionary"
	case .COLOR:
		return "Color"
	case .VECTOR2:
		return "Vector2"
	case .VECTOR2I:
		return "Vector2i"
	case .VECTOR3:
		return "Vector3"
	case .VECTOR3I:
		return "Vector3i"
	case .VECTOR4:
		return "Vector4"
	case .VECTOR4I:
		return "Vector4i"
	case .RECT2:
		return "Rect2"
	case .RECT2I:
		return "Rect2i"
	case .TRANSFORM2D:
		return "Transform2D"
	case .TRANSFORM3D:
		return "Transform3D"
	case .PLANE:
		return "Plane"
	case .QUATERNION:
		return "Quaternion"
	case .AABB:
		return "AABB"
	case .BASIS:
		return "Basis"
	case .PROJECTION:
		return "Projection"
	}
	return "Variant"
}

// An integer field's value (little-endian bytes), sign-extended when signed.
@(private)
read_int :: proc(bytes: []u8, signed: bool) -> i64 {
	value := read_uint(bytes)
	if signed && len(bytes) < 8 && value >> (uint(len(bytes)) * 8 - 1) != 0 {
		value |= ~u64(0) << (uint(len(bytes)) * 8)
	}
	return i64(value)
}

// The event states as GDScript sees them: UnifiedSession.EVENT_EMITTED, EVENT_CONFIRMED, EVENT_CANCELLED (in the
// enum UnifiedSession.EventState), the values of view.Event_Action.
EVENT_STATE_NAMES := [view.Event_Action]string {
	.Emitted   = "EVENT_EMITTED",
	.Confirmed = "EVENT_CONFIRMED",
	.Cancelled = "EVENT_CANCELLED",
}
