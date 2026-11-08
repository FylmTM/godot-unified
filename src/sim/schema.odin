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
	ti:   ^runtime.Type_Info,
	off:  int,
}

Schema :: struct {
	tables:  [dynamic]Table_Info,
	globals: [dynamic]Global_Info,
}

// Built once per state type and kept for the program's lifetime (not thread-safe on first call).
schema_of :: proc($S: typeid) -> ^Schema {
	@(static) cached: Schema
	@(static) built: bool
	if !built {
		build_schema(&cached, type_info_of(S))
		built = true
	}
	return &cached
}

build_schema :: proc(out: ^Schema, ti: ^runtime.Type_Info) {
	context.allocator = runtime.heap_allocator()
	st, is_struct := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	if !is_struct {
		return
	}
	for i in 0 ..< int(st.field_count) {
		name, fti, off := st.names[i], st.types[i], int(st.offsets[i])
		if items, slots, ok := table_fields(fti); ok {
			arr := runtime.type_info_base(items.type).variant.(runtime.Type_Info_Array)
			append(&out.tables, Table_Info{name, arr.elem, arr.count, off + items.off, off + slots.off})
		} else if arr, is_arr := runtime.type_info_base(fti).variant.(runtime.Type_Info_Array); is_arr {
			if _, elem_struct := runtime.type_info_base(arr.elem).variant.(runtime.Type_Info_Struct); elem_struct {
				append(&out.tables, Table_Info{name, arr.elem, arr.count, off, -1})
				continue
			}
			append(&out.globals, Global_Info{name, fti, off})
		} else {
			append(&out.globals, Global_Info{name, fti, off})
		}
	}
}

@(private)
Field :: struct {
	type: ^runtime.Type_Info,
	off:  int,
}

@(private)
table_fields :: proc(ti: ^runtime.Type_Info) -> (items, slots: Field, ok: bool) {
	st := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct) or_return
	for i in 0 ..< int(st.field_count) {
		switch st.names[i] {
		case "items":
			items = {st.types[i], int(st.offsets[i])}
		case "slots":
			arr := runtime.type_info_base(st.types[i]).variant.(runtime.Type_Info_Array) or_return
			if arr.elem.id != Slot {
				return
			}
			slots = {st.types[i], int(st.offsets[i])}
		}
	}
	return items, slots, items.type != nil && slots.type != nil
}

find_table :: proc(sc: ^Schema, name: string) -> (^Table_Info, bool) {
	for &t in sc.tables {
		if t.name == name {
			return &t, true
		}
	}
	return nil, false
}

// The entity at `idx` of table `t` in the state at `base`, and whether it is live (fixed-array
// elements always are).
entity_ptr :: proc(base: rawptr, t: ^Table_Info, idx: int) -> (ptr: rawptr, slot: ^Slot, live: bool) {
	b := ([^]u8)(base)
	ptr = &b[t.items_off + idx * t.elem.size]
	if t.slots_off < 0 {
		return ptr, nil, true
	}
	slot = (^Slot)(&b[t.slots_off + idx * size_of(Slot)])
	return ptr, slot, slot.alive
}
