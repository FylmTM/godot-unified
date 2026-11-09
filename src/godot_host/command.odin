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
	for k, i in api.commands do if k.name == name do kind = i
	if kind < 0 {
		names := make([]string, len(api.commands), context.temp_allocator)
		for k, i in api.commands do names[i] = k.name
		return fail(
			name,
			fmt.tprintf("not one of the game's commands (%s)", strings.join(names, ", ", context.temp_allocator)),
		)
	}
	ti := type_info_of(api.commands[kind].id)
	buf: [sim.COMMAND_MAX]u8
	if err := dict_to_struct(ti, buf[:ti.size], args); err != "" do return fail(name, err)
	c, ok := sim.command_from_bytes(api.commands, kind, buf[:ti.size])
	assert(ok)
	if !api.running() do return fail(name, "no session is running")
	if !api.send(c) do return fail(name, "too many commands are waiting for the session")
	return true
}

// Fills a command struct from a Dictionary of its field names. Fields named `_...` are explicit padding:
// left zero, never given. Returns what is wrong ("" when nothing is).
@(private)
dict_to_struct :: proc(ti: ^runtime.Type_Info, out: []u8, d: ^gd.Dictionary) -> string {
	st, is_struct := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	if !is_struct do return fmt.tprintf("%v is not a struct", ti.id)
	fields := make([dynamic]string, 0, st.field_count, context.temp_allocator)
	for i in 0 ..< int(st.field_count) {
		if !strings.has_prefix(st.names[i], "_") do append(&fields, st.names[i])
	}
	field_list := strings.join(fields[:], ", ", context.temp_allocator)
	keys := gd.Dictionary_keys(d)
	defer gd.Array_destroy(&keys)
	for i in 0 ..< gd.array_len(&keys) {
		k, ok := gd.from_variant(string, gd.array_at(&keys, i))
		known := false
		if ok do for f in fields do known ||= f == k
		if !known {
			return fmt.tprintf("unknown field %v (fields: %s)", ok ? fmt.tprintf("%q", k) : "(not a name)", field_list)
		}
	}
	for i in 0 ..< int(st.field_count) {
		name := st.names[i]
		if strings.has_prefix(name, "_") do continue
		key := gd.to_variant(name)
		defer gdi.variant_destroy(&key)
		if !gd.Dictionary_has(d, key) do return fmt.tprintf("missing field %q (fields: %s)", name, field_list)
		nil_v := gd.variant_nil()
		v := gd.Dictionary_get(d, key, nil_v)
		defer gdi.variant_destroy(&v)
		ft := st.types[i]
		if err := write_value(ft, out[st.offsets[i]:][:ft.size], &v); err != "" {
			return fmt.tprintf("field %q: %s", name, err)
		}
	}
	return ""
}

// One field: ints (range-checked), floats, bools, enums (a member's name, any case, or its value), bit_sets
// (an Array of member names or values), [2]f32 / [3]f32 (Vector2 / Vector3).
@(private)
write_value :: proc(ti: ^runtime.Type_Info, out: []u8, v: ^gd.Variant) -> string {
	vt := gd.variant_type(v)
	got :: proc(vt: gdi.VariantType) -> string {return fmt.tprintf("got %v", vt)}
	#partial switch t in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer:
		if vt != .INT do return fmt.tprintf("want an int, %s", got(vt))
		i, _ := gd.from_variant(i64, v)
		if !int_fits(i, ti.size, t.signed) do return fmt.tprintf("%d does not fit %v", i, ti.id)
		put_int(out, i)
	case runtime.Type_Info_Float:
		if vt != .INT && vt != .FLOAT do return fmt.tprintf("want a float, %s", got(vt))
		f, _ := gd.from_variant(f64, v)
		if ti.size == 4 {
			x := f32(f)
			copy(out, ([^]u8)(&x)[:4])
		} else if ti.size == 8 {
			copy(out, ([^]u8)(&f)[:8])
		} else {
			return fmt.tprintf("unsupported float type %v", ti.id)
		}
	case runtime.Type_Info_Boolean:
		if vt != .BOOL do return fmt.tprintf("want a bool, %s", got(vt))
		b, _ := gd.from_variant(bool, v)
		out[0] = u8(b)
	case runtime.Type_Info_Enum:
		val, err := enum_value(ti, t, v)
		if err != "" do return err
		put_int(out, val)
	case runtime.Type_Info_Bit_Set:
		if vt != .ARRAY do return fmt.tprintf("want an Array of %v members, %s", t.elem.id, got(vt))
		a, _ := gd.from_variant(gd.Array, v)
		defer gd.Array_destroy(&a)
		bits: u64
		for i in 0 ..< gd.array_len(&a) {
			e := gd.array_at(&a, i)
			val: i64
			if et, is_enum := runtime.type_info_base(t.elem).variant.(runtime.Type_Info_Enum); is_enum {
				err: string
				val, err = enum_value(t.elem, et, e)
				if err != "" do return fmt.tprintf("item %d: %s", i, err)
			} else if gd.variant_type(e) == .INT {
				val, _ = gd.from_variant(i64, e)
			} else {
				return fmt.tprintf("item %d: want an int, %s", i, got(gd.variant_type(e)))
			}
			if val < t.lower || val > t.upper do return fmt.tprintf("item %d: %d is outside %v", i, val, ti.id)
			bits |= 1 << u64(val - t.lower)
		}
		put_int(out, i64(bits))
	case runtime.Type_Info_Array:
		if t.elem.id != f32 || (t.count != 2 && t.count != 3) {
			return fmt.tprintf("unsupported field type %v", ti.id)
		}
		xyz: [3]f32
		if t.count == 2 {
			if vt != .VECTOR2 do return fmt.tprintf("want a Vector2, %s", got(vt))
			p, _ := gd.from_variant(gd.Vector2, v)
			xyz.xy = {p.x, p.y}
		} else {
			if vt != .VECTOR3 do return fmt.tprintf("want a Vector3, %s", got(vt))
			p, _ := gd.from_variant(gd.Vector3, v)
			xyz = {p.x, p.y, p.z}
		}
		copy(out, ([^]u8)(&xyz)[:4 * t.count])
	case:
		return fmt.tprintf("unsupported field type %v", ti.id)
	}
	return ""
}

// An enum member's value from its name (any case) or its value.
@(private)
enum_value :: proc(ti: ^runtime.Type_Info, t: runtime.Type_Info_Enum, v: ^gd.Variant) -> (i64, string) {
	#partial switch vt := gd.variant_type(v); vt {
	case .INT:
		i, _ := gd.from_variant(i64, v)
		for x in t.values do if i64(x) == i do return i, ""
		return 0, fmt.tprintf("%d is not a %v", i, ti.id)
	case .STRING, .STRING_NAME:
		s, _ := gd.from_variant(string, v)
		for n, k in t.names do if strings.equal_fold(n, s) do return i64(t.values[k]), ""
		return 0, fmt.tprintf("%q is not a %v (%s)", s, ti.id, strings.join(t.names, ", ", context.temp_allocator))
	case:
		return 0, fmt.tprintf("want a %v name or value, got %v", ti.id, vt)
	}
}

@(private)
int_fits :: proc(i: i64, size: int, signed: bool) -> bool {
	if size >= 8 do return signed || i >= 0
	bits := u32(size * 8)
	if signed do return i >= -(i64(1) << (bits - 1)) && i < i64(1) << (bits - 1)
	return i >= 0 && i < i64(1) << bits
}

// The low len(out) bytes of v, little-endian.
@(private)
put_int :: proc(out: []u8, v: i64) {
	x := transmute([8]u8)i64le(v)
	copy(out, x[:len(out)])
}
