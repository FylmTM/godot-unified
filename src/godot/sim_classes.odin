// The game's events and commands as Godot classes, registered at load from the sim's unions by RTTI (nothing
// generated): a class per kind, `extends UnifiedEvent` or `extends UnifiedCommand` (RefCounted), named `Event` or
// `Command` + the Odin type in PascalCase (EventRockHit, CommandDrop: class_name_of), with a typed property per
// field. Events reach GDScript as instances (session.odin, views.odin); scripts make commands with
// `CommandDrop.new()` and send them with UnifiedSession.send_command (command.odin).
#+private
package godot

import "base:runtime"
import "core:fmt"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"

#assert(sim.EVENT_MAX == sim.COMMAND_MAX)

// A registered event or command class.
Sim_Class :: struct {
	using class: gd.Class,
	class_name:  ^gd.StringName, // its name, interned: an event's object is made per delivery
	type:        ^runtime.Type_Info, // the variant's struct
	kind:        int, // its index in the union
	is_event:    bool,
	fields:      []Sim_Field,
}

// A struct field as a Godot property (an event's or command's, a data class's, a view's data): struct_sim_fields.
Sim_Field :: struct {
	name:    string,
	name_sn: ^gd.StringName, // interned: a view's data sets it by name
	type:    ^runtime.Type_Info,
	offset:  int,
	kind:    gdi.VariantType,
}

// An instance: the event's or command's struct bytes.
Sim_Object :: struct {
	using hdr: gd.Instance_Header,
	tick:      i64, // an event's tick
	id:        i64, // an event's id (the same in each of its states)
	bad:       bool, // a command property was set to a wrong value (send_command refuses it)
	data:      [sim.EVENT_MAX]u8,
}

event_base_class, command_base_class: gd.Class
sim_classes: [dynamic]^Sim_Class

// The class of an object made from one of the game's event or command classes (nil otherwise).
sim_class_of :: proc(obj: gd.Object) -> (^Sim_Class, ^Sim_Object) {
	instance := (^Sim_Object)(gd.instance_of(obj, &event_base_class))
	if instance == nil do instance = (^Sim_Object)(gd.instance_of(obj, &command_base_class))
	if instance == nil do return nil, nil
	for sim_class in sim_classes do if &sim_class.class == instance.class do return sim_class, instance
	return nil, nil
}

// The class of an event or command kind: `Event` or `Command`, then the Odin type name in PascalCase (an event's
// `Event_` and a command's `Cmd_` dropped): Rock_Hit and Event_Rock_Hit -> EventRockHit, Cmd_Drop -> CommandDrop.
// Godot has no namespaces for classes (an extension class can't nest, nor can GDScript alias one as a constant), so
// the prefix groups them.
class_name_of :: proc(variant: ^runtime.Type_Info, is_event: bool) -> string {
	name := fmt.tprint(variant.id)
	if named, ok := variant.variant.(runtime.Type_Info_Named); ok do name = named.name
	name = strings.trim_prefix(name, is_event ? sim.EVENT_PREFIX : sim.COMMAND_PREFIX)
	return pascal_name(is_event ? "Event" : "Command", name)
}

rune_upper :: proc(r: rune) -> rune {
	return r >= 'a' && r <= 'z' ? r - 'a' + 'A' : r
}

// The Variant type a field reads as (Position: Vector2 in a 2D game).
field_kind :: proc(type: ^runtime.Type_Info) -> gdi.VariantType {
	if type.id == sim.Position do return api.is_2d ? .VECTOR2 : .VECTOR3
	if is_handle(type) || type.id == sim.Player do return .INT
	if kind, is_builtin := gd.builtin_variant_type(type.id); is_builtin do return kind // Godot's math types
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Integer:
		return .INT
	case runtime.Type_Info_Float:
		return .FLOAT
	case runtime.Type_Info_Boolean:
		return .BOOL
	case runtime.Type_Info_Enum:
		return .INT
	case runtime.Type_Info_String:
		return .STRING
	case runtime.Type_Info_Bit_Set:
		return .ARRAY
	case runtime.Type_Info_Array:
		if info.elem.id == f32 {
			switch info.count {
			case 2:
				return .VECTOR2
			case 3:
				return .VECTOR3
			case 4:
				return .COLOR
			}
		}
		return .ARRAY
	case runtime.Type_Info_Enumerated_Array:
		return .ARRAY
	case runtime.Type_Info_Struct:
		return .DICTIONARY
	}
	return .NIL
}

// Registers UnifiedEvent, UnifiedCommand and a class per kind of the game's event and command unions (SCENE init).
register_sim_classes :: proc() {
	event_base_class = {
		name   = "UnifiedEvent",
		parent = "RefCounted",
		size   = size_of(Sim_Object),
	}
	gd.register_class(&event_base_class)
	gd.bind_property(&event_base_class, "tick", proc(object: ^Sim_Object) -> i64 {return object.tick})
	gd.bind_property(&event_base_class, "id", proc(object: ^Sim_Object) -> i64 {return object.id})
	gd.bind_property(&event_base_class, "kind", proc(object: ^Sim_Object) -> string {
		if object.class == &event_base_class do return ""
		return api.events[(^Sim_Class)(object.class).kind].name
	})
	command_base_class = {
		name   = "UnifiedCommand",
		parent = "RefCounted",
		size   = size_of(Sim_Object),
	}
	gd.register_class(&command_base_class)
	for layout, kind in api.events do register_sim_class(layout.type, kind, true)
	for layout, kind in api.commands do register_sim_class(layout.type, kind, false)
}

register_sim_class :: proc(variant: ^runtime.Type_Info, kind: int, is_event: bool) {
	context.allocator = runtime.heap_allocator()
	name := class_name_of(variant, is_event)
	if gdi.classdb_get_class_tag(gd.sn(name)) != nil {
		gd.print_error(
			fmt.tprintf(
				"unified: the %s %v would be the class %s, which exists already: rename it",
				is_event ? "event" : "command",
				variant.id,
				name,
			),
		)
		return
	}
	sim_class := new(Sim_Class)
	sim_class^ = {
		class = {
			name   = strings.clone(name),
			parent = is_event ? "UnifiedEvent" : "UnifiedCommand",
			native = "RefCounted",
			size   = size_of(Sim_Object),
		},
		class_name = gd.sn(name),
		type = variant,
		kind = kind,
		is_event = is_event,
	}
	gd.register_class(&sim_class.class)
	sim_class.fields = struct_sim_fields(variant)
	for &field in sim_class.fields {
		hint, hint_string := field_hint(field.type)
		setter: gd.Dynamic_Proc = is_event ? nil : field_set
		gd.bind_dynamic_property(
			&sim_class.class,
			{field.name, field.kind, ""},
			field_get,
			setter,
			&field,
			hint,
			hint_string,
		)
	}
	append(&sim_classes, sim_class)
}

field_get :: proc(user: rawptr, instance: rawptr, args: []^gd.Variant) -> gd.Variant {
	field := (^Sim_Field)(user)
	object := (^Sim_Object)(instance)
	// an event's bytes are the sim's; a command object's positions are what the script set (view units)
	return field_variant(
		field.type,
		object.data[field.offset:][:field.type.size],
		(^Sim_Class)(object.class).is_event ? .Sim : .View,
	)
}

field_set :: proc(user: rawptr, instance: rawptr, args: []^gd.Variant) -> gd.Variant {
	field := (^Sim_Field)(user)
	object := (^Sim_Object)(instance)
	if err := write_value(field.type, object.data[field.offset:][:field.type.size], args[0]); err != "" {
		object.bad = true
		gd.print_error(fmt.tprintf("unified: %s.%s: %s", object.class.name, field.name, err))
	}
	return gd.variant_nil()
}

// An event in a new object of its class (main thread; the first Variant made of it holds its reference).
new_event_object :: proc(kind: int, tick: u32, id: u64, data: []u8) -> gd.Object {
	for sim_class in sim_classes {
		if !sim_class.is_event || sim_class.kind != kind do continue
		object := gd.Object{gd.construct_object_named(sim_class.class_name)}
		instance := (^Sim_Object)(gd.instance_of(object, &sim_class.class))
		instance.tick = i64(tick)
		instance.id = i64(id)
		copy(instance.data[:], data)
		return object
	}
	return {}
}
