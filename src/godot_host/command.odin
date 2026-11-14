// UnifiedSession.send_command(name, args): a GDScript Dictionary becomes the game's command struct by RTTI
// (no per-game glue), then goes to the session thread, which hands it to the client (driver.odin).
package godot_host

import "base:runtime"
import "core:fmt"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"

// Main thread. False, with print_error naming what is wrong, for an unknown command, a missing or unknown
// field, a value of the wrong type or out of range, no running session, or a full queue.
send_command :: proc(name: string, args: ^gd.Dictionary) -> bool {
	fail :: proc(name, msg: string) -> bool {
		gd.print_error(fmt.tprintf("unified: send_command(&%q): %s", name, msg))
		return false
	}
	if !api.installed do return fail(name, "no game is installed in this extension")
	kind := -1
	for command_name, i in api.command_names do if command_name == name do kind = i
	if kind < 0 {
		names := strings.join(api.command_names, ", ", context.temp_allocator)
		return fail(name, fmt.tprintf("not one of the game's commands (%s)", names))
	}
	type := sim.union_variants(api.commands)[kind]
	bytes: [sim.COMMAND_MAX]u8
	if err := dict_to_struct(type, bytes[:type.size], args); err != "" do return fail(name, err)
	command, ok := sim.command_from_bytes(api.commands, kind, bytes[:type.size])
	assert(ok)
	if !api.running() do return fail(name, "no session is running")
	if !api.send(command) do return fail(name, "too many commands are waiting for the session")
	return true
}

// Fills a command struct from a Dictionary of its field names. Fields named `_...` are explicit padding:
// left zero, never given. Returns what is wrong ("" when nothing is).
@(private)
dict_to_struct :: proc(type: ^runtime.Type_Info, out: []u8, dict: ^gd.Dictionary) -> string {
	struct_info, is_struct := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	if !is_struct do return fmt.tprintf("%v is not a struct", type.id)
	fields := make([dynamic]string, 0, struct_info.field_count, context.temp_allocator)
	for i in 0 ..< int(struct_info.field_count) {
		if !strings.has_prefix(struct_info.names[i], "_") do append(&fields, struct_info.names[i])
	}
	field_list := strings.join(fields[:], ", ", context.temp_allocator)
	keys := gd.Dictionary_keys(dict)
	defer gd.Array_destroy(&keys)
	for i in 0 ..< gd.array_len(&keys) {
		given, ok := gd.from_variant(string, gd.array_at(&keys, i))
		known := false
		if ok do for field in fields do known ||= field == given
		if !known {
			return fmt.tprintf(
				"unknown field %v (fields: %s)",
				ok ? fmt.tprintf("%q", given) : "(not a name)",
				field_list,
			)
		}
	}
	for i in 0 ..< int(struct_info.field_count) {
		name := struct_info.names[i]
		if strings.has_prefix(name, "_") do continue
		key := gd.to_variant(name)
		defer gdi.variant_destroy(&key)
		if !gd.Dictionary_has(dict, key) do return fmt.tprintf("missing field %q (fields: %s)", name, field_list)
		nil_variant := gd.variant_nil()
		value := gd.Dictionary_get(dict, key, nil_variant)
		defer gdi.variant_destroy(&value)
		field_type := struct_info.types[i]
		if err := write_value(field_type, out[struct_info.offsets[i]:][:field_type.size], &value); err != "" {
			return fmt.tprintf("field %q: %s", name, err)
		}
	}
	return ""
}

// One field: ints (range-checked), floats, bools, enums (a member's name, any case, or its value), bit_sets
// (an Array of member names or values), [2]f32 / [3]f32 (Vector2 / Vector3).
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
		if info.elem.id != f32 || (info.count != 2 && info.count != 3) {
			return fmt.tprintf("unsupported field type %v", type.id)
		}
		xyz: [3]f32
		if info.count == 2 {
			if variant_type != .VECTOR2 do return fmt.tprintf("want a Vector2, %s", got(variant_type))
			vector, _ := gd.from_variant(gd.Vector2, variant)
			xyz.xy = {vector.x, vector.y}
		} else {
			if variant_type != .VECTOR3 do return fmt.tprintf("want a Vector3, %s", got(variant_type))
			vector, _ := gd.from_variant(gd.Vector3, variant)
			xyz = {vector.x, vector.y, vector.z}
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
