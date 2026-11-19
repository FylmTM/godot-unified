// A plain struct from text, by RTTI: `key=value[,key=value...]`, what the headless `--setup`, the Godot session's
// `--setup` and `--profile` flags and the control socket's commands say. Never inside `tick`.
package sim

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

// A plain struct (a Setup, a Profile) of type T made from `start` and the assignments in `text`, comma-separated
// `key=value`: integers, f32, bools (true, false, 1, 0), enums by member name (any case) or value, bit_sets as
// member names joined by `|` (`{}`: none), a sim.Player by its key (player_key); `a.b` names a nested struct's field,
// `a[2]` an array's element (an enumerated array's also by member name). `problem` says what does not parse (""
// when all of it does; temp-allocated); the value is `start` then. Whether the result reads as sent is the caller's to ask
// (setup_violation): an enum given by an undeclared value does not.
//
//   setup, problem := sim.struct_from_text(game.setup, "difficulty=hard,start_wave=3")
struct_from_text :: proc(start: $T, text: string) -> (value: T, problem: string) {
	value = start
	if problem = assign_text(&value, type_info_of(T), text); problem != "" {
		return start, problem
	}
	return
}

// struct_from_text for a type known at run time: the assignments in `text` written into the value of `type` at
// `data` (a command the control socket builds from text). The problem says what does not parse ("" when all of it
// does; temp-allocated); the fields before it are written then.
assign_text :: proc(data: rawptr, type: ^runtime.Type_Info, text: string) -> string {
	rest := text
	for assignment in strings.split_iterator(&rest, ",") {
		trimmed := strings.trim_space(assignment)
		if trimmed == "" do continue
		equals := strings.index_byte(trimmed, '=')
		if equals < 0 do return fmt.tprintf("%q: not key=value", trimmed)
		key, value := strings.trim_space(trimmed[:equals]), strings.trim_space(trimmed[equals + 1:])
		target, target_type, problem := text_path(data, type, key)
		if problem != "" do return problem
		if problem = text_value(target, target_type, value); problem != "" {
			return fmt.tprintf("%s: %s", key, problem)
		}
	}
	return ""
}

// Where the field a path names (`a.b[2].c`) lives, and its type.
@(private)
text_path :: proc(
	data: rawptr,
	type: ^runtime.Type_Info,
	path: string,
) -> (
	target: rawptr,
	target_type: ^runtime.Type_Info,
	problem: string,
) {
	target, target_type = data, type
	rest := path
	for rest != "" {
		if rest[0] == '[' {
			close := strings.index_byte(rest, ']')
			if close < 0 do return nil, nil, fmt.tprintf("%q: an unclosed [", path)
			index_text := rest[1:close]
			rest = rest[close + 1:]
			if strings.has_prefix(rest, ".") do rest = rest[1:]
			index := -1
			elem: ^runtime.Type_Info
			count, elem_size: int
			#partial switch info in runtime.type_info_base(target_type).variant {
			case runtime.Type_Info_Array:
				elem, count, elem_size = info.elem, info.count, info.elem_size
				if parsed, ok := strconv.parse_int(index_text, 10); ok do index = parsed
			case runtime.Type_Info_Enumerated_Array:
				elem, count, elem_size = info.elem, info.count, info.elem_size
				if parsed, ok := strconv.parse_int(index_text, 10); ok {
					index = parsed
				} else if names, is_enum := runtime.type_info_base(info.index).variant.(runtime.Type_Info_Enum);
				   is_enum {
					for name, i in names.names {
						if strings.equal_fold(name, index_text) do index = int(i64(names.values[i]) - i64(info.min_value))
					}
				}
			case:
				return nil, nil, fmt.tprintf("%q: %v is not an array", path, target_type.id)
			}
			if index < 0 || index >= count do return nil, nil, fmt.tprintf("%q: no element %s", path, index_text)
			target, target_type = rawptr(uintptr(target) + uintptr(index * elem_size)), elem
			continue
		}
		end := len(rest)
		for c, i in rest {
			if c == '.' || c == '[' {
				end = i
				break
			}
		}
		name := rest[:end]
		rest = rest[end:]
		if strings.has_prefix(rest, ".") do rest = rest[1:]
		info, is_struct := runtime.type_info_base(target_type).variant.(runtime.Type_Info_Struct)
		if !is_struct do return nil, nil, fmt.tprintf("%q: %v has no fields", path, target_type.id)
		found := false
		for i in 0 ..< int(info.field_count) {
			if info.names[i] == name {
				target, target_type = rawptr(uintptr(target) + info.offsets[i]), info.types[i]
				found = true
				break
			}
		}
		if !found do return nil, nil, fmt.tprintf("%q: %v has no field %q", path, target_type.id, name)
	}
	return
}

// Writes `text` into the leaf at `target` as its type reads it.
@(private)
text_value :: proc(target: rawptr, type: ^runtime.Type_Info, text: string) -> string {
	if type.id == Player { 	// by its key (player_key), as GDScript and the control socket name a player
		key, ok := strconv.parse_u64(text)
		player := player_of_key(key)
		if !ok || (key != 0 && player == {}) do return fmt.tprintf("%q is not a player's key", text)
		(^Player)(target)^ = player
		return ""
	}
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Integer:
		return text_integer(target, type, text)
	case runtime.Type_Info_Float:
		parsed, ok := strconv.parse_f32(text)
		if !ok || type.size != 4 do return fmt.tprintf("%q is not an f32", text)
		(^f32)(target)^ = parsed
	case runtime.Type_Info_Boolean:
		set: bool
		switch strings.to_lower(text, context.temp_allocator) {
		case "true", "1":
			set = true
		case "false", "0":
			set = false
		case:
			return fmt.tprintf("%q is not a bool (true, false)", text)
		}
		runtime.mem_zero(target, type.size)
		(^u8)(target)^ = u8(set)
	case runtime.Type_Info_Enum:
		for name, i in info.names {
			if strings.equal_fold(name, text) {
				return write_integer(target, info.base, i64(info.values[i]))
			}
		}
		if _, ok := strconv.parse_i64(text); !ok {
			return fmt.tprintf(
				"%q is none of %v's members (%s)",
				text,
				type.id,
				strings.join(info.names, ", ", context.temp_allocator),
			)
		}
		return text_integer(target, info.base, text)
	case runtime.Type_Info_Bit_Set:
		runtime.mem_zero(target, type.size)
		if text == "{}" do return ""
		names, is_enum := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Enum)
		rest := text
		for element_text in strings.split_iterator(&rest, "|") {
			element := strings.trim_space(element_text)
			bit := i64(-1)
			if is_enum {
				for name, i in names.names do if strings.equal_fold(name, element) do bit = i64(names.values[i])
			} else if parsed, ok := strconv.parse_i64(element); ok {
				bit = parsed
			}
			if bit < info.lower || bit > info.upper do return fmt.tprintf("%q is not an element of %v", element, type.id)
			offset := bit - info.lower
			([^]u8)(target)[offset / 8] |= 1 << uint(offset % 8)
		}
	case:
		return fmt.tprintf("%v can't be given as text", type.id)
	}
	return ""
}

@(private)
text_integer :: proc(target: rawptr, type: ^runtime.Type_Info, text: string) -> string {
	parsed, ok := strconv.parse_i64(text)
	if !ok do return fmt.tprintf("%q is not an integer", text)
	return write_integer(target, type, parsed)
}

// Writes an integer of `type` (a sized integer) at `target`, refusing one it can't hold.
@(private)
write_integer :: proc(target: rawptr, type: ^runtime.Type_Info, value: i64) -> string {
	integer, is_integer := runtime.type_info_base(type).variant.(runtime.Type_Info_Integer)
	if !is_integer do return fmt.tprintf("%v is not an integer", type.id)
	bits := uint(type.size * 8)
	low, high: i64
	if integer.signed {
		low, high = -(i64(1) << (bits - 1)), (i64(1) << (bits - 1)) - 1
	} else {
		low, high = 0, bits >= 64 ? max(i64) : (i64(1) << bits) - 1
	}
	if value < low || value > high do return fmt.tprintf("%d is out of %v's range", value, type.id)
	switch type.size {
	case 1:
		(^u8)(target)^ = u8(value)
	case 2:
		(^u16)(target)^ = u16(value)
	case 4:
		(^u32)(target)^ = u32(value)
	case:
		(^u64)(target)^ = u64(value)
	}
	return ""
}
