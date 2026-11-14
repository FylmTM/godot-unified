// UnifiedSession.send_command(command): a command object (a class sim_classes.odin registered from the game's
// command union) becomes the command's struct, then goes to the session thread, which hands it to the client
// (driver.odin).
package godot

import "base:runtime"
import "core:fmt"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"

// One kind of the game's command union.
Command_Layout :: struct {
	name: string, // the type name without `Cmd_`, lowercased ("drop")
	type: ^runtime.Type_Info,
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
		return fail("not one of the game's commands (make one with its class: `var drop := Drop.new()`)")
	}
	if instance.bad do return fail(fmt.tprintf("%s has a property set to a wrong value", sim_class.name))
	command, ok := sim.command_from_bytes(api.commands_type, sim_class.kind, instance.data[:sim_class.type.size])
	assert(ok)
	if !api.running() do return fail("no session is running")
	if !api.send(command) do return fail("too many commands are waiting for the session")
	return true
}

// One field: ints (range-checked), floats, bools, enums (a member's name, any case, or its value), bit_sets
// (an Array of member names or values), [2]f32 / [3]f32 / [4]f32 (Vector2 / Vector3 / Color).
@(private)
write_value :: proc(type: ^runtime.Type_Info, out: []u8, variant: ^gd.Variant) -> string {
	variant_type := gd.variant_type(variant)
	got :: proc(variant_type: gdi.VariantType) -> string {return fmt.tprintf("got %v", variant_type)}
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
	case runtime.Type_Info_Array:
		if info.elem.id != f32 || info.count < 2 || info.count > 4 {
			return fmt.tprintf("unsupported field type %v", type.id)
		}
		xyz: [4]f32
		if info.count == 4 {
			if variant_type != .COLOR do return fmt.tprintf("want a Color, %s", got(variant_type))
			color, _ := gd.from_variant(gd.Color, variant)
			xyz = {color.r, color.g, color.b, color.a}
		} else if info.count == 2 {
			if variant_type != .VECTOR2 do return fmt.tprintf("want a Vector2, %s", got(variant_type))
			vector, _ := gd.from_variant(gd.Vector2, variant)
			xyz.xy = {vector.x, vector.y}
		} else {
			if variant_type != .VECTOR3 do return fmt.tprintf("want a Vector3, %s", got(variant_type))
			vector, _ := gd.from_variant(gd.Vector3, variant)
			xyz.xyz = {vector.x, vector.y, vector.z}
		}
		copy(out, ([^]u8)(&xyz)[:4 * info.count])
	case:
		return fmt.tprintf("unsupported field type %v", type.id)
	}
	return ""
}

// An enum member's value from its name (any case) or its value.
@(private)
enum_value :: proc(type: ^runtime.Type_Info, info: runtime.Type_Info_Enum, variant: ^gd.Variant) -> (i64, string) {
	#partial switch variant_type := gd.variant_type(variant); variant_type {
	case .INT:
		integer, _ := gd.from_variant(i64, variant)
		for member in info.values do if i64(member) == integer do return integer, ""
		return 0, fmt.tprintf("%d is not a %v", integer, type.id)
	case .STRING, .STRING_NAME:
		given, _ := gd.from_variant(string, variant)
		for name, k in info.names do if strings.equal_fold(name, given) do return i64(info.values[k]), ""
		names := strings.join(info.names, ", ", context.temp_allocator)
		return 0, fmt.tprintf("%q is not a %v (%s)", given, type.id, names)
	case:
		return 0, fmt.tprintf("want a %v name or value, got %v", type.id, variant_type)
	}
}

@(private)
int_fits :: proc(value: i64, size: int, signed: bool) -> bool {
	if size >= 8 do return signed || value >= 0
	bits := u32(size * 8)
	if signed do return value >= -(i64(1) << (bits - 1)) && value < i64(1) << (bits - 1)
	return value >= 0 && value < i64(1) << bits
}

// The low len(out) bytes of value, little-endian.
@(private)
put_int :: proc(out: []u8, value: i64) {
	bytes := transmute([8]u8)i64le(value)
	copy(out, bytes[:len(out)])
}
