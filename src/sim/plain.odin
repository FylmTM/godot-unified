// Plain-data check and layout hash for state blocks and inputs, by walking Odin's runtime type
// info. Odin has no compile-time "is plain data" trait (type intrinsics work on one type at a
// time, with no loop over fields), so `create` runs the check once and `odin test` runs it too.
package sim

import "base:runtime"
import "core:fmt"
import "core:strings"

// Returns "" if values of the type are plain data that can be memcpy'd, hashed as bytes and sent
// to another machine: integers, floats, bools, enums, bit_sets, fixed arrays and structs of those,
// with no implicit padding anywhere (so the bytes are fully defined). Otherwise, the reason.
plain_violation :: proc(type: ^runtime.Type_Info, path: string = "") -> string {
	#partial switch variant in type.variant {
	case runtime.Type_Info_Named:
		return plain_violation(variant.base, path)
	case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Boolean:
		return ""
	case runtime.Type_Info_Enum:
		return plain_violation(variant.base, path)
	case runtime.Type_Info_Bit_Set:
		if variant.underlying == nil {
			return fmt.tprintf("%s: bit_set without an explicit backing integer", path)
		}
		return ""
	case runtime.Type_Info_Array:
		return plain_violation(variant.elem, path)
	case runtime.Type_Info_Enumerated_Array:
		if variant.is_sparse {
			return fmt.tprintf("%s: sparse enumerated array", path)
		}
		return plain_violation(variant.elem, path)
	case runtime.Type_Info_Struct:
		if .raw_union in variant.flags {
			return fmt.tprintf("%s: raw union", path)
		}
		end := uintptr(0)
		for i in 0 ..< int(variant.field_count) {
			name := fmt.tprintf("%s.%s", path, variant.names[i])
			if variant.offsets[i] != end {
				return fmt.tprintf("%s: implicit padding before this field", name)
			}
			if reason := plain_violation(variant.types[i], name); reason != "" {
				return reason
			}
			end = variant.offsets[i] + uintptr(variant.types[i].size)
		}
		if end != uintptr(type.size) {
			return fmt.tprintf("%s: implicit padding at the end", path)
		}
		return ""
	}
	return fmt.tprintf("%s: %v is not plain data", path, type.id)
}

// Panics unless T is plain data (see plain_violation).
check_plain :: proc($T: typeid) {
	check_plain_of(type_info_of(T))
}

// Panics unless the type is plain data, for a type known only at run time (check_plain's RTTI form).
check_plain_of :: proc(type: ^runtime.Type_Info) {
	if reason := plain_violation(type, fmt.tprint(type.id)); reason != "" {
		fmt.panicf("%v is not plain data: %s", type.id, reason)
	}
}

// XXH3 of the type's layout (field names, types, offsets and sizes, recursively). Snapshots carry
// it, so bytes from a build with another state layout are rejected instead of misread.
layout_hash :: proc($T: typeid) -> u64 {
	return layout_hash_of(type_info_of(T))
}

// The layout hash of a type known only at run time (layout_hash's RTTI form); union variants are hashed with it.
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
