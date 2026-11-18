// Session data, constants and enums as typed Godot classes (src/godot/SPEC.md "Session data and constants"), all
// registered at load from RTTI:
//
//   - a class per type of the game's data union (Glue.data: `Data_Hud` -> DataHud, extends Object), one live
//     instance each, its typed properties read from the newest frame's bytes, a `changed` signal when they change
//     (fill_frame: push_data), held by `UnifiedData` with a property per type named from it (`Data_Hud` -> hud);
//   - `UnifiedConstants`: the constants' fields (godot.init's constants), one instance filled at load (no fields when the
//     game has none);
//   - the engine singleton `Unified` (class and singleton, like Godot's Input): `Unified.data`, `Unified.constants`,
//     `Unified.session`, `Unified.tick_hz` and `Unified.view_scale`;
//   - a class per enum type the event, command, data and constants types use (`Phase` -> EnumPhase) with its members
//     as integer constants (EnumPhase.LOBBY) and a static `name(value)`.
#+private
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
	property: string, // Unified.data.hud
}

// A struct as a class (Data_Role: session data, the constants, the input values, a nested struct) and its one live
// instance (none for a nested struct: a new value per read).
Data_Class :: struct {
	using class: gd.Class,
	class_sn:    ^gd.StringName, // its name, interned: a nested value is made per read
	layout:      Data_Layout,
	role:        Data_Role,
	fields:      []Sim_Field,
	positions:   [dynamic]int, // the offsets of its sim.Position fields (a nested value's are in view units)
	object:      gd.Object, // the live instance (nil until registered; none for a nested struct)
	instance:    ^Data_Object,
}

// An instance: the value's bytes (session data: the newest frame's, zero outside a session).
Data_Object :: struct {
	using hdr: gd.Instance_Header,
	bytes:     []u8,
}

// An enum type as a class of integer constants.
Enum_Class :: struct {
	using class: gd.Class,
	type:        ^runtime.Type_Info,
	info:        runtime.Type_Info_Enum,
}

CONSTANTS_CLASS :: "UnifiedConstants"
INPUT_CLASS :: "UnifiedInput"

D: struct {
	data:          [dynamic]^Data_Class, // by data kind (the union's order)
	constants:     ^Data_Class, // UnifiedConstants (nil before registration, or on a clash)
	input:         ^Data_Class, // UnifiedInput (nil before registration, or on a clash)
	nested:        map[typeid]^Data_Class, // the nested structs' classes, by type
	enums:         [dynamic]^Enum_Class,
	unified:       gd.Class,
	holder:        gd.Class, // UnifiedData
	holder_object: gd.Object,
	singleton:     gd.Object,
}

// The layout of a data or constants type: the class `Data` + the type name in PascalCase without `Data_`, the
// property the type name without `Data_`, lowercased.
data_layout :: proc(type: ^runtime.Type_Info) -> Data_Layout {
	context.allocator = runtime.heap_allocator()
	name := sim.variant_name(type, DATA_PREFIX)
	return {type = type, class = strings.clone(pascal_name("Data", name)), property = strings.clone(name)}
}

// `prefix` + a snake_case name in PascalCase (rock_hit -> RockHit).
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

// The problems of a game's data union, constants and input values types (install collects them).
data_problems :: proc(data: typeid, constants: typeid, input_values: typeid, problems: ^[dynamic]string) {
	context.allocator = runtime.heap_allocator()
	if data != nil {
		info, is_union := runtime.type_info_base(type_info_of(data)).variant.(runtime.Type_Info_Union)
		if !is_union {
			append(problems, fmt.aprintf("Glue.data %v is not a union of Data_ structs", data))
			return
		}
		if len(info.variants) > MAX_DATA_TYPES {
			append(problems, fmt.aprintf("Glue.data has %d types (at most %d)", len(info.variants), MAX_DATA_TYPES))
		}
		for variant in info.variants do struct_problems("data type", variant, true, problems)
	}
	if constants != nil do struct_problems("the constants", type_info_of(constants), false, problems)
	if input_values != nil do struct_problems("Glue.input_values", type_info_of(input_values), true, problems)
}

// A Glue struct type's problems: not a struct, not plain (`plain`: padding-free, no pointers: sim.plain_violation), or
// a field of one of Godot's own types (data maps by shape: [3]f32, godot.Color...).
struct_problems :: proc(what: string, type: ^runtime.Type_Info, plain: bool, problems: ^[dynamic]string) {
	if _, is_struct := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct); !is_struct {
		append(problems, fmt.aprintf("%s %v is not a struct", what, type.id))
		return
	}
	if plain {
		if reason := sim.plain_violation(type, fmt.tprint(type.id)); reason != "" {
			append(problems, fmt.aprintf("%s %v: %s", what, type.id, reason))
		}
	}
	if godot_type := godot_type_in(type); godot_type != nil {
		append(
			problems,
			fmt.aprintf(
				"%s %v holds %v, one of Godot's types: use [2]f32 / [3]f32 / [4]f32, [2]i32..., godot.Color or godot.Quat",
				what,
				type.id,
				godot_type,
			),
		)
	}
}

// The first of Godot's own types (unified:gdext's) a type holds, in nested structs and arrays too (nil: none).
godot_type_in :: proc(type: ^runtime.Type_Info) -> typeid {
	if named, is_named := type.variant.(runtime.Type_Info_Named); is_named && named.pkg == "gdext" do return type.id
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Array:
		return godot_type_in(info.elem)
	case runtime.Type_Info_Enumerated_Array:
		return godot_type_in(info.elem)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(info.field_count) do if found := godot_type_in(info.types[i]); found != nil do return found
	}
	return nil
}

// ---- registration (SCENE init)

// The struct types nested in the event, command, data, constants and input types (through arrays too), each once, a
// struct after the ones it holds: they become classes (DataHudPlayer) before the classes that use them.
nested_types_of :: proc(types: []^runtime.Type_Info, out: ^[dynamic]^runtime.Type_Info) {
	walk :: proc(type: ^runtime.Type_Info, out: ^[dynamic]^runtime.Type_Info, is_root: bool) {
		if type == nil || type.id == sim.Position || type.id == sim.Player || is_handle(type) do return
		#partial switch info in runtime.type_info_base(type).variant {
		case runtime.Type_Info_Array:
			walk(info.elem, out, false)
		case runtime.Type_Info_Enumerated_Array:
			walk(info.elem, out, false)
		case runtime.Type_Info_Struct:
			for known in out do if known.id == type.id do return
			for i in 0 ..< int(info.field_count) do walk(info.types[i], out, false)
			if !is_root do append(out, type)
		}
	}
	for type in types do walk(type, out, true)
}

// Registers a class per nested struct type (Glue types and the event and command unions: nested_types_of), named
// `Data` + its type name in PascalCase (Hud_Player -> DataHudPlayer): a RefCounted value whose fields a script reads
// and sets. A field of that type reads as a new object of it; a command's takes one.
register_nested_classes :: proc() {
	context.allocator = runtime.heap_allocator()
	if !api.installed do return
	roots := make([dynamic]^runtime.Type_Info, context.temp_allocator)
	for layout in api.events do append(&roots, layout.type)
	for layout in api.commands do append(&roots, layout.type)
	for layout in api.data do append(&roots, layout.type)
	if api.constants.type != nil do append(&roots, api.constants.type)
	if api.input_values.type != nil do append(&roots, api.input_values.type)
	types := make([dynamic]^runtime.Type_Info, context.temp_allocator)
	nested_types_of(roots[:], &types)
	for type in types {
		named, is_named := type.variant.(runtime.Type_Info_Named)
		if !is_named do continue // an anonymous struct reads as a Dictionary
		layout := Data_Layout {
			type  = type,
			class = strings.clone(pascal_name("Data", named.name)),
		}
		if nested := register_data_class(layout, .Nested); nested != nil do D.nested[type.id] = nested
	}
}

// Registers the enum, data, constants and input classes and the Unified singleton.
register_data_classes :: proc() {
	context.allocator = runtime.heap_allocator()
	if api.installed {
		// the view kinds: EnumView and EnumMultiView whatever the game named its enums (get_view and the scene's kind)
		register_enum_class(api.view_enum, "EnumView")
		register_enum_class(api.multi_enum, "EnumMultiView")
		for type in api.enum_types {
			if type.id != api.view_enum.id && type.id != api.multi_enum.id do register_enum_class(type)
		}
		for layout in api.data do append(&D.data, register_data_class(layout, .Data))
	}
	// the constants' and the input's classes always exist (no fields without a type), so scripts can name them
	constants := api.constants
	constants.class, constants.property = CONSTANTS_CLASS, "constants"
	D.constants = register_data_class(constants, .Constants)
	if D.constants != nil do copy(D.constants.instance.bytes, api.constants_bytes)
	input := api.input_values
	input.class, input.property = INPUT_CLASS, "input"
	D.input = register_data_class(input, .Input)
	object_getter :: proc(user: rawptr, _: rawptr, _: []^gd.Variant) -> gd.Variant {
		data_class := (^Data_Class)(user)
		return gd.variant_from_any(data_class.object)
	}
	D.holder = {
		name      = "UnifiedData",
		parent    = "Object",
		doc_brief = "The game's session data: [code]Unified.data[/code].",
		doc       = "A typed property per type of the game's session data ([code]Data_Hud[/code]: [code]Unified.data.hud[/code], a [code]DataHud[/code] with a [code]changed[/code] signal), set from the newest tick and back to zero when a session ends.",
	}
	gd.register_class(&D.holder)
	for data_class in D.data {
		if data_class == nil do continue
		gd.bind_dynamic_property(
			&D.holder,
			{data_class.layout.property, .OBJECT, data_class.name},
			object_getter,
			nil,
			data_class,
			doc = fmt.tprintf("The game's session data %v.", data_class.layout.type.id),
		)
	}
	D.holder_object = {gd.construct_object("UnifiedData")}
	D.unified = {
		name      = "Unified",
		parent    = "Object",
		doc_brief = "The engine singleton for the game's session data, its constants, its input values and the session.",
		doc       = "[member data] holds the game's session data, [member constants] its constants, [member input] the values scripts give its input sampling, [member session] the active [UnifiedSession].",
	}
	gd.register_class(&D.unified)
	gd.bind_dynamic_property(&D.unified, {"session", .OBJECT, "UnifiedSession"}, proc(_: rawptr, _: rawptr, _: []^gd.Variant) -> gd.Variant {
			if active == nil do return gd.variant_nil()
			return gd.variant_from_any(active.obj)
		}, doc = "The active session node (null: none).")
	gd.bind_property(
		&D.unified,
		"tick_hz",
		proc(_: ^gd.Instance_Header) -> i64 {return i64(api.tick_hz)},
		doc = "The sim's ticks per second.",
	)
	gd.bind_property(
		&D.unified,
		"view_scale",
		proc(_: ^gd.Instance_Header) -> f64 {return f64(api.view_scale)},
		doc = "View units per sim unit (the game's Glue.view_scale; 1 unless set): positions arrive scaled already; multiply a sim size (a radius from the constants) by it.",
	)
	gd.bind_dynamic_method(&D.unified, "level_markers", proc(_: rawptr, _: rawptr, args: []^gd.Variant) -> gd.Variant {
			root, _ := gd.from_variant(gd.Node, args[0])
			markers := level_markers(root)
			return array_variant(&markers)
		}, nil, {{"root", .OBJECT, "Node"}}, gd.Dynamic_Arg{"", .ARRAY, "Node"}, doc = "The level markers under [param root] (a level scene's root) in the order its [code].level[/code] file holds them (depth-first, parents before children, every node that declares a marker kind), so marker index i is element i.")
	gd.bind_dynamic_property(
		&D.unified,
		{"data", .OBJECT, "UnifiedData"},
		proc(_: rawptr, _: rawptr, _: []^gd.Variant) -> gd.Variant {
			return gd.variant_from_any(D.holder_object)
		},
		doc = "The game's session data, one typed object per type.",
	)
	if D.constants != nil {
		gd.bind_dynamic_property(
			&D.unified,
			{"constants", .OBJECT, CONSTANTS_CLASS},
			object_getter,
			nil,
			D.constants,
			doc = "The game's constants.",
		)
	}
	if D.input != nil {
		gd.bind_dynamic_property(
			&D.unified,
			{"input", .OBJECT, INPUT_CLASS},
			object_getter,
			nil,
			D.input,
			doc = "Values only scripts know (a camera's look direction), which the game's input sampling reads (Glue.input_values): set its fields every frame.",
		)
	}
	D.singleton = {gd.construct_object("Unified")}
	gd.Engine_register_singleton(gd.Engine_singleton(), "Unified", D.singleton)
}

// What a Data_Class is: its parent, its units, whether scripts set it and whether it has a live instance.
Data_Role :: enum u8 {
	Data, // a session data type: one live instance, set from the frames, `changed`
	Constants, // UnifiedConstants: one live instance, set at load
	Input, // UnifiedInput: one live instance, set by scripts, read by sample_input
	Nested, // a nested struct: a RefCounted value per read, settable
}

register_data_class :: proc(layout: Data_Layout, role: Data_Role) -> ^Data_Class {
	if gdi.classdb_get_class_tag(gd.sn(layout.class)) != nil {
		gd.print_error(
			fmt.tprintf(
				"unified: the type %v would be the class %s, which exists already: rename it",
				layout.type.id if layout.type != nil else nil,
				layout.class,
			),
		)
		return nil
	}
	type_name := layout.type.id if layout.type != nil else nil
	data_class := new(Data_Class)
	data_class^ = {
		class = {
			name = layout.class,
			parent = role == .Nested ? "RefCounted" : "Object",
			size = size_of(Data_Object),
			init = proc(instance: rawptr) {
				object := (^Data_Object)(instance)
				type := (^Data_Class)(object.class).layout.type
				object.bytes = make([]u8, type.size if type != nil else 0, runtime.heap_allocator())
			},
			fini = proc(instance: rawptr) {delete((^Data_Object)(instance).bytes, runtime.heap_allocator())},
		},
		layout = layout,
		role = role,
		class_sn = gd.sn(layout.class),
	}
	switch role {
	case .Data:
		data_class.doc_brief = fmt.aprintf("The game's session data %v.", type_name)
		data_class.doc = fmt.aprintf(
			"[code]Unified.data.%s[/code]: the newest tick's values (fill_frame: push_data), zero outside a session.",
			layout.property,
		)
	case .Constants:
		data_class.doc_brief = "The game's constants (what godot.init's constants proc returned): [code]Unified.constants[/code]."
		data_class.doc = "The game's fixed values for its scripts, set once at load (no members when the game has none)."
	case .Input:
		data_class.doc_brief = "The game's input values (Glue.input_values): [code]Unified.input[/code]."
		data_class.doc = "What only scripts know for the game's input sampling (a camera's look direction): set each field every frame; sample_input reads the latest. No members when the game has none."
	case .Nested:
		data_class.doc_brief = fmt.aprintf("The game's struct %v, nested in its events, commands or data.", type_name)
		data_class.doc = "A value: each read of a field of this type makes a new one. Set its fields to put it into a command."
	}
	gd.register_class(&data_class.class)
	if layout.type != nil {
		data_class.fields = struct_sim_fields(layout.type)
		position_offsets(layout.type, 0, &data_class.positions)
	}
	settable := role == .Input || role == .Nested
	for &field in data_class.fields {
		gd.bind_dynamic_property(
			&data_class.class,
			{field.name, field.kind, field.class_name},
			data_field_get,
			settable ? data_field_set : nil,
			&field,
			doc = field_doc(field),
		)
	}
	if role == .Data do gd.bind_signal(&data_class.class, "changed", doc = "A value changed (a new tick's, or the reset when a session ends).")
	if role != .Nested {
		data_class.object = {gd.construct_object(layout.class)}
		data_class.instance = (^Data_Object)(gd.instance_of(data_class.object, &data_class.class))
	}
	return data_class
}

// A data object's field: session data and constants hold the sim's bytes (positions in sim units), input values and
// nested values what scripts read and set (view units).
data_field_get :: proc(user: rawptr, instance: rawptr, _: []^gd.Variant) -> gd.Variant {
	field := (^Sim_Field)(user)
	object := (^Data_Object)(instance)
	role := (^Data_Class)(object.class).role
	units: Units = role == .Data || role == .Constants ? .Sim : .View
	return field_variant(field.type, object.bytes[field.offset:][:field.type.size], units)
}

data_field_set :: proc(user: rawptr, instance: rawptr, args: []^gd.Variant) -> gd.Variant {
	field := (^Sim_Field)(user)
	object := (^Data_Object)(instance)
	if err := write_value(field.type, object.bytes[field.offset:][:field.type.size], args[0]); err != "" {
		gd.print_error(fmt.tprintf("unified: %s.%s: %s", object.class.name, field.name, err))
	}
	return gd.variant_nil()
}

// The properties of a struct's fields (`_` fields are padding, left out), kept as long as the process (main thread).
struct_sim_fields :: proc(type: ^runtime.Type_Info) -> []Sim_Field {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	fields := make([dynamic]Sim_Field, runtime.heap_allocator())
	for i in 0 ..< int(info.field_count) {
		name := info.names[i]
		if strings.has_prefix(name, "_") do continue
		kind, class_name := field_kind(info.types[i])
		append(&fields, Sim_Field {
			name       = name,
			name_sn    = gd.sn(name),
			type       = info.types[i],
			offset     = int(info.offsets[i]),
			kind       = kind,
			class_name = strings.clone(class_name, runtime.heap_allocator()),
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
enum_class_name :: proc(type: ^runtime.Type_Info) -> string {
	name := fmt.tprint(type.id)
	if named, ok := type.variant.(runtime.Type_Info_Named); ok do name = named.name
	return pascal_name("Enum", strings.to_lower(name, context.temp_allocator))
}

register_enum_class :: proc(type: ^runtime.Type_Info, class_name := "") {
	name := class_name != "" ? class_name : enum_class_name(type)
	if gdi.classdb_get_class_tag(gd.sn(name)) != nil {
		gd.print_error(
			fmt.tprintf("unified: the enum %v would be the class %s, which exists already: rename it", type.id, name),
		)
		return
	}
	enum_class := new(Enum_Class)
	enum_class^ = {
		class = {
			name      = strings.clone(name),
			parent    = "Object",
			doc_brief = fmt.aprintf("The game's enum %v: fields of this type are ints.", type.id),
			doc       = "Compare a field with its constants; [method name] gives a member's name for display.",
		},
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
			doc = fmt.tprintf("%v.%s", type.id, member),
		)
	}
	gd.bind_dynamic_method(&enum_class.class, "name", proc(user: rawptr, _: rawptr, args: []^gd.Variant) -> gd.Variant {
			enum_class := (^Enum_Class)(user)
			value, _ := gd.from_variant(i64, args[0])
			for member, i in enum_class.info.values {
				if i64(member) == value do return gd.to_variant(strings.to_lower(enum_class.info.names[i], context.temp_allocator))
			}
			return gd.to_variant(fmt.tprintf("%d", value))
		}, enum_class, {{"value", .INT, ""}}, gd.Dynamic_Arg{"", .STRING, ""}, static = true, doc = "The member's name, lowercased (its value as text for none).")
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
	if D.holder_object.ptr != nil {
		gdi.object_destroy(D.holder_object.ptr)
		D.holder_object = {}
	}
	for data_class in data_classes() {
		if data_class.object.ptr == nil do continue
		gdi.object_destroy(data_class.object.ptr)
		data_class.object, data_class.instance = {}, nil
	}
}

// Every registered data class, and the constants' and the input's classes.
data_classes :: proc() -> []^Data_Class {
	all := make([dynamic]^Data_Class, context.temp_allocator)
	for data_class in D.data do if data_class != nil do append(&all, data_class)
	if D.constants != nil do append(&all, D.constants)
	if D.input != nil do append(&all, D.input)
	return all[:]
}

// Forgets the data and enum classes once gd.shutdown has unregistered them (the extension unloads; a hot reload
// registers anew). The classes themselves live as long as the process.
data_classes_forget :: proc() {
	clear(&D.data)
	clear(&D.enums)
	clear(&D.nested)
	D.constants, D.input, D.singleton = nil, nil, {}
}
