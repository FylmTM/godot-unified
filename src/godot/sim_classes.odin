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
	name:       string,
	name_sn:    ^gd.StringName, // interned: a view's data sets it by name
	type:       ^runtime.Type_Info,
	offset:     int,
	kind:       gdi.VariantType,
	class_name: string, // an OBJECT's class, an ARRAY's element type (field_kind)
}

// A field's line in the editor's help.
field_doc :: proc(field: Sim_Field) -> string {
	return fmt.tprintf("The field [code]%s[/code] (Odin [code]%v[/code]).", field.name, field.type.id)
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

// Registers UnifiedEvent, UnifiedCommand and a class per kind of the game's event and command unions (SCENE init).
register_sim_classes :: proc() {
	event_base_class = {
		name      = "UnifiedEvent",
		parent    = "RefCounted",
		size      = size_of(Sim_Object),
		doc_brief = "One of the game's sim events: the base of its event classes.",
		doc       = "Each kind of the game's event union is a class extending this one, named Event + its type name (Rock_Hit: [code]EventRockHit[/code]), with a property per field. Dispatch by class: [code]if event is EventRockHit: var hit := event as EventRockHit[/code].",
	}
	gd.register_class(&event_base_class)
	gd.bind_property(
		&event_base_class,
		"tick",
		proc(object: ^Sim_Object) -> i64 {return object.tick},
		doc = "The tick that produced it.",
	)
	gd.bind_property(
		&event_base_class,
		"id",
		proc(object: ^Sim_Object) -> i64 {return object.id},
		doc = "The same in its EVENT_EMITTED and in its EVENT_CONFIRMED or EVENT_CANCELLED (each state is a new object): remember what an effect started by it, undo it on EVENT_CANCELLED, forget it on EVENT_CONFIRMED. Never repeats in the process; an event cancelled and produced again later is a new one.",
	)
	gd.bind_property(&event_base_class, "kind", proc(object: ^Sim_Object) -> string {
			if object.class == &event_base_class do return ""
			return api.events[(^Sim_Class)(object.class).kind].name
		}, doc = "Its kind's name for logs: the type name without Event_, lowercased. Handlers dispatch by class (`is`), never by this.")
	command_base_class = {
		name      = "UnifiedCommand",
		parent    = "RefCounted",
		size      = size_of(Sim_Object),
		doc_brief = "One of the game's commands: the base of its command classes.",
		doc       = "Each kind of the game's command union is a class extending this one, named Command + its type name without Cmd_ (Cmd_Drop: [code]CommandDrop[/code]), with a property per field. Make one, set its fields, and send it with [method UnifiedSession.send_command].",
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
			name      = strings.clone(name),
			parent    = is_event ? "UnifiedEvent" : "UnifiedCommand",
			native    = "RefCounted",
			size      = size_of(Sim_Object),
			doc_brief = fmt.aprintf("The game's %s %v.", is_event ? "event" : "command", variant.id),
			doc       = is_event ? "Reaches views ([code]_sim_event[/code]) and [signal UnifiedSession.sim_event] in each of its states." : "Set its fields and send it with [method UnifiedSession.send_command].",
		},
		class_name = gd.sn(name),
		type = variant,
		kind = kind,
		is_event = is_event,
	}
	gd.register_class(&sim_class.class)
	sim_class.fields = struct_sim_fields(variant)
	for &field in sim_class.fields {
		setter: gd.Dynamic_Proc = is_event ? nil : field_set
		gd.bind_dynamic_property(
			&sim_class.class,
			{field.name, field.kind, field.class_name},
			field_get,
			setter,
			&field,
			doc = field_doc(field),
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
