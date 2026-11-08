// Pointer-freedom and layout check for the state block, by walking Odin's runtime type info.
// Odin has no compile-time "is POD" trait (type intrinsics work on one type at a time, with no
// loop over fields), so this runs once at startup and in `odin test`.
package pod

import "base:runtime"
import "core:fmt"

// Returns "" if values of the type are plain data that can be memcpy'd, hashed as bytes and sent
// to another machine: integers, floats, bools, enums, fixed arrays and structs of those, with no
// implicit padding anywhere (so the bytes are fully defined). Otherwise, the reason.
violation :: proc(ti: ^runtime.Type_Info, path: string = "") -> string {
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		return violation(v.base, path)
	case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Boolean:
		return ""
	case runtime.Type_Info_Enum:
		return violation(v.base, path)
	case runtime.Type_Info_Array:
		return violation(v.elem, path)
	case runtime.Type_Info_Enumerated_Array:
		if v.is_sparse {
			return fmt.tprintf("%s: sparse enumerated array", path)
		}
		return violation(v.elem, path)
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
			if r := violation(v.types[i], name); r != "" {
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

check :: proc($T: typeid) {
	if r := violation(type_info_of(T), fmt.tprint(typeid_of(T))); r != "" {
		fmt.panicf("state block is not plain data: %s", r)
	}
}
