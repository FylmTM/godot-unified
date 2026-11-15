// A game declares its commands and events as unions of plain structs (src/sim/SPEC.md "Commands",
// "Events"). On the wire, in the log and in the ring each value is its kind (the variant's index in
// the union) and its struct's bytes; these helpers go between the two by RTTI.
package sim

import "base:runtime"
import "core:fmt"
import "core:strings"

COMMAND_PREFIX :: "Cmd_" // a command's name is its type name without it, lowercased
EVENT_PREFIX :: "Event_" // an event's name is its type name without it (when it has it), lowercased

// The union's variants (nil for a nil typeid).
union_variants :: proc(type: typeid) -> []^runtime.Type_Info {
	if type == nil do return nil
	info, ok := runtime.type_info_base(type_info_of(type)).variant.(runtime.Type_Info_Union)
	return info.variants if ok else nil
}

// A variant's kind (its index in the union), -1 when `variant` is not one of them.
variant_kind :: proc(type: typeid, variant: typeid) -> int {
	for candidate, i in union_variants(type) {
		if candidate.id == variant do return i
	}
	return -1
}

// A variant's name: its type name without `prefix`, lowercased ("Cmd_Drop_Coin" -> "drop_coin",
// "Event_Coin_Picked" and "Coin_Picked" -> "coin_picked"). Temp-allocated.
variant_name :: proc(type: ^runtime.Type_Info, prefix: string) -> string {
	name := fmt.tprint(type.id)
	if named, ok := type.variant.(runtime.Type_Info_Named); ok do name = named.name
	return strings.to_lower(strings.trim_prefix(name, prefix), context.temp_allocator)
}

// The names of a union's variants, by kind (allocated with `allocator`, names included).
variant_names :: proc(type: typeid, prefix: string, allocator := context.allocator) -> []string {
	variants := union_variants(type)
	names := make([]string, len(variants), allocator)
	for variant, i in variants {
		names[i] = strings.clone(variant_name(variant, prefix), allocator)
	}
	return names
}

// The game's command names, by kind ("drop_coin"): what GDScript's send_command uses.
command_names :: proc(commands: typeid, allocator := context.allocator) -> []string {
	return variant_names(commands, COMMAND_PREFIX, allocator)
}

// The game's event names, by kind ("coin_picked").
event_names :: proc(events: typeid, allocator := context.allocator) -> []string {
	return variant_names(events, EVENT_PREFIX, allocator)
}

// Why a union can't be a command or event union ("" when it can, or when `type` is nil): a union
// (not #no_nil, not #shared_nil), at most 255 variants, each plain data (plain_violation) of
// 1..max_size bytes, names unique.
union_violation :: proc(type: typeid, max_size: int, prefix: string) -> string {
	if type == nil do return ""
	info, ok := runtime.type_info_base(type_info_of(type)).variant.(runtime.Type_Info_Union)
	if !ok do return fmt.tprintf("%v is not a union", type)
	if info.no_nil || info.shared_nil do return fmt.tprintf("%v: #no_nil and #shared_nil unions can't be read back", type)
	if len(info.variants) > 255 do return fmt.tprintf("%v: %d variants (at most 255)", type, len(info.variants))
	for variant, i in info.variants {
		name := variant_name(variant, prefix)
		if reason := plain_violation(variant, fmt.tprint(variant.id)); reason != "" {
			return fmt.tprintf("%q: %s", name, reason)
		}
		if variant.size > max_size || variant.size == 0 {
			return fmt.tprintf("%q: %d bytes (1..%d)", name, variant.size, max_size)
		}
		for j in 0 ..< i {
			if variant_name(info.variants[j], prefix) == name {
				return fmt.tprintf("two variants are named %q", name)
			}
		}
	}
	return ""
}

// The union value of kind `kind` made of `bytes` (nil: a kind out of range or the wrong size, which
// is how bytes from the network that don't match the build read back on every peer).
union_value :: proc(kind: int, bytes: []u8, $U: typeid) -> (value: U) {
	variants := union_variants(U)
	if kind < 0 || kind >= len(variants) || len(bytes) != variants[kind].size {
		return
	}
	info := runtime.type_info_base(type_info_of(U)).variant.(runtime.Type_Info_Union)
	runtime.mem_copy_non_overlapping(&value, raw_data(bytes), len(bytes))
	tag := uintptr(&value) + info.tag_offset
	switch info.tag_type.size { 	// the tag of variant `kind` is kind + 1 (0 is nil)
	case 1:
		(^u8)(tag)^ = u8(kind + 1)
	case 2:
		(^u16)(tag)^ = u16(kind + 1)
	case 4:
		(^u32)(tag)^ = u32(kind + 1)
	case:
		(^u64)(tag)^ = u64(kind + 1)
	}
	return
}

// The XXH3 of a union's variants (names and layouts), for compat_of (0 for nil).
@(private)
union_hash :: proc(type: typeid, prefix: string) -> u64 {
	variants := union_variants(type)
	if len(variants) == 0 do return 0
	bytes := make([dynamic]u8, 0, 64 * len(variants), context.temp_allocator)
	for variant in variants {
		append(&bytes, ..transmute([]u8)variant_name(variant, prefix))
		layout := transmute([8]u8)u64le(layout_hash_of(variant))
		append(&bytes, ..layout[:])
	}
	return hash_bytes(bytes[:])
}
