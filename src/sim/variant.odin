// A game declares its commands and events as unions of plain structs (src/sim/README.md, Commands,
// Events). On the wire, in the log and in the ring each value is its kind (the variant's index in
// the union) and its struct's bytes; these helpers go between the two by RTTI.
package sim

import "base:builtin"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

COMMAND_PREFIX :: "Command_" // a command's name is its type name without it, lowercased
EVENT_PREFIX :: "Event_" // an event's name is its type name without it (when it has it), lowercased

// The union's variants (nil for a nil typeid).
union_variants :: proc(type: typeid) -> []^runtime.Type_Info {
	if type == nil do return nil
	info, ok := runtime.type_info_base(type_info_of(type)).variant.(runtime.Type_Info_Union)
	return info.variants if ok else nil
}

// A variant's kind (its index in the union), -1 when `variant` is not one of them.
@(private)
variant_kind :: proc(type: typeid, variant: typeid) -> int {
	for candidate, i in union_variants(type) {
		if candidate.id == variant do return i
	}
	return -1
}

// A variant's name: its type name without `prefix`, lowercased ("Command_Drop_Coin" -> "drop_coin",
// "Event_Coin_Picked" and "Coin_Picked" -> "coin_picked"). Temp-allocated.
variant_name :: proc(type: ^runtime.Type_Info, prefix: string) -> string {
	name := fmt.tprint(type.id)
	if named, ok := type.variant.(runtime.Type_Info_Named); ok do name = named.name
	return strings.to_lower(strings.trim_prefix(name, prefix), context.temp_allocator)
}

// Why a union can't be a command or event union ("" when it can, or when `type` is nil): a union
// (not #no_nil, not #shared_nil), at most 255 variants, each plain data (plain_violation; events: padding allowed,
// padded_violation) of min_size..max_size bytes (a command may be empty: `Command_Start :: struct {}`), names unique.
@(private)
union_violation :: proc(type: typeid, min_size, max_size: int, prefix: string, padding := false) -> string {
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
		if variant.size > max_size || variant.size < min_size {
			return fmt.tprintf("%q: %d bytes (%d..%d)", name, variant.size, min_size, max_size)
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
	if len(bytes) > 0 do runtime.mem_copy_non_overlapping(&value, raw_data(bytes), len(bytes)) // an empty command: none
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

// The kind (variant index) a union value holds: union_value's inverse (-1: nil).
@(private)
union_kind :: proc(value: ^$U) -> int where intrinsics.type_is_union(U) {
	info := runtime.type_info_base(type_info_of(U)).variant.(runtime.Type_Info_Union)
	if len(info.variants) == 0 do return -1
	tag := uintptr(value) + info.tag_offset
	stored: u64
	switch info.tag_type.size {
	case 1:
		stored = u64((^u8)(tag)^)
	case 2:
		stored = u64((^u16)(tag)^)
	case 4:
		stored = u64((^u32)(tag)^)
	case:
		stored = (^u64)(tag)^
	}
	return int(stored) - 1 // the tag of variant `kind` is kind + 1 (0 is nil)
}

// What a value from another machine is read as (wire_fix).
@(private)
Wire_Kind :: enum u8 {
	Command, // an enum outside its values or a non-finite float rejects the whole command
	Input, // an enum outside its values reads as 0, a declared member (wire_violation; an Input holds no floats or bools)
}

// Reads a plain value from another machine the way every peer reads it, in place when `apply`: a bool as 0 or 1, a
// bit_set without the bits of no element, a sim.Bits without its bits past N, and per `kind` an enum outside its
// declared values and a List or Queue past its capacity (zeroed for an Input, `rejected` for a command) and a
// non-finite float (`rejected`). `changed`: the value is not already so (with `apply` false, a check that writes
// nothing).
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
		if !enum_declares(info, read_integer(data, info.base)) {
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
		if collection := collection_kind(type); collection != .None {
			changed, rejected = collection_fix(data, type, collection, kind, apply)
		}
		for i in 0 ..< int(info.field_count) {
			c, r := wire_fix(rawptr(uintptr(data) + info.offsets[i]), info.types[i], kind, apply)
			changed, rejected = changed || c, rejected || r
		}
	}
	return
}

// wire_fix of a collection's own fields: a List's or Queue's count past its capacity (a Queue's head too) is
// `rejected` for a command and empties it for an Input; a Bits' bit past N reads as clear, as a bit_set's bit of no
// element does. What no honest peer sends, and what would index past a table on every peer.
@(private)
collection_fix :: proc(
	data: rawptr,
	type: ^runtime.Type_Info,
	collection: Collection,
	kind: Wire_Kind,
	apply: bool,
) -> (
	changed, rejected: bool,
) {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	last := int(info.field_count) - 1
	if collection == .Bits {
		words := ([^]u8)(rawptr(uintptr(data) + info.offsets[last]))
		for bit in bits_capacity(type) ..< info.types[last].size * 8 {
			if words[bit / 8] & (1 << uint(bit % 8)) == 0 do continue
			changed = true
			if apply do words[bit / 8] &~= 1 << uint(bit % 8)
		}
		return
	}
	if wire_count_holds(wire_count_of(type, 0), data) do return
	changed = true
	if kind == .Command do rejected = true
	else if apply do runtime.mem_zero(data, type.size)
	return
}

// Where a List's or Queue's count and head are (`head` -1: a List's, none), as wide as they are, and its capacity.
@(private)
Wire_Count :: struct {
	count, head: int, // offsets in the value checked
	size:        int, // bytes of each
	capacity:    u64,
}

// The Wire_Count of a List or Queue of `type` at `offset`.
@(private)
wire_count_of :: proc(type: ^runtime.Type_Info, offset: int) -> (count: Wire_Count) {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	count.head = -1
	for i in 0 ..< int(info.field_count) {
		switch info.names[i] {
		case "count":
			count.count, count.size = offset + int(info.offsets[i]), info.types[i].size
		case "head":
			count.head = offset + int(info.offsets[i])
		}
	}
	last := int(info.field_count) - 1
	count.capacity = u64(runtime.type_info_base(info.types[last]).variant.(runtime.Type_Info_Array).count)
	return
}

// Whether a List's or Queue's count is at most its capacity and its head below it, read unsigned at its width (a
// u64 count with its top bit set is past any capacity, never negative).
@(private)
wire_count_holds :: #force_inline proc(count: Wire_Count, data: rawptr) -> bool {
	unsigned :: #force_inline proc(data: rawptr, offset, size: int) -> (value: u64) {
		bytes := ([^]u8)(data)[offset:][:size]
		for b, k in bytes do value |= u64(b) << uint(8 * k)
		return
	}
	if unsigned(data, count.count, count.size) > count.capacity do return false
	return count.head < 0 || unsigned(data, count.head, count.size) < count.capacity
}

// N of a sim.Bits(N): the number its type's name ends in (the words round it up to 64).
@(private)
bits_capacity :: proc(type: ^runtime.Type_Info) -> int {
	name := type.variant.(runtime.Type_Info_Named).name
	close := strings.last_index_byte(name, ')')
	start := close
	for start > 0 && name[start - 1] >= '0' && name[start - 1] <= '9' do start -= 1
	capacity, _ := strconv.parse_int(name[start:close], 10)
	return capacity
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

// Whether `value` is one of an enum's declared values.
@(private)
enum_declares :: proc(info: runtime.Type_Info_Enum, value: i64) -> bool {
	for declared in info.values do if i64(declared) == value do return true
	return false
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

// An Input's wire rules (wire_fix's for an Input) compiled once at create: the bits each byte may hold, the enum
// fields and the collections' counts, so a step checks a slot with a mask and a compare per enum and count instead of
// walking the type info.
@(private)
Wire_Check :: struct {
	allowed: []u8, // per byte of the Input: the bits a value may set (a bit_set's elements', a bool's low bit; any)
	enums:   [dynamic]Wire_Enum,
	any:     bool, // there is something to check: an enum, a bit a value may not set, a count
	counts:  [dynamic]Wire_Count, // the Input's Lists and Queues: a count past the capacity no mask says
}

// An enum field of an Input, by its offset.
@(private)
Wire_Enum :: struct {
	offset:    int,
	base:      ^runtime.Type_Info, // its backing integer
	info:      runtime.Type_Info_Enum,
	low, high: i64, // its least and greatest declared values
	dense:     bool, // every value from low to high is declared: a range check
}

// The Wire_Check of `type` (delete with wire_check_destroy).
@(private)
wire_check_make :: proc(type: ^runtime.Type_Info) -> (check: Wire_Check) {
	check.allowed = make([]u8, type.size)
	for &bits in check.allowed do bits = 0xFF
	wire_compile(&check, type, 0)
	for bits in check.allowed do check.any ||= bits != 0xFF
	check.any ||= len(check.enums) > 0 || len(check.counts) > 0
	return
}

@(private)
wire_check_destroy :: proc(check: ^Wire_Check) {
	delete(check.allowed)
	delete(check.enums)
	delete(check.counts)
}

@(private)
wire_compile :: proc(check: ^Wire_Check, type: ^runtime.Type_Info, offset: int) {
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Boolean:
		for i in 0 ..< type.size do check.allowed[offset + i] = 1 if i == 0 else 0 // little-endian: the low byte holds 1
	case runtime.Type_Info_Enum:
		field := Wire_Enum {
			offset = offset,
			base   = info.base,
			info   = info,
			low    = max(i64),
			high   = min(i64),
		}
		for value in info.values {
			if i64(value) < field.low do field.low = i64(value)
			if i64(value) > field.high do field.high = i64(value)
		}
		field.dense = len(info.values) > 0 && field.high - field.low < 256
		for value := field.low; field.dense && value <= field.high; value += 1 {
			field.dense = enum_declares(info, value)
		}
		builtin.append(&check.enums, field)
	case runtime.Type_Info_Bit_Set:
		for i in 0 ..< type.size * 8 {
			if !bit_set_holds(info, info.lower + i64(i)) do check.allowed[offset + i / 8] &~= 1 << uint(i % 8)
		}
	case runtime.Type_Info_Array:
		for i in 0 ..< info.count do wire_compile(check, info.elem, offset + i * info.elem_size)
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< info.count do wire_compile(check, info.elem, offset + i * info.elem_size)
	case runtime.Type_Info_Struct:
		switch collection_kind(type) {
		case .Bits:
			words := offset + int(info.offsets[0])
			for bit in bits_capacity(type) ..< info.types[0].size * 8 do check.allowed[words + bit / 8] &~= 1 << uint(bit % 8)
		case .List, .Queue:
			builtin.append(&check.counts, wire_count_of(type, offset))
		case .None:
		}
		for i in 0 ..< int(info.field_count) do wire_compile(check, info.types[i], offset + int(info.offsets[i]))
	}
}

// Whether an Input reads as it was sent: what wire_fix(.Input, apply = false) says when it changes nothing.
@(private)
wire_reads_as_sent :: #force_inline proc(check: ^Wire_Check, data: rawptr) -> bool {
	bytes := ([^]u8)(data)
	stray: u8
	for allowed, i in check.allowed do stray |= bytes[i] &~ allowed
	if stray != 0 do return false
	for &field in check.enums {
		value := read_integer(rawptr(uintptr(data) + uintptr(field.offset)), field.base)
		if field.dense ? value < field.low || value > field.high : !enum_declares(field.info, value) do return false
	}
	for count in check.counts do if !wire_count_holds(count, data) do return false
	return true
}

// The XXH3 of a union's variants (names and layouts), for compat_of (0 for nil).
@(private)
union_hash :: proc(type: typeid, prefix: string) -> u64 {
	variants := union_variants(type)
	if len(variants) == 0 do return 0
	bytes := make([dynamic]u8, 0, 64 * len(variants), context.temp_allocator)
	for variant in variants {
		builtin.append(&bytes, ..transmute([]u8)variant_name(variant, prefix))
		layout := transmute([8]u8)u64le(layout_hash_of(variant))
		builtin.append(&bytes, ..layout[:])
	}
	return hash_bytes(bytes[:])
}
