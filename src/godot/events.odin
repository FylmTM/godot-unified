// Sim events on the Godot side (src/godot/README.md, Events): the game's event union, read by RTTI once at install.
// The session thread feeds every simulated tick's events to the view's tracker (each identified by its tick, kind,
// subject and index among equal ones) and posts them as kind + bytes, positions in sim units; the main thread makes
// each an object of its class (sim_classes.odin) and hands it to the subject's view and to the `sim_event` signal, as
// Emitted, Confirmed or Cancelled. field_variant converts a field by type for the event classes and for the views'
// and the session's data, mapping a sim.Position to view units (Glue.view_scale).
#+private
package godot

import "base:runtime"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"

// What the tracker identifies and the session thread posts: one event of one simulated tick.
Tick_Event :: struct {
	tick:   u32,
	nth:    u32, // among the tick's events of the same kind and subject
	player: u64, // the subject player's key (sim.player_key; 0: none)
	entity: u64, // the subject (a handle's key, or a sim.Entity), 0: none
	raw:    sim.Raw_Event,
}

tick_event_id :: proc(event: Tick_Event) -> Event_Id {
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
to_view_units :: #force_inline proc "contextless" (point: [3]f32) -> [3]f32 {
	return point * api.view_scale
}

// View units to sim units: a point a script set (a command's sim.Position).
to_sim :: #force_inline proc "contextless" (point: [3]f32) -> [3]f32 {
	return point / api.view_scale
}

// The offsets of a struct's sim.Position fields, in nested structs too (what crosses between sim and view units).
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

is_integer :: proc(type: ^runtime.Type_Info) -> bool {
	_, ok := runtime.type_info_base(type).variant.(runtime.Type_Info_Integer)
	return ok
}

// ---- the main thread: fields converted by type (field_kind, field_variant; command.odin write_value the other way)

// The Variant type a field reads as, and its class name: an OBJECT's class (a nested struct's DataX), an ARRAY's
// element type ("int", "Vector2", "DataHudPlayer"; "": untyped, an array of arrays). By shape: [2]/[3]/[4]f32 a
// Vector2/3/4, [2]/[3]/[4]i32 a Vector2i/3i/4i, Color a Color, Quat a Quaternion, a sim.Position a Vector2 (2D) or
// Vector3; a handle or a sim.Player an int (its key), a sim.Entity an int (its index, -1: none), an enum an int, a
// bit_set an Array[int], a nested struct an object of its class (a Dictionary when it has none: a struct only view
// data uses).
field_kind :: proc(type: ^runtime.Type_Info) -> (kind: gdi.VariantType, class_name: string) {
	switch {
	case type.id == sim.Position:
		return api.is_2d ? .VECTOR2 : .VECTOR3, ""
	case is_handle(type) || type.id == sim.Player || type.id == sim.Entity:
		return .INT, ""
	case type.id == Color:
		return .COLOR, ""
	case type.id == Quat:
		return .QUATERNION, ""
	}
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Enum:
		return .INT, ""
	case runtime.Type_Info_Float:
		return .FLOAT, ""
	case runtime.Type_Info_Boolean:
		return .BOOL, ""
	case runtime.Type_Info_String:
		return .STRING, ""
	case runtime.Type_Info_Bit_Set:
		return .ARRAY, "int"
	case runtime.Type_Info_Array:
		if vector := vector_kind(info.elem, info.count); vector != .NIL do return vector, ""
		return .ARRAY, element_type_name(info.elem)
	case runtime.Type_Info_Enumerated_Array:
		return .ARRAY, element_type_name(info.elem)
	case runtime.Type_Info_Struct:
		if nested := D.nested[type.id]; nested != nil do return .OBJECT, nested.name
		return .DICTIONARY, ""
	}
	return .NIL, ""
}

// [2]/[3]/[4] of f32 or i32 as a Godot vector type (NIL: none).
vector_kind :: proc(elem: ^runtime.Type_Info, count: int) -> gdi.VariantType {
	FLOATS :: [3]gdi.VariantType{.VECTOR2, .VECTOR3, .VECTOR4}
	INTS :: [3]gdi.VariantType{.VECTOR2I, .VECTOR3I, .VECTOR4I}
	if count < 2 || count > 4 do return .NIL
	floats, ints := FLOATS, INTS
	if elem.id == f32 do return floats[count - 2]
	if elem.id == i32 do return ints[count - 2]
	return .NIL
}

// The type name an array of `elem` is typed by in GDScript ("": untyped, an array of arrays).
element_type_name :: proc(elem: ^runtime.Type_Info) -> string {
	kind, class_name := field_kind(elem)
	#partial switch kind {
	case .ARRAY, .NIL:
		return ""
	case .OBJECT:
		return class_name
	}
	return gd.variant_type_name(kind)
}

f32_at :: proc(bytes: []u8, i: int) -> f32 {
	return transmute(f32)u32(read_uint(bytes[i * 4:][:4]))
}

i32_at :: proc(bytes: []u8, i: int) -> i32 {
	return i32(read_int(bytes[i * 4:][:4], true))
}

// A field's value (field_kind says as what), from bytes in `units` (.Sim: a sim.Position is mapped to view units).
field_variant :: proc(type: ^runtime.Type_Info, bytes: []u8, units: Units) -> gd.Variant {
	switch {
	case type.id == sim.Position:
		point := [3]f32{f32_at(bytes, 0), f32_at(bytes, 1), f32_at(bytes, 2)}
		if units == .Sim do point = to_view_units(point)
		if api.is_2d do return gd.to_variant(gd.Vector2{point.x, point.y})
		return gd.to_variant(gd.Vector3{point.x, point.y, point.z})
	case is_handle(type):
		index, generation := read_uint(bytes[:4]), read_uint(bytes[4:])
		return gd.to_variant(i64(generation << 32 | index))
	case type.id == sim.Player:
		return gd.to_variant(i64(player_key_of(bytes)))
	case type.id == sim.Entity:
		// its index, the number its views are keyed by and Unified.level_markers is indexed by (-1: none)
		index, ok := sim.entity_index(sim.Entity(read_uint(bytes)))
		return gd.to_variant(i64(ok ? index : -1))
	case type.id == Color:
		return gd.to_variant(gd.Color{f32_at(bytes, 0), f32_at(bytes, 1), f32_at(bytes, 2), f32_at(bytes, 3)})
	case type.id == Quat:
		return gd.to_variant(gd.Quaternion{f32_at(bytes, 0), f32_at(bytes, 1), f32_at(bytes, 2), f32_at(bytes, 3)})
	}
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
		return array_variant(&array)
	case runtime.Type_Info_Array:
		#partial switch vector_kind(info.elem, info.count) {
		case .VECTOR2:
			return gd.to_variant(gd.Vector2{f32_at(bytes, 0), f32_at(bytes, 1)})
		case .VECTOR3:
			return gd.to_variant(gd.Vector3{f32_at(bytes, 0), f32_at(bytes, 1), f32_at(bytes, 2)})
		case .VECTOR4:
			return gd.to_variant(gd.Vector4{f32_at(bytes, 0), f32_at(bytes, 1), f32_at(bytes, 2), f32_at(bytes, 3)})
		case .VECTOR2I:
			return gd.to_variant(gd.Vector2i{i32_at(bytes, 0), i32_at(bytes, 1)})
		case .VECTOR3I:
			return gd.to_variant(gd.Vector3i{i32_at(bytes, 0), i32_at(bytes, 1), i32_at(bytes, 2)})
		case .VECTOR4I:
			return gd.to_variant(gd.Vector4i{i32_at(bytes, 0), i32_at(bytes, 1), i32_at(bytes, 2), i32_at(bytes, 3)})
		}
		return elements_variant(type, info.elem, info.elem_size, info.count, bytes, units)
	case runtime.Type_Info_Enumerated_Array:
		return elements_variant(type, info.elem, info.elem_size, info.count, bytes, units) // by the enum's order
	case runtime.Type_Info_Struct:
		if nested := D.nested[type.id]; nested != nil do return nested_variant(nested, bytes, units)
		dict := gd.dict_new()
		struct_fields(&dict, type, bytes, units)
		value := gd.to_variant(dict)
		gd.Dictionary_destroy(&dict)
		return value
	}
	return gd.variant_nil()
}

// An array's or an enumerated array's elements as a typed Array.
elements_variant :: proc(
	type, elem: ^runtime.Type_Info,
	elem_size, count: int,
	bytes: []u8,
	units: Units,
) -> gd.Variant {
	array := typed_array(type)
	for i in 0 ..< count {
		element := field_variant(elem, bytes[i * elem_size:][:elem.size], units)
		gd.Array_push_back(&array, element)
		gdi.variant_destroy(&element)
	}
	return array_variant(&array)
}

// A nested struct's value: a new object of its class holding a copy of the bytes, in view units (a script may set its
// fields and put it into a command).
nested_variant :: proc(nested: ^Data_Class, bytes: []u8, units: Units) -> gd.Variant {
	object := gd.Object{gd.construct_object_named(nested.class_sn)}
	instance := (^Data_Object)(gd.instance_of(object, &nested.class))
	copy(instance.bytes, bytes)
	if units == .Sim {
		for offset in nested.positions {
			position := (^sim.Position)(&instance.bytes[offset])
			position^ = sim.Position(to_view_units(([3]f32)(position^)))
		}
	}
	// the Variant holds a reference and ours goes: the object lives as long as a script keeps it
	value := gd.variant_from_any(object)
	gd.unref(transmute(gd.RefCounted)object)
	return value
}

// A struct only view data uses (it has no class): its fields into a Dictionary (`_` fields are padding).
struct_fields :: proc(dict: ^gd.Dictionary, type: ^runtime.Type_Info, data: []u8, units: Units) {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	for i in 0 ..< int(info.field_count) {
		name := info.names[i]
		if strings.has_prefix(name, "_") do continue
		field := info.types[i]
		value := field_variant(field, data[info.offsets[i]:][:field.size], units)
		gd.dict_set(dict, name, value)
		gdi.variant_destroy(&value)
	}
}

// A new Array for an array field, typed by its elements when it can be.
typed_array :: proc(type: ^runtime.Type_Info) -> gd.Array {
	array := gd.array_new()
	kind, element := field_kind(type)
	if kind != .ARRAY || element == "" do return array
	element_kind, _ := field_kind(array_elem(type))
	#partial switch element_kind {
	case .OBJECT:
		gd.array_set_typed(&array, .OBJECT, element)
	case:
		gd.array_set_typed(&array, element_kind)
	}
	return array
}

// The element type of an array, enumerated array or bit_set (a bit_set's elements are ints).
array_elem :: proc(type: ^runtime.Type_Info) -> ^runtime.Type_Info {
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Array:
		return info.elem
	case runtime.Type_Info_Enumerated_Array:
		return info.elem
	}
	return type_info_of(i64)
}

// An integer field's value (little-endian bytes), sign-extended when signed.
read_int :: proc(bytes: []u8, signed: bool) -> i64 {
	value := read_uint(bytes)
	if signed && len(bytes) < 8 && value >> (uint(len(bytes)) * 8 - 1) != 0 {
		value |= ~u64(0) << (uint(len(bytes)) * 8)
	}
	return i64(value)
}

// The event states as GDScript sees them: UnifiedSession.EVENT_EMITTED, EVENT_CONFIRMED, EVENT_CANCELLED (in the
// enum UnifiedSession.EventState), the values of Event_Action.
EVENT_STATE_NAMES := [Event_Action]string {
	.Emitted   = "EVENT_EMITTED",
	.Confirmed = "EVENT_CONFIRMED",
	.Cancelled = "EVENT_CANCELLED",
}
