// Discovers a state block's tables by walking its RTTI once: every field whose type is a
// Table(T, N) is a table of entities of type T (recognised by shape: `items: [N]T` and
// `slots: [N]Slot`); a fixed array of structs is a table whose elements are all live; anything
// else is a global. Inspectors, desync diffs and dumps build on this without per-type code.
package sim

import "base:runtime"

Table_Info :: struct {
	name:      string,
	elem:      ^runtime.Type_Info, // the entity type
	cap:       int,
	items_off: int, // byte offset of items[0] in the state
	slots_off: int, // byte offset of slots[0], or -1 for a fixed array
}

Global_Info :: struct {
	name: string,
	type: ^runtime.Type_Info,
	off:  int,
}

Schema :: struct {
	tables:  [dynamic]Table_Info,
	globals: [dynamic]Global_Info,
}

// Built once per state type and kept for the program's lifetime (not thread-safe on first call).
schema_of :: proc($State: typeid) -> ^Schema {
	@(static) cached: Schema
	@(static) built: bool
	if !built {
		build_schema(&cached, type_info_of(State))
		built = true
	}
	return &cached
}

build_schema :: proc(out: ^Schema, type: ^runtime.Type_Info) {
	context.allocator = runtime.heap_allocator()
	struct_info, is_struct := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	if !is_struct {
		return
	}
	for i in 0 ..< int(struct_info.field_count) {
		name, field_type, offset := struct_info.names[i], struct_info.types[i], int(struct_info.offsets[i])
		if items, slots, ok := table_fields(field_type); ok {
			array := runtime.type_info_base(items.type).variant.(runtime.Type_Info_Array)
			append(&out.tables, Table_Info{name, array.elem, array.count, offset + items.off, offset + slots.off})
		} else if array, is_array := runtime.type_info_base(field_type).variant.(runtime.Type_Info_Array); is_array {
			if _, elem_struct := runtime.type_info_base(array.elem).variant.(runtime.Type_Info_Struct); elem_struct {
				append(&out.tables, Table_Info{name, array.elem, array.count, offset, -1})
				continue
			}
			append(&out.globals, Global_Info{name, field_type, offset})
		} else {
			append(&out.globals, Global_Info{name, field_type, offset})
		}
	}
}

@(private)
Field :: struct {
	type: ^runtime.Type_Info,
	off:  int,
}

@(private)
table_fields :: proc(type: ^runtime.Type_Info) -> (items, slots: Field, ok: bool) {
	struct_info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct) or_return
	for i in 0 ..< int(struct_info.field_count) {
		switch struct_info.names[i] {
		case "items":
			items = {struct_info.types[i], int(struct_info.offsets[i])}
		case "slots":
			array := runtime.type_info_base(struct_info.types[i]).variant.(runtime.Type_Info_Array) or_return
			if array.elem.id != Slot {
				return
			}
			slots = {struct_info.types[i], int(struct_info.offsets[i])}
		}
	}
	return items, slots, items.type != nil && slots.type != nil
}
