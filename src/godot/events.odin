// Sim events on the Godot side (src/godot_host/SPEC.md "Events"): the game's event union, read by RTTI once at
// install. The session thread feeds every simulated tick's events to the view's tracker (each identified by its
// tick, kind, subject and index among equal ones), converts their sim.Position fields into view units
// (Glue.event_pos) and posts them as kind + bytes; the main thread turns each into a Dictionary of its fields
// and hands it to the subject's view and to the `sim_event` signal, as Predicted, Confirmed or Cancelled.
package godot

import "base:runtime"
import "core:fmt"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"
import "unified:view"

// One event kind (a variant of Game.events), read by RTTI.
Event_Layout :: struct {
	name:              string, // the type name, lowercased ("coin_picked")
	type:              ^runtime.Type_Info,
	player:            int, // offset of the `player` field (an integer), -1: none
	player_size:       int,
	subject:           int, // offset of the first sim.Handle(T) field, or of a u64 field named `entity`; -1: none
	subject_is_handle: bool,
	positions:         [dynamic]int, // offsets of the sim.Position fields
}

// What the tracker identifies and the session thread posts: one event of one simulated tick.
@(private)
Tick_Event :: struct {
	tick:   u32,
	nth:    u32, // among the tick's events of the same kind and subject
	player: u32, // the subject player (sim.NO_PLAYER: none)
	entity: u64, // the subject key (a handle's key, or the `entity` field), 0: none
	raw:    sim.Raw_Event,
}

@(private)
tick_event_id :: proc(event: Tick_Event) -> view.Event_Id {
	return {
		tick = event.tick,
		kind = u32(event.raw.kind),
		entity = event.entity,
		player = event.player,
		nth = event.nth,
	}
}

// The layouts of a game's event union, by kind (allocated for the process's lifetime).
event_layouts :: proc(events: typeid) -> []Event_Layout {
	context.allocator = runtime.heap_allocator()
	variants := sim.union_variants(events)
	layouts := make([]Event_Layout, len(variants))
	for variant, kind in variants {
		layout := &layouts[kind]
		layout^ = {
			name    = strings.clone(sim.variant_name(variant, "")),
			type    = variant,
			player  = -1,
			subject = -1,
		}
		info := runtime.type_info_base(variant).variant.(runtime.Type_Info_Struct)
		for i in 0 ..< int(info.field_count) {
			field, offset := info.types[i], int(info.offsets[i])
			name := info.names[i]
			switch {
			case field.id == sim.Position:
				append(&layout.positions, offset)
			case is_handle(field):
				if layout.subject < 0 do layout.subject, layout.subject_is_handle = offset, true
			case name == "entity" && field.id == u64:
				if layout.subject < 0 do layout.subject = offset
			case name == "player" && is_integer(field):
				layout.player, layout.player_size = offset, field.size
			}
			// the host adds `tick` to every event's data
			if name == "tick" do fmt.panicf("unified: event %v has a field named `tick`, which the host's event data reserves", variant.id)
		}
	}
	return layouts
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

// The event's subject: its player (sim.NO_PLAYER: none) and its key (a handle's key or the `entity` field, 0: none).
event_subject :: proc(layout: ^Event_Layout, data: []u8) -> (player: u32, entity: u64) {
	player = u32(sim.NO_PLAYER)
	if layout.player >= 0 {
		value := read_uint(data[layout.player:][:layout.player_size])
		if value < u64(sim.MAX_PLAYERS) do player = u32(value)
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

// ---- the main thread: an event's Dictionary

// The event's fields as a Dictionary, converted by type: a handle becomes its key (int), a sim.Position a
// Vector2 (2D) or Vector3 (in view units already), an enum its member's name lowercased (a String), a bit_set an
// Array of those, [2]f32 / [3]f32 / [4]f32 a Vector2 / Vector3 / Color, a nested struct a Dictionary; fields
// named `_...` are padding and left out; a `player` field holding sim.NO_PLAYER becomes -1.
event_dictionary :: proc(layout: ^Event_Layout, data: []u8, is_2d: bool) -> gd.Dictionary {
	dict := gd.dict_new()
	struct_fields(&dict, layout.type, data, is_2d, true)
	return dict
}

@(private)
struct_fields :: proc(dict: ^gd.Dictionary, type: ^runtime.Type_Info, data: []u8, is_2d, top: bool) {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	for i in 0 ..< int(info.field_count) {
		name := info.names[i]
		if strings.has_prefix(name, "_") do continue
		field := info.types[i]
		bytes := data[info.offsets[i]:][:field.size]
		value: gd.Variant
		if top && name == "player" && is_integer(field) && read_uint(bytes) == u64(sim.NO_PLAYER) {
			value = gd.to_variant(i64(-1))
		} else {
			value = field_variant(field, bytes, is_2d)
		}
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

@(private)
f32_at :: proc(bytes: []u8, i: int) -> f32 {
	return transmute(f32)u32(read_uint(bytes[i * 4:][:4]))
}

@(private)
field_variant :: proc(type: ^runtime.Type_Info, bytes: []u8, is_2d: bool) -> gd.Variant {
	if type.id == sim.Position {
		if is_2d do return gd.to_variant(gd.Vector2{f32_at(bytes, 0), f32_at(bytes, 1)})
		return gd.to_variant(gd.Vector3{f32_at(bytes, 0), f32_at(bytes, 1), f32_at(bytes, 2)})
	}
	if is_handle(type) {
		index, generation := read_uint(bytes[:4]), read_uint(bytes[4:])
		return gd.to_variant(i64(generation << 32 | index))
	}
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Integer:
		value := read_uint(bytes)
		if info.signed && type.size < 8 && value >> (uint(type.size) * 8 - 1) != 0 {
			value |= ~u64(0) << (uint(type.size) * 8) // sign-extend
		}
		return gd.to_variant(i64(value))
	case runtime.Type_Info_Float:
		if type.size == 4 do return gd.to_variant(f64(f32_at(bytes, 0)))
		return gd.to_variant(transmute(f64)read_uint(bytes))
	case runtime.Type_Info_Boolean:
		return gd.to_variant(bytes[0] != 0)
	case runtime.Type_Info_Enum:
		return gd.variant_string_name(enum_name(info, read_uint(bytes), type.size))
	case runtime.Type_Info_Bit_Set:
		bits := read_uint(bytes)
		array := gd.array_new()
		for bit in 0 ..< type.size * 8 {
			if bits & (1 << uint(bit)) == 0 do continue
			member := u64(i64(bit) + info.lower)
			if element, is_enum := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Enum); is_enum {
				gd.array_push(&array, enum_name(element, member, info.elem.size))
			} else {
				gd.array_push(&array, i64(member))
			}
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
		array := gd.array_new()
		for i in 0 ..< info.count {
			element := field_variant(info.elem, bytes[i * info.elem_size:][:info.elem.size], is_2d)
			gd.Array_push_back(&array, element)
			gdi.variant_destroy(&element)
		}
		value := gd.to_variant(array)
		gd.Array_destroy(&array)
		return value
	case runtime.Type_Info_Struct:
		dict := gd.dict_new()
		struct_fields(&dict, type, bytes, is_2d, false)
		value := gd.to_variant(dict)
		gd.Dictionary_destroy(&dict)
		return value
	}
	return gd.variant_nil()
}

// An enum member's name, lowercased ("" plus the value when no member has it).
@(private)
enum_name :: proc(info: runtime.Type_Info_Enum, value: u64, size: int) -> string {
	for member, i in info.values {
		bits := u64(member)
		if size < 8 do bits &= (1 << (uint(size) * 8)) - 1
		if bits == value do return strings.to_lower(info.names[i], context.temp_allocator)
	}
	return fmt.tprintf("%d", value)
}

// The event states as GDScript sees them: UnifiedSession.EVENT_EMITTED, EVENT_CONFIRMED, EVENT_CANCELLED (in the
// enum UnifiedSession.EventState), the values of view.Event_Action.
EVENT_STATE_NAMES := [view.Event_Action]string {
	.Emitted   = "EVENT_EMITTED",
	.Confirmed = "EVENT_CONFIRMED",
	.Cancelled = "EVENT_CANCELLED",
}
