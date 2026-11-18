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
@(private)
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
// (not #no_nil, not #shared_nil), at most 255 variants, each plain data (plain_violation; events: padding allowed,
// padded_violation) of 1..max_size bytes, names unique.
union_violation :: proc(type: typeid, max_size: int, prefix: string, padding := false) -> string {
	if type == nil do return ""
	info, ok := runtime.type_info_base(type_info_of(type)).variant.(runtime.Type_Info_Union)
	if !ok do return fmt.tprintf("%v is not a union", type)
	if info.no_nil || info.shared_nil do return fmt.tprintf("%v: #no_nil and #shared_nil unions can't be read back", type)
	if len(info.variants) > 255 do return fmt.tprintf("%v: %d variants (at most 255)", type, len(info.variants))
	for variant, i in info.variants {
		name := variant_name(variant, prefix)
		check := padding ? padded_violation : plain_violation
		if reason := check(variant, fmt.tprint(variant.id)); reason != "" {
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

// The union value of kind `kind` made of `bytes` (nil: a kind out of range or the wrong size, which is how bytes from
// the network that don't match the build read back on every peer). The bytes come from another machine, so they are
// read as the wire rule says (wire_fix): every bool reads back as 0 or 1 and every bit_set holds only its own
// elements, and an enum field outside its declared values or a float that is not finite makes the whole value nil, so
// every peer leaves it out alike instead of indexing a table with it.
@(private)
union_value :: proc(kind: int, bytes: []u8, $U: typeid) -> (value: U) {
	variants := union_variants(U)
	if kind < 0 || kind >= len(variants) || len(bytes) != variants[kind].size {
		return
	}
	info := runtime.type_info_base(type_info_of(U)).variant.(runtime.Type_Info_Union)
	runtime.mem_copy_non_overlapping(&value, raw_data(bytes), len(bytes))
	if _, rejected := wire_fix(&value, variants[kind], .Command, apply = true); rejected {
		return {}
	}
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

// What a value from another machine is read as (wire_fix).
@(private)
Wire_Kind :: enum u8 {
	Command, // an enum outside its values or a non-finite float rejects the whole command
	Input, // an enum outside its values reads as its zero value (an Input holds no floats or bools)
}

// Reads a plain value from another machine the way every peer reads it, in place when `apply`: a bool as 0 or 1, a
// bit_set without the bits of no element, and per `kind` an enum outside its declared values (zeroed for an Input,
// `rejected` for a command) and a non-finite float (`rejected`). `changed`: the value is not already so (with `apply`
// false, a check that writes nothing).
@(private)
wire_fix :: proc(data: rawptr, type: ^runtime.Type_Info, kind: Wire_Kind, apply: bool) -> (changed, rejected: bool) {
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Boolean:
		bytes := ([^]u8)(data)[:type.size]
		set := false
		for b in bytes do set ||= b != 0
		for b, i in bytes do changed ||= b != (u8(set) if i == 0 else 0) // little-endian: the low byte holds 1
		if changed && apply {
			runtime.mem_zero(data, type.size)
			bytes[0] = u8(set)
		}
	case runtime.Type_Info_Float:
		bits := (^u32)(data)^ // f32 only (plain_violation)
		rejected = bits & 0x7F80_0000 == 0x7F80_0000 // an infinity or a NaN
	case runtime.Type_Info_Enum:
		value := read_integer(data, info.base)
		declared := false
		for allowed in info.values do declared ||= i64(allowed) == value
		if !declared {
			changed = true
			if kind == .Command do rejected = true
			else if apply do runtime.mem_zero(data, type.size)
		}
	case runtime.Type_Info_Bit_Set:
		bytes := ([^]u8)(data)[:type.size]
		for i in 0 ..< type.size * 8 {
			if bytes[i / 8] & (1 << uint(i % 8)) == 0 || bit_set_holds(info, info.lower + i64(i)) do continue
			changed = true
			if apply do bytes[i / 8] &~= 1 << uint(i % 8)
		}
	case runtime.Type_Info_Array:
		for i in 0 ..< info.count {
			c, r := wire_fix(rawptr(uintptr(data) + uintptr(i * info.elem_size)), info.elem, kind, apply)
			changed, rejected = changed || c, rejected || r
		}
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< info.count {
			c, r := wire_fix(rawptr(uintptr(data) + uintptr(i * info.elem_size)), info.elem, kind, apply)
			changed, rejected = changed || c, rejected || r
		}
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(info.field_count) {
			c, r := wire_fix(rawptr(uintptr(data) + info.offsets[i]), info.types[i], kind, apply)
			changed, rejected = changed || c, rejected || r
		}
	}
	return
}

// Whether `element` is one of a bit_set's elements: a declared value of its enum, else in its range.
@(private)
bit_set_holds :: proc(info: runtime.Type_Info_Bit_Set, element: i64) -> bool {
	if element > info.upper do return false
	if values, is_enum := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Enum); is_enum {
		for value in values.values do if i64(value) == element do return true
		return false
	}
	return true
}

// An integer of `type` (a sized integer: plain_violation) at `data`, as i64.
@(private)
read_integer :: proc(data: rawptr, type: ^runtime.Type_Info) -> i64 {
	integer := runtime.type_info_base(type).variant.(runtime.Type_Info_Integer)
	switch type.size {
	case 1:
		return i64((^i8)(data)^) if integer.signed else i64((^u8)(data)^)
	case 2:
		return i64((^i16)(data)^) if integer.signed else i64((^u16)(data)^)
	case 4:
		return i64((^i32)(data)^) if integer.signed else i64((^u32)(data)^)
	}
	return (^i64)(data)^
}

// Whether a value of `type` holds anything wire_fix may change in an Input: an enum or a bit_set (step reads every
// slot's Input through it only then).
@(private)
wire_fixable :: proc(type: ^runtime.Type_Info) -> bool {
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Enum, runtime.Type_Info_Bit_Set, runtime.Type_Info_Boolean:
		return true
	case runtime.Type_Info_Array:
		return wire_fixable(info.elem)
	case runtime.Type_Info_Enumerated_Array:
		return wire_fixable(info.elem)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(info.field_count) {
			if wire_fixable(info.types[i]) do return true
		}
	}
	return false
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
