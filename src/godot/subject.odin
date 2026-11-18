// An event's subject as the host reads it by RTTI (src/godot/SPEC.md "Events"): its first sim.Player field, and its
// first handle or sim.Entity field. Public for tests/godot_driver, like the rest of the view logic.
package godot

import "base:runtime"
import "core:strings"
import "unified:sim"

// One event kind (a variant of the game's Event union), read by RTTI.
Event_Layout :: struct {
	name:              string, // the type name without `Event_`, lowercased ("coin_picked")
	type:              ^runtime.Type_Info,
	player:            int, // offset of the first sim.Player field, -1: none
	subject:           int, // offset of the first sim.Handle(T) or sim.Entity field; -1: none
	subject_is_handle: bool,
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
			switch {
			case field.id == sim.Player:
				if layout.player < 0 do layout.player = offset
			case is_handle(field):
				if layout.subject < 0 do layout.subject, layout.subject_is_handle = offset, true
			case field.id == sim.Entity:
				if layout.subject < 0 do layout.subject = offset
			}
		}
	}
	return layouts
}

// The event's subject: its player's key (its first sim.Player field; 0: none) and its subject (a handle's key or a
// sim.Entity, 0: none).
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

// A sim.Handle(T): its RTTI names it "Handle($T=...)" in package sim.
is_handle :: proc(type: ^runtime.Type_Info) -> bool {
	named, ok := type.variant.(runtime.Type_Info_Named)
	return ok && named.pkg == "sim" && strings.has_prefix(named.name, "Handle(") && type.size == 8
}

read_uint :: proc(bytes: []u8) -> u64 {
	value: u64
	for i := len(bytes) - 1; i >= 0; i -= 1 do value = value << 8 | u64(bytes[i])
	return value
}

// The key of a sim.Player's bytes (sim.player_key: 0 for nobody).
player_key_of :: proc(bytes: []u8) -> u64 {
	return sim.player_key({index = u16(read_uint(bytes[:2])), id = u16(read_uint(bytes[2:4]))})
}
