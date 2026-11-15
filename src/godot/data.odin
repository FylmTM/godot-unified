// Session data, constants and enums as typed Godot classes (src/godot/SPEC.md "Session data and constants"), all
// registered at load from RTTI:
//
//   - a class per type of the game's data union (Glue.data: `Data_Hud` -> DataHud, extends Object), one live
//     instance each, its typed properties read from the newest frame's bytes, a `changed` signal when they change
//     (fill_frame: push_data);
//   - the constants' class (Glue.constants: `Data_Constants` -> DataConstants), one instance filled at load;
//   - the engine singleton `Unified` (class and singleton, like Godot's Input): a property per data type named
//     from it (`Data_Hud` -> Unified.hud), `Unified.constants`, `Unified.session` and `Unified.tick_hz`;
//   - a class per enum type the event, command, data and constants types use (`Phase` -> EnumPhase) with its members
//     as integer constants (EnumPhase.LOBBY) and a static `name(value)`.
package godot

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"

DATA_PREFIX :: "Data_"
MAX_DATA_TYPES :: 64 // types in a game's data union

// One type of the game's data union (or its constants), read by RTTI.
Data_Layout :: struct {
	type:     ^runtime.Type_Info,
	class:    string, // DataHud
	property: string, // Unified.hud
}

// A data or constants class and its one live instance.
@(private)
Data_Class :: struct {
	using class: gd.Class,
	layout:      Data_Layout,
	fields:      []Sim_Field,
	object:      gd.Object, // the live instance (nil until registered)
	instance:    ^Data_Object,
}

// An instance: the value's bytes (the newest frame's; zero outside a session).
@(private)
Data_Object :: struct {
	using hdr: gd.Instance_Header,
	bytes:     []u8,
}

// An enum type as a class of integer constants.
@(private)
Enum_Class :: struct {
	using class: gd.Class,
	type:        ^runtime.Type_Info,
	info:        runtime.Type_Info_Enum,
}

@(private)
D: struct {
	data:      [dynamic]^Data_Class, // by data kind (the union's order)
	constants: ^Data_Class, // nil: the game has none
	enums:     [dynamic]^Enum_Class,
	unified:   gd.Class,
	singleton: gd.Object,
}

// The layout of a data or constants type: the class `Data` + the type name in PascalCase without `Data_`, the
// property the type name without `Data_`, lowercased.
data_layout :: proc(type: ^runtime.Type_Info) -> Data_Layout {
	context.allocator = runtime.heap_allocator()
	name := sim.variant_name(type, DATA_PREFIX)
	return {type = type, class = strings.clone(pascal_name("Data", name)), property = strings.clone(name)}
}

// `prefix` + a snake_case name in PascalCase (rock_hit -> RockHit).
@(private)
pascal_name :: proc(prefix, name: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, prefix)
	upper := true
	for r in name {
		if r == '_' {
			upper = true
			continue
		}
		strings.write_rune(&builder, upper ? rune_upper(r) : r)
		upper = false
	}
	return strings.to_string(builder)
}

// The problems of a game's data union and constants type (install collects them: data_problems).
data_problems :: proc(data: typeid, constants: typeid, problems: ^[dynamic]string) {
	context.allocator = runtime.heap_allocator()
	reserved := []string{"session", "constants", "tick_hz"}
	if data != nil {
		info, is_union := runtime.type_info_base(type_info_of(data)).variant.(runtime.Type_Info_Union)
		if !is_union {
			append(problems, fmt.aprintf("Glue.data %v is not a union of Data_ structs", data))
			return
		}
		if len(info.variants) > MAX_DATA_TYPES {
			append(problems, fmt.aprintf("Glue.data has %d types (at most %d)", len(info.variants), MAX_DATA_TYPES))
		}
		for variant in info.variants {
			if _, is_struct := runtime.type_info_base(variant).variant.(runtime.Type_Info_Struct); !is_struct {
				append(problems, fmt.aprintf("data type %v is not a struct", variant.id))
				continue
			}
			if reason := sim.plain_violation(variant, fmt.tprint(variant.id)); reason != "" {
				append(problems, fmt.aprintf("data type %v: %s", variant.id, reason))
			}
			layout := data_layout(variant)
			for name in reserved {
				if layout.property == name {
					append(
						problems,
						fmt.aprintf(
							"data type %v would be Unified.%s, which the library has: rename it",
							variant.id,
							name,
						),
					)
				}
			}
		}
	}
	if constants != nil {
		if _, is_struct := runtime.type_info_base(type_info_of(constants)).variant.(runtime.Type_Info_Struct);
		   !is_struct {
			append(problems, fmt.aprintf("Glue.constants %v is not a struct", constants))
		}
	}
}

// ---- registration (SCENE init)

// Registers the enum, data and constants classes and the Unified singleton. `constants` is the Glue's value (the
// host copies its bytes; its strings must live as long as the process: literals).
@(private)
register_data_classes :: proc() {
	context.allocator = runtime.heap_allocator()
	if api.installed {
		for type in api.enum_types do register_enum_class(type)
		for layout in api.data do append(&D.data, register_data_class(layout))
		if api.constants.type != nil {
			D.constants = register_data_class(api.constants)
			if D.constants != nil {
				copy(D.constants.instance.bytes, api.constants_bytes)
			}
		}
	}
	D.unified = {
		name   = "Unified",
		parent = "Object",
		size   = size_of(gd.Instance_Header),
	}
	gd.register_class(&D.unified)
	gd.bind_dynamic_method(&D.unified, "get_session", proc(_: rawptr, _: rawptr, _: []^gd.Variant) -> gd.Variant {
		if active == nil do return gd.variant_nil()
		return gd.variant_from_any(active.obj)
	}, nil, nil, gd.Dynamic_Arg{"", .OBJECT, "UnifiedSession"})
	gd.bind_property_by_name(&D.unified, "session", .OBJECT, "get_session", "", "UnifiedSession")
	gd.bind_dynamic_method(&D.unified, "get_tick_hz", proc(_: rawptr, _: rawptr, _: []^gd.Variant) -> gd.Variant {
		return gd.to_variant(i64(api.tick_hz))
	}, nil, nil, gd.Dynamic_Arg{"", .INT, ""})
	gd.bind_property_by_name(&D.unified, "tick_hz", .INT, "get_tick_hz")
	object_getter :: proc(user: rawptr, _: rawptr, _: []^gd.Variant) -> gd.Variant {
		data_class := (^Data_Class)(user)
		return gd.variant_from_any(data_class.object)
	}
	if D.constants != nil {
		gd.bind_dynamic_method(
			&D.unified,
			"get_constants",
			object_getter,
			D.constants,
			nil,
			gd.Dynamic_Arg{"", .OBJECT, D.constants.name},
		)
		gd.bind_property_by_name(&D.unified, "constants", .OBJECT, "get_constants", "", D.constants.name)
	}
	for data_class in D.data {
		if data_class == nil do continue
		getter := fmt.tprintf("get_%s", data_class.layout.property)
		gd.bind_dynamic_method(
			&D.unified,
			getter,
			object_getter,
			data_class,
			nil,
			gd.Dynamic_Arg{"", .OBJECT, data_class.name},
		)
		gd.bind_property_by_name(&D.unified, data_class.layout.property, .OBJECT, getter, "", data_class.name)
	}
	D.singleton = {gd.construct_object("Unified")}
	gd.Engine_register_singleton(gd.Engine_singleton(), "Unified", D.singleton)
}

@(private)
register_data_class :: proc(layout: Data_Layout) -> ^Data_Class {
	if gdi.classdb_get_class_tag(gd.sn(layout.class)) != nil {
		gd.print_error(
			fmt.tprintf(
				"unified: the data type %v would be the class %s, which exists already: rename it",
				layout.type.id,
				layout.class,
			),
		)
		return nil
	}
	data_class := new(Data_Class)
	data_class^ = {
		class = {
			name = layout.class,
			parent = "Object",
			size = size_of(Data_Object),
			init = proc(instance: rawptr) {
				object := (^Data_Object)(instance)
				object.bytes = make([]u8, (^Data_Class)(object.class).layout.type.size, runtime.heap_allocator())
			},
			fini = proc(instance: rawptr) {delete((^Data_Object)(instance).bytes, runtime.heap_allocator())},
		},
		layout = layout,
	}
	gd.register_class(&data_class.class)
	data_class.fields = struct_sim_fields(layout.type)
	for &field in data_class.fields {
		getter := fmt.tprintf("get_%s", field.name)
		gd.bind_dynamic_method(
			&data_class.class,
			getter,
			data_field_get,
			&field,
			nil,
			gd.Dynamic_Arg{"", field.kind, ""},
		)
		gd.bind_property_by_name(&data_class.class, field.name, field.kind, getter)
	}
	gd.bind_signal(&data_class.class, "changed")
	data_class.object = {gd.construct_object(layout.class)}
	data_class.instance = (^Data_Object)(gd.instance_of(data_class.object, &data_class.class))
	return data_class
}

@(private)
data_field_get :: proc(user: rawptr, instance: rawptr, _: []^gd.Variant) -> gd.Variant {
	field := (^Sim_Field)(user)
	object := (^Data_Object)(instance)
	return field_variant(field.type, object.bytes[field.offset:][:field.type.size], api.is_2d)
}

// The properties of a struct's fields (`_` fields are padding, left out).
@(private)
struct_sim_fields :: proc(type: ^runtime.Type_Info) -> []Sim_Field {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	fields := make([dynamic]Sim_Field, runtime.heap_allocator())
	for i in 0 ..< int(info.field_count) {
		name := info.names[i]
		if strings.has_prefix(name, "_") do continue
		append(&fields, Sim_Field {
			name   = name,
			type   = info.types[i],
			offset = int(info.offsets[i]),
			kind   = field_kind(info.types[i]),
		})
	}
	return fields[:]
}

// ---- enums

// The enum types the given types use in their fields (nested structs, arrays and bit_sets included), each once.
enum_types_of :: proc(types: []^runtime.Type_Info, out: ^[dynamic]^runtime.Type_Info) {
	walk :: proc(type: ^runtime.Type_Info, out: ^[dynamic]^runtime.Type_Info) {
		if type == nil do return
		#partial switch info in runtime.type_info_base(type).variant {
		case runtime.Type_Info_Enum:
			for known in out do if known.id == type.id do return
			append(out, type)
		case runtime.Type_Info_Bit_Set:
			walk(info.elem, out)
		case runtime.Type_Info_Array:
			walk(info.elem, out)
		case runtime.Type_Info_Enumerated_Array:
			walk(info.index, out)
			walk(info.elem, out)
		case runtime.Type_Info_Struct:
			if type.id == sim.Position || type.id == sim.Player || is_handle(type) do return
			for i in 0 ..< int(info.field_count) do walk(info.types[i], out)
		}
	}
	for type in types do walk(type, out)
}

// An enum's class: `Enum` + its type name in PascalCase (Phase -> EnumPhase, Rock_Size -> EnumRockSize).
@(private)
enum_class_name :: proc(type: ^runtime.Type_Info) -> string {
	name := fmt.tprint(type.id)
	if named, ok := type.variant.(runtime.Type_Info_Named); ok do name = named.name
	return pascal_name("Enum", strings.to_lower(name, context.temp_allocator))
}

@(private)
register_enum_class :: proc(type: ^runtime.Type_Info) {
	name := enum_class_name(type)
	if gdi.classdb_get_class_tag(gd.sn(name)) != nil {
		gd.print_error(
			fmt.tprintf("unified: the enum %v would be the class %s, which exists already: rename it", type.id, name),
		)
		return
	}
	enum_class := new(Enum_Class)
	enum_class^ = {
		class = {name = strings.clone(name), parent = "Object", size = size_of(gd.Instance_Header)},
		type = type,
		info = runtime.type_info_base(type).variant.(runtime.Type_Info_Enum),
	}
	gd.register_class(&enum_class.class)
	for member, i in enum_class.info.names {
		gd.bind_constant(
			&enum_class.class,
			"",
			strings.to_upper(member, context.temp_allocator),
			i64(enum_class.info.values[i]),
		)
	}
	gd.bind_dynamic_method(&enum_class.class, "name", proc(user: rawptr, _: rawptr, args: []^gd.Variant) -> gd.Variant {
			enum_class := (^Enum_Class)(user)
			value, _ := gd.from_variant(i64, args[0])
			for member, i in enum_class.info.values {
				if i64(member) == value do return gd.to_variant(strings.to_lower(enum_class.info.names[i], context.temp_allocator))
			}
			return gd.to_variant(fmt.tprintf("%d", value))
		}, enum_class, {{"value", .INT, ""}}, gd.Dynamic_Arg{"", .STRING, ""}, static = true)
	append(&D.enums, enum_class)
}

// ---- the main thread: frames, session end

// Sets each pushed data type's instance from the frame's bytes; emits `changed` when they differ.
data_sync :: proc(frame: ^Frame_Data) {
	for item in frame.datas[:frame.n_datas] {
		if int(item.kind) >= len(D.data) do continue
		data_class := D.data[item.kind]
		if data_class == nil || data_class.instance == nil do continue
		bytes := frame.data[item.offset:][:item.size]
		if string(bytes) == string(data_class.instance.bytes) do continue
		copy(data_class.instance.bytes, bytes)
		gd.emit_signal(data_class.object, gd.sn("changed"))
	}
}

// A session ended (or a new one starts): every data value back to zero, `changed` once for each that wasn't.
data_reset :: proc() {
	for data_class in D.data {
		if data_class == nil || data_class.instance == nil do continue
		bytes := data_class.instance.bytes
		if slice.all_of(bytes, 0) do continue
		slice.zero(bytes)
		gd.emit_signal(data_class.object, gd.sn("changed"))
	}
}

// Frees the singleton and the data and constants instances: at Godot's shutdown, while scripting still runs (a
// lambda connected to `changed` must not outlive GDScript), or when the extension unloads (hot reload).
data_objects_free :: proc() {
	if D.singleton.ptr != nil {
		gd.Engine_unregister_singleton(gd.Engine_singleton(), "Unified")
		gdi.object_destroy(D.singleton.ptr)
		D.singleton = {}
	}
	for data_class in data_classes() {
		if data_class.object.ptr == nil do continue
		gdi.object_destroy(data_class.object.ptr)
		data_class.object, data_class.instance = {}, nil
	}
}

// Every registered data class and the constants' class.
@(private)
data_classes :: proc() -> []^Data_Class {
	all := make([dynamic]^Data_Class, context.temp_allocator)
	for data_class in D.data do if data_class != nil do append(&all, data_class)
	if D.constants != nil do append(&all, D.constants)
	return all[:]
}

// Unregisters the singleton and the classes when the extension unloads (the instances are freed first).
unregister_data_classes :: proc() {
	data_objects_free()
	gd.unregister_class(&D.unified)
	for data_class in data_classes() do gd.unregister_class(&data_class.class)
	#reverse for enum_class in D.enums do gd.unregister_class(&enum_class.class)
	clear(&D.data)
	clear(&D.enums)
	D.constants, D.singleton = nil, {}
}
