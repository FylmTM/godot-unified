// Discovers a state block's tables by walking its RTTI once: every field whose type is a
// Table(T, N) is a table of entities of type T (recognised by shape: `items: [N]T` and
// `slots: [N]Slot`); a fixed array of structs is a table whose elements are all live; anything
// else is a global. Inspectors, desync diffs and dumps build on this without per-type code.
package sim

import "base:runtime"

import "core:sync"

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

// Built once per state type, by whichever thread asks first, and kept for the program's lifetime.
schema_of :: proc($State: typeid) -> ^Schema {
	@(static) cache: Schema_Cache
	return schema_cached(&cache, type_info_of(State))
}

// One state type's schema and the guard that builds it once (a non-generic home for core:sync: -vet).
@(private)
Schema_Cache :: struct {
	schema: Schema,
	once:   sync.Once,
}

@(private)
schema_cached :: proc(cache: ^Schema_Cache, type: ^runtime.Type_Info) -> ^Schema {
	Build :: struct {
		out:  ^Schema,
		type: ^runtime.Type_Info,
	}
	build := Build{&cache.schema, type}
	sync.once_do_with_data(&cache.once, proc(data: rawptr) {
			build := (^Build)(data)
			build_schema(build.out, build.type)
		}, &build)
	return &cache.schema
}

// Fills `out` with the tables and globals of the state type (heap-allocated, as the schema lives as long as the
// program); schema_of calls it once per type and caches the result.
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
