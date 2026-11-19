// Plain-data check and layout hash for state blocks and inputs, by walking Odin's runtime type
// info. Odin has no compile-time "is plain data" trait (type intrinsics work on one type at a
// time, with no loop over fields), so `create` runs the check once and `odin test` runs it too.
package sim

import "base:runtime"
import "core:fmt"
import "core:strings"

// Returns "" if values of the type are plain data that can be memcpy'd, hashed as bytes and sent
// to another machine: fixed-size integers (not int, uint or uintptr, whose size is the platform's), f32
// (the sim is f32 only), bools, enums, bit_sets, fixed arrays and structs of those, with no implicit
// padding anywhere (so the bytes are fully defined). Otherwise, the reason. The state block's rule.
plain_violation :: proc(type: ^runtime.Type_Info, path: string = "") -> string {
	return plain_check(type, path, bools = true, floats = true)
}

// plain_violation that allows padding: the rule for an event, which is never hashed or compared as bytes.
@(private)
padded_violation :: proc(type: ^runtime.Type_Info, path: string = "") -> string {
	return plain_check(type, path, bools = true, floats = true, padding = true)
}

// plain_violation without bools or floats, and every enum with a member of value 0: the rule for a tick's Input,
// which comes from another machine and is compared and logged as raw bytes. A bool's byte can hold values other than
// 0 and 1 there, which Odin's bool operations don't define (a u8 of flags or a bit_set says the same with every byte
// value defined); a float can be a NaN or an infinity a sim never expects (quantize: an i8 axis, dmath's direction
// encodings). An undeclared enum value reads as 0, and an absent player's input is all zeros: 0 must be declared.
wire_violation :: proc(type: ^runtime.Type_Info, path: string = "") -> string {
	return plain_check(type, path, bools = false, floats = false, zero_enums = true)
}

@(private)
plain_check :: proc(
	type: ^runtime.Type_Info,
	path: string,
	bools: bool,
	floats: bool,
	padding := false,
	zero_enums := false, // every enum declares a member of value 0
	named: ^runtime.Type_Info = nil, // the named type, when `type` is its base: the padding errors name it
) -> string {
	#partial switch variant in type.variant {
	case runtime.Type_Info_Named:
		return plain_check(variant.base, path, bools, floats, padding, zero_enums, type)
	case runtime.Type_Info_Integer:
		if type.id == int || type.id == uint || type.id == uintptr {
			return fmt.tprintf("%s: %v is platform-sized (use a sized integer: i32, u64, ...)", path, type.id)
		}
		return ""
	case runtime.Type_Info_Float:
		if !floats {
			return fmt.tprintf(
				"%s: %v (an input is quantized: a float from another machine may be a NaN; use an integer, e.g. an i8 axis or a dmath direction)",
				path,
				type.id,
			)
		}
		if type.size != 4 {
			return fmt.tprintf("%s: %v (the simulation is f32 only)", path, type.id)
		}
		return ""
	case runtime.Type_Info_Boolean:
		if !bools {
			return fmt.tprintf(
				"%s: %v (a bool's byte from another machine may be neither 0 nor 1: use u8 flags or a bit_set)",
				path,
				type.id,
			)
		}
		return ""
	case runtime.Type_Info_Enum:
		if zero_enums && !enum_declares(variant, 0) {
			return fmt.tprintf(
				"%s: %v declares no member of value 0 (an undeclared value from another machine, and an absent player's input, read as 0)",
				path,
				named != nil ? named.id : type.id,
			)
		}
		return plain_check(variant.base, path, bools, floats, padding, zero_enums)
	case runtime.Type_Info_Bit_Set:
		if variant.underlying == nil {
			return fmt.tprintf("%s: bit_set without an explicit backing integer", path)
		}
		return plain_check(variant.underlying, path, bools, floats, padding, zero_enums)
	case runtime.Type_Info_Array:
		return plain_check(variant.elem, path, bools, floats, padding, zero_enums)
	case runtime.Type_Info_Enumerated_Array:
		if variant.is_sparse {
			return fmt.tprintf("%s: sparse enumerated array", path)
		}
		return plain_check(variant.elem, path, bools, floats, padding, zero_enums)
	case runtime.Type_Info_Struct:
		if .raw_union in variant.flags {
			return fmt.tprintf("%s: raw union", path)
		}
		struct_name := named != nil ? fmt.tprint(named.id) : "the struct"
		end := uintptr(0)
		for i in 0 ..< int(variant.field_count) {
			name := fmt.tprintf("%s.%s", path, variant.names[i])
			if !padding && variant.offsets[i] != end {
				return fmt.tprintf(
					"%s: %s has %d bytes of implicit padding before this field (add `_pad: [%d]u8` before it, or reorder)",
					name,
					struct_name,
					variant.offsets[i] - end,
					variant.offsets[i] - end,
				)
			}
			if reason := plain_check(variant.types[i], name, bools, floats, padding, zero_enums); reason != "" {
				return reason
			}
			end = variant.offsets[i] + uintptr(variant.types[i].size)
		}
		if !padding && end != uintptr(type.size) {
			return fmt.tprintf(
				"%s: %s has %d bytes of implicit padding at its end (add `_pad: [%d]u8` as its last field)",
				path,
				struct_name,
				uintptr(type.size) - end,
				uintptr(type.size) - end,
			)
		}
		return ""
	}
	return fmt.tprintf("%s: %v is not plain data", path, type.id)
}

// Panics unless T is plain data without bools or floats (see wire_violation): what the netcode client and the relay
// check an Input with.
check_wire :: proc($T: typeid) {
	if reason := wire_violation(type_info_of(T), fmt.tprint(typeid_of(T))); reason != "" {
		fmt.panicf("%v can't be sent between machines: %s", typeid_of(T), reason)
	}
}

// XXH3 of the type's layout (field names, types, offsets and sizes, recursively). Snapshots carry
// it, so bytes from a build with another state layout are rejected instead of misread.
layout_hash :: proc($T: typeid) -> u64 {
	return layout_hash_of(type_info_of(T))
}

// The layout hash of a type known only at run time (layout_hash's RTTI form); union variants are hashed with it.
@(private)
layout_hash_of :: proc(type: ^runtime.Type_Info) -> u64 {
	builder := strings.builder_make(context.temp_allocator)
	layout_text(&builder, type)
	return hash_bytes(builder.buf[:])
}

@(private)
layout_text :: proc(builder: ^strings.Builder, type: ^runtime.Type_Info) {
	#partial switch variant in type.variant {
	case runtime.Type_Info_Named:
		layout_text(builder, variant.base)
	case runtime.Type_Info_Struct:
		strings.write_byte(builder, '{')
		for i in 0 ..< int(variant.field_count) {
			fmt.sbprintf(builder, "%s@%d:", variant.names[i], variant.offsets[i])
			layout_text(builder, variant.types[i])
			strings.write_byte(builder, ';')
		}
		fmt.sbprintf(builder, "}%d", type.size)
	case runtime.Type_Info_Array:
		fmt.sbprintf(builder, "[%d]", variant.count)
		layout_text(builder, variant.elem)
	case runtime.Type_Info_Enumerated_Array:
		fmt.sbprintf(builder, "[%d]", variant.count)
		layout_text(builder, variant.elem)
	case:
		fmt.sbprintf(builder, "%v", type.id)
	}
}
