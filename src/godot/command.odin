// UnifiedSession.send_command(command): a command object (a class sim_classes.odin registered from the game's
// command union) becomes the command's struct, then goes to the session thread, which hands it to the client
// (driver.odin).
#+private
package godot

import "base:runtime"
import "core:fmt"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"

// One kind of the game's command union.
Command_Layout :: struct {
	name:      string, // the type name without `Cmd_`, lowercased ("drop")
	type:      ^runtime.Type_Info,
	positions: [dynamic]int, // offsets of the sim.Position fields, nested structs' too: view units to sim units
}

// The layouts of a game's command union, by kind (allocated for the process's lifetime).
command_layouts :: proc(commands: typeid) -> []Command_Layout {
	context.allocator = runtime.heap_allocator()
	variants := sim.union_variants(commands)
	layouts := make([]Command_Layout, len(variants))
	for variant, kind in variants {
		layouts[kind] = {
			name = strings.clone(sim.variant_name(variant, sim.COMMAND_PREFIX)),
			type = variant,
		}
		position_offsets(variant, 0, &layouts[kind].positions)
	}
	return layouts
}

// Main thread. False, with print_error naming what is wrong, for an object that is not one of the game's
// commands, a property set to a wrong value, no running session, or a full queue.
send_command :: proc(object: gd.Object) -> bool {
	fail :: proc(msg: string) -> bool {
		gd.print_error(fmt.tprintf("unified: send_command: %s", msg))
		return false
	}
	if !api.installed do return fail("no game is installed in this extension")
	sim_class, instance := sim_class_of(object)
	if sim_class == nil || sim_class.is_event {
		return fail("not one of the game's commands (make one with its class: `var drop := CommandDrop.new()`)")
	}
	if instance.bad do return fail(fmt.tprintf("%s has a property set to a wrong value", sim_class.name))
	if !api.running() do return fail("no session is running")
	// the object holds positions in view units (what a script reads back); the sim gets sim units
	bytes := instance.data
	for offset in api.commands[sim_class.kind].positions {
		position := (^sim.Position)(&bytes[offset])
		position^ = position_to_sim(position^)
	}
	command, ok := sim.command_from_bytes(api.commands_type, sim_class.kind, bytes[:sim_class.type.size])
	assert(ok)
	tick, player: u64 = 0, 0
	if active != nil && active.frame != nil do tick, player = u64(active.frame.tick), active.frame.local_player
	if !api.send(command) {
		dev_command(u32(tick), .Refused, player, &command)
		return fail("too many commands are waiting for the session")
	}
	dev_command(u32(tick), .Sent, player, &command)
	return true
}

// A command's position, from view units (what the script set) to sim units (Glue.view_scale).
position_to_sim :: proc(position: sim.Position) -> sim.Position {
	return sim.Position(to_sim(([3]f32)(position)))
}

// One field, from what a script set (field_kind says as what): ints (range-checked), floats, bools, enums (a member's
// value: EnumPhase.LOBBY), bit_sets (an Array of member values), a Vector2/3/4 or Vector2i/3i/4i ([2]/[3]/[4] of f32
// or i32), a Color (godot.Color), a Quaternion (godot.Quat), a sim.Position (Vector2 in a 2D game, else Vector3; in
// view units until send_command), a handle (its key: sim.handle_key, 0: none), a player (its key), a nested struct
// (an object of its class: DataArea.new()).
write_value :: proc(type: ^runtime.Type_Info, out: []u8, variant: ^gd.Variant) -> string {
	variant_type := gd.variant_type(variant)
	got :: proc(variant_type: gdi.VariantType) -> string {return fmt.tprintf("got %v", variant_type)}
	want, class_name := field_kind(type)
	switch {
	case type.id == sim.Position:
		position: sim.Position
		if variant_type != want do return fmt.tprintf("want a position (a %v), %s", want, got(variant_type))
		if api.is_2d {
			vector, _ := gd.from_variant(gd.Vector2, variant)
			position = {vector.x, vector.y, 0}
		} else {
			vector, _ := gd.from_variant(gd.Vector3, variant)
			position = {vector.x, vector.y, vector.z}
		}
		copy(out, ([^]u8)(&position)[:size_of(sim.Position)])
		return ""
	case is_handle(type):
		// a handle's key (sim.handle_key: generation << 32 | index; 0: the null handle)
		if variant_type != .INT do return fmt.tprintf("want a handle's key (an int), %s", got(variant_type))
		key, _ := gd.from_variant(i64, variant)
		handle := [2]u32{u32(u64(key) & 0xFFFF_FFFF), u32(u64(key) >> 32)} // index, generation
		if key != 0 && handle[1] == 0 do return fmt.tprintf("%d is not a handle's key", key)
		copy(out, ([^]u8)(&handle)[:8])
		return ""
	case type.id == sim.Player:
		// a player's key (sim.player_key; 0: nobody)
		if variant_type != .INT do return fmt.tprintf("want a player (an int), %s", got(variant_type))
		key, _ := gd.from_variant(i64, variant)
		player := sim.player_of_key(u64(key))
		if key != 0 && player == {} do return fmt.tprintf("%d is not a player", key)
		copy(out, ([^]u8)(&player)[:size_of(sim.Player)])
		return ""
	case type.id == sim.Entity:
		// a fixed thing's index (sim.entity(index); -1: none)
		if variant_type != .INT do return fmt.tprintf("want a thing's index (an int, -1: none), %s", got(variant_type))
		index, _ := gd.from_variant(i64, variant)
		if index < -1 do return fmt.tprintf("%d is not a thing's index (-1: none)", index)
		entity := index < 0 ? sim.Entity(0) : sim.entity(int(index))
		copy(out, ([^]u8)(&entity)[:size_of(sim.Entity)])
		return ""
	}
	#partial switch want {
	case .VECTOR2, .VECTOR3, .VECTOR4, .COLOR, .QUATERNION, .VECTOR2I, .VECTOR3I, .VECTOR4I:
		if variant_type != want do return fmt.tprintf("want a %v, %s", want, got(variant_type))
		value: [16]u8
		gd.variant_to_bytes(variant, want, value[:len(out)])
		copy(out, value[:len(out)])
		return ""
	case .OBJECT:
		// a nested struct: an object of its class, copied (its positions are in view units already)
		object, _ := gd.from_variant(gd.Object, variant)
		nested := D.nested[type.id]
		instance := (^Data_Object)(gd.instance_of(object, &nested.class)) if object.ptr != nil else nil
		if instance == nil do return fmt.tprintf("want a %s, %s", class_name, got(variant_type))
		copy(out, instance.bytes)
		return ""
	}
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Integer:
		if variant_type != .INT do return fmt.tprintf("want an int, %s", got(variant_type))
		integer, _ := gd.from_variant(i64, variant)
		if !int_fits(integer, type.size, info.signed) do return fmt.tprintf("%d does not fit %v", integer, type.id)
		put_int(out, integer)
	case runtime.Type_Info_Float:
		if variant_type != .INT && variant_type != .FLOAT do return fmt.tprintf("want a float, %s", got(variant_type))
		float, _ := gd.from_variant(f64, variant)
		if type.size == 4 {
			narrowed := f32(float)
			copy(out, ([^]u8)(&narrowed)[:4])
		} else if type.size == 8 {
			copy(out, ([^]u8)(&float)[:8])
		} else {
			return fmt.tprintf("unsupported float type %v", type.id)
		}
	case runtime.Type_Info_Boolean:
		if variant_type != .BOOL do return fmt.tprintf("want a bool, %s", got(variant_type))
		boolean, _ := gd.from_variant(bool, variant)
		out[0] = u8(boolean)
	case runtime.Type_Info_Enum:
		value, err := enum_value(type, info, variant)
		if err != "" do return err
		put_int(out, value)
	case runtime.Type_Info_Bit_Set:
		if variant_type != .ARRAY do return fmt.tprintf("want an Array of %v members, %s", info.elem.id, got(variant_type))
		array, _ := gd.from_variant(gd.Array, variant)
		defer gd.Array_destroy(&array)
		bits: u64
		for i in 0 ..< gd.array_len(&array) {
			item := gd.array_at(&array, i)
			value: i64
			if elem_enum, is_enum := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Enum); is_enum {
				err: string
				value, err = enum_value(info.elem, elem_enum, item)
				if err != "" do return fmt.tprintf("item %d: %s", i, err)
			} else if gd.variant_type(item) == .INT {
				value, _ = gd.from_variant(i64, item)
			} else {
				return fmt.tprintf("item %d: want an int, %s", i, got(gd.variant_type(item)))
			}
			if value < info.lower || value > info.upper do return fmt.tprintf("item %d: %d is outside %v", i, value, type.id)
			bits |= 1 << u64(value - info.lower)
		}
		put_int(out, i64(bits))
	case:
		return fmt.tprintf("unsupported field type %v", type.id)
	}
	return ""
}

// An enum member's value (an int, one of the members: the Enum* class's constants).
enum_value :: proc(type: ^runtime.Type_Info, info: runtime.Type_Info_Enum, variant: ^gd.Variant) -> (i64, string) {
	if variant_type := gd.variant_type(variant); variant_type != .INT {
		return 0, fmt.tprintf("want a %v value (an int), got %v", type.id, variant_type)
	}
	integer, _ := gd.from_variant(i64, variant)
	for member in info.values do if i64(member) == integer do return integer, ""
	names := strings.join(info.names, ", ", context.temp_allocator)
	return 0, fmt.tprintf("%d is not a %v (%s)", integer, type.id, names)
}

int_fits :: proc(value: i64, size: int, signed: bool) -> bool {
	if size >= 8 do return signed || value >= 0
	bits := u32(size * 8)
	if signed do return value >= -(i64(1) << (bits - 1)) && value < i64(1) << (bits - 1)
	return value >= 0 && value < i64(1) << bits
}

// The low len(out) bytes of value, little-endian.
put_int :: proc(out: []u8, value: i64) {
	bytes := transmute([8]u8)i64le(value)
	copy(out, bytes[:len(out)])
}
