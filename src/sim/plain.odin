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
plain_violation :: proc(ti: ^runtime.Type_Info, path: string = "") -> string {
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		return plain_violation(v.base, path)
	case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Boolean:
		return ""
	case runtime.Type_Info_Enum:
		return plain_violation(v.base, path)
	case runtime.Type_Info_Bit_Set:
		if v.underlying == nil {
			return fmt.tprintf("%s: bit_set without an explicit backing integer", path)
		}
		return ""
	case runtime.Type_Info_Array:
		return plain_violation(v.elem, path)
	case runtime.Type_Info_Enumerated_Array:
		if v.is_sparse {
			return fmt.tprintf("%s: sparse enumerated array", path)
		}
		return plain_violation(v.elem, path)
	case runtime.Type_Info_Struct:
		if .raw_union in v.flags {
			return fmt.tprintf("%s: raw union", path)
		}
		end := uintptr(0)
		for i in 0 ..< int(v.field_count) {
			name := fmt.tprintf("%s.%s", path, v.names[i])
			if v.offsets[i] != end {
				return fmt.tprintf("%s: implicit padding before this field", name)
			}
			if r := plain_violation(v.types[i], name); r != "" {
				return r
			}
			end = v.offsets[i] + uintptr(v.types[i].size)
		}
		if end != uintptr(ti.size) {
			return fmt.tprintf("%s: implicit padding at the end", path)
		}
		return ""
	}
	return fmt.tprintf("%s: %v is not plain data", path, ti.id)
}

// Panics unless T is plain data (see plain_violation).
check_plain :: proc($T: typeid) {
	check_plain_of(type_info_of(T))
}

check_plain_of :: proc(ti: ^runtime.Type_Info) {
	if r := plain_violation(ti, fmt.tprint(ti.id)); r != "" {
		fmt.panicf("%v is not plain data: %s", ti.id, r)
	}
}

// XXH3 of the type's layout (field names, types, offsets and sizes, recursively). Snapshots carry
// it, so bytes from a build with another state layout are rejected instead of misread.
layout_hash :: proc($T: typeid) -> u64 {
	return layout_hash_of(type_info_of(T))
}

layout_hash_of :: proc(ti: ^runtime.Type_Info) -> u64 {
	b := strings.builder_make(context.temp_allocator)
	layout_text(&b, ti)
	return hash_bytes(b.buf[:])
}

@(private)
layout_text :: proc(b: ^strings.Builder, ti: ^runtime.Type_Info) {
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		layout_text(b, v.base)
	case runtime.Type_Info_Struct:
		strings.write_byte(b, '{')
		for i in 0 ..< int(v.field_count) {
			fmt.sbprintf(b, "%s@%d:", v.names[i], v.offsets[i])
			layout_text(b, v.types[i])
			strings.write_byte(b, ';')
		}
		fmt.sbprintf(b, "}%d", ti.size)
	case runtime.Type_Info_Array:
		fmt.sbprintf(b, "[%d]", v.count)
		layout_text(b, v.elem)
	case runtime.Type_Info_Enumerated_Array:
		fmt.sbprintf(b, "[%d]", v.count)
		layout_text(b, v.elem)
	case:
		fmt.sbprintf(b, "%v", ti.id)
	}
}
