// The NaN rule's check (src/dmath/README.md): a NaN made at run time has each platform's own bits
// (x64 sets the sign, arm64 doesn't), so a NaN in the block gives peers on different CPUs different checksums. No NaN
// may reach the block; the sync-test looks for one after every step (headless.Run).
package sim

import "base:builtin"
import "base:runtime"
import "core:fmt"

// Where a NaN is in the state block: "" when there is none, else the first one's field and bits ("tick 40:
// enemies[12].pos.x is a NaN (ffc00000)"; temp-allocated). `floats` keeps the State's float offsets between calls
// (the first call fills it from the State's RTTI; the caller deletes it). Reads every f32 of the block, items of dead
// table slots too: they are hashed like the rest.
find_nan :: proc(simulation: ^Sim($G), floats: ^[dynamic]u32) -> string {
	State :: part(G, GAME_STATE)
	if len(floats) == 0 do float_offsets(type_info_of(State), 0, floats)
	block := ([^]u8)(&simulation.state)
	for offset in floats {
		bits := (^u32)(&block[offset])^
		if bits & 0x7F80_0000 == 0x7F80_0000 && bits & 0x007F_FFFF != 0 {
			return fmt.tprintf(
				"tick %d: %s is a NaN (%08x)",
				simulation.tick,
				field_path(type_info_of(State), block[:size_of(State)], int(offset)),
				bits,
			)
		}
	}
	return ""
}

// Appends the offset of every f32 in a value of `type` at `base` (fields, arrays, enumerated arrays), in order.
@(private)
float_offsets :: proc(type: ^runtime.Type_Info, base: u32, out: ^[dynamic]u32) {
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Float:
		builtin.append(out, base)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(info.field_count) {
			float_offsets(info.types[i], base + u32(info.offsets[i]), out)
		}
	case runtime.Type_Info_Array:
		if !has_float(info.elem) do return
		for i in 0 ..< info.count {
			float_offsets(info.elem, base + u32(i * info.elem_size), out)
		}
	case runtime.Type_Info_Enumerated_Array:
		if !has_float(info.elem) do return
		for i in 0 ..< info.count {
			float_offsets(info.elem, base + u32(i * info.elem_size), out)
		}
	}
}

// Whether a value of `type` holds an f32 anywhere (float_offsets skips arrays of integers whole).
@(private)
has_float :: proc(type: ^runtime.Type_Info) -> bool {
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Float:
		return true
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(info.field_count) {
			if has_float(info.types[i]) do return true
		}
	case runtime.Type_Info_Array:
		return has_float(info.elem)
	case runtime.Type_Info_Enumerated_Array:
		return has_float(info.elem)
	}
	return false
}

// The path of the leaf field at byte `offset` of `value` (the bytes of a value of `type`), named as the desync report
// names it (snapshot_diff): "enemies[12].pos.x", a table and a List read by item index, a Queue's items oldest first.
// Temp-allocated.
@(private)
field_path :: proc(type: ^runtime.Type_Info, value: []u8, offset: int, path := "") -> string {
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Struct:
		// A sim.Table (items and slots, as snapshot_diff tells), List or Queue: its items read as its own elements.
		kind := collection_kind(type)
		table := kind == .List || kind == .Queue
		for i in 0 ..< int(info.field_count) {
			array, is_array := info.types[i].variant.(runtime.Type_Info_Array)
			table ||= info.names[i] == "slots" && is_array && array.elem.id == Slot
		}
		for i in 0 ..< int(info.field_count) {
			start := int(info.offsets[i])
			if offset < start || offset >= start + info.types[i].size do continue
			field := value[start:][:info.types[i].size]
			if kind == .Queue && info.names[i] == "items" {
				array := runtime.type_info_base(info.types[i]).variant.(runtime.Type_Info_Array)
				k := (offset - start) / array.elem_size
				oldest_first := (k - collection_field(info, value, "head")) %% array.count
				return field_path(
					array.elem,
					field[k * array.elem_size:][:array.elem_size],
					offset - start - k * array.elem_size,
					fmt.tprintf("%s[%d]", path, oldest_first),
				)
			}
			if table && info.names[i] == "items" {
				return field_path(info.types[i], field, offset - start, path)
			}
			name := info.names[i] if path == "" else fmt.tprintf("%s.%s", path, info.names[i])
			return field_path(info.types[i], field, offset - start, name)
		}
	case runtime.Type_Info_Array:
		k := offset / info.elem_size
		item := value[k * info.elem_size:][:info.elem_size]
		return field_path(info.elem, item, offset - k * info.elem_size, fmt.tprintf("%s[%d]", path, k))
	case runtime.Type_Info_Enumerated_Array:
		k := offset / info.elem_size
		item := value[k * info.elem_size:][:info.elem_size]
		return field_path(info.elem, item, offset - k * info.elem_size, fmt.tprintf("%s[%d]", path, k))
	}
	return path
}
