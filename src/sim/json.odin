// A value as JSON, by RTTI, read the way the tools read the State: a sim.Table by its live items, a List or Queue by
// its live items in order, a Bits by the indices it holds, a player by its key. What the Godot host's control socket
// answers a state query with (src/godot/README.md, The control socket). Never inside `tick`.
package sim

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

import "unified:dmath"

// An array longer than this is written as an object of its non-zero elements by index ({"12": ...}): a State's big
// arrays are mostly zero (a free list, an unused pool).
JSON_ARRAY_FULL :: 64

// Writes the value of `type` at `data` as JSON: a struct an object of its fields (`_` fields left out), a sim.Table an
// object of its live items by index (`{"3": {...}}`), a List or Queue an array of its items (a Queue's oldest first),
// a Bits an array of the indices it holds, an array an array (longer than JSON_ARRAY_FULL: an object of its non-zero
// elements by index), an enumerated array an object by member name, an enum its member's name (an undeclared value:
// its number), a bit_set an array of member names, a sim.Player its key (player_key: 0 is nobody), an f32 a number
// (not finite: a string).
value_json :: proc(out: ^strings.Builder, type: ^runtime.Type_Info, data: rawptr) {
	bytes := ([^]u8)(data)[:type.size]
	if type.id == Player {
		fmt.sbprintf(out, "%d", player_key((^Player)(data)^))
		return
	}
	if kind := collection_kind(type); kind != .None {
		json_collection(out, kind, type, bytes)
		return
	}
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Struct:
		if items, slots, is_table := table_fields(info); is_table {
			json_table(out, info, items, slots, bytes)
			return
		}
		strings.write_byte(out, '{')
		first := true
		for i in 0 ..< int(info.field_count) {
			if strings.has_prefix(info.names[i], "_") do continue
			if !first do strings.write_byte(out, ',')
			first = false
			strings.write_quoted_string(out, info.names[i])
			strings.write_byte(out, ':')
			value_json(out, info.types[i], at(data, int(info.offsets[i])))
		}
		strings.write_byte(out, '}')
	case runtime.Type_Info_Array:
		json_array(out, info.elem, info.elem_size, info.count, bytes)
	case runtime.Type_Info_Enumerated_Array:
		names, is_enum := runtime.type_info_base(info.index).variant.(runtime.Type_Info_Enum)
		strings.write_byte(out, '{')
		for i in 0 ..< info.count {
			if i > 0 do strings.write_byte(out, ',')
			name := fmt.tprint(i64(info.min_value) + i64(i))
			if is_enum {
				for value, k in names.values do if i64(value) == i64(info.min_value) + i64(i) do name = names.names[k]
			}
			strings.write_quoted_string(out, name)
			strings.write_byte(out, ':')
			value_json(out, info.elem, at(data, i * info.elem_size))
		}
		strings.write_byte(out, '}')
	case runtime.Type_Info_Enum:
		value := read_integer(data, info.base)
		for member, k in info.values {
			if i64(member) == value {
				strings.write_quoted_string(out, info.names[k])
				return
			}
		}
		fmt.sbprintf(out, "%d", value)
	case runtime.Type_Info_Bit_Set:
		names, is_enum := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Enum)
		strings.write_byte(out, '[')
		first := true
		for bit in info.lower ..= info.upper {
			offset := bit - info.lower
			if bytes[offset / 8] & (1 << uint(offset % 8)) == 0 do continue
			if !first do strings.write_byte(out, ',')
			first = false
			name := ""
			if is_enum do for value, k in names.values do if i64(value) == bit do name = names.names[k]
			if name != "" do strings.write_quoted_string(out, name)
			else do fmt.sbprintf(out, "%d", bit)
		}
		strings.write_byte(out, ']')
	case runtime.Type_Info_Integer:
		if info.signed do fmt.sbprintf(out, "%d", read_integer(data, type))
		else do fmt.sbprintf(out, "%d", u64(read_integer(data, type)))
	case runtime.Type_Info_Float:
		value := f64((^f32)(data)^) if type.size == 4 else (^f64)(data)^
		if value != value || value - value != 0 { 	// NaN or infinite
			strings.write_quoted_string(out, fmt.tprint(value))
		} else {
			buffer: [64]u8
			text := strconv.write_float(buffer[:], value, 'g', -1, 32 if type.size == 4 else 64)
			strings.write_string(out, strings.trim_prefix(text, "+")) // it writes a sign: JSON has none for positive numbers
		}
	case runtime.Type_Info_Boolean:
		strings.write_string(out, bytes[0] != 0 ? "true" : "false")
	case:
		strings.write_quoted_string(out, fmt.tprint(any{data, type.id}))
	}
}

// Writes the part of a value that `path` names as JSON (value_json): fields by name and elements by index, joined as
// diffs and the op log name them (`players.slots[0]`, `enemies[12].pos.x`): a Table's element by its index (a dead
// one is null), a List's or Queue's by its place among the live items, an enumerated array's also by member name. ""
// is the whole value. `problem` says what the path does not name ("" when it names something; temp-allocated), and
// nothing is written then.
value_json_at :: proc(
	out: ^strings.Builder,
	type: ^runtime.Type_Info,
	data: rawptr,
	path: string,
) -> (
	problem: string,
) {
	target, target_type := data, type
	rest := path
	for rest != "" {
		if rest[0] == '[' {
			close := strings.index_byte(rest, ']')
			if close < 0 do return fmt.tprintf("%q: an unclosed [", path)
			index_text := rest[1:close]
			rest = strings.trim_prefix(rest[close + 1:], ".")
			alive: int
			target, target_type, alive, problem = json_element(target, target_type, index_text)
			if problem != "" do return problem
			if alive == 0 {
				if rest != "" do return fmt.tprintf("%q: element %s is not alive", path, index_text)
				strings.write_string(out, "null")
				return ""
			}
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
		rest = strings.trim_prefix(rest[end:], ".")
		info, is_struct := runtime.type_info_base(target_type).variant.(runtime.Type_Info_Struct)
		if !is_struct || collection_kind(target_type) != .None do return fmt.tprintf("%q: %v has no fields", path, target_type.id)
		found := false
		for i in 0 ..< int(info.field_count) {
			if info.names[i] == name {
				target, target_type = rawptr(uintptr(target) + info.offsets[i]), info.types[i]
				found = true
				break
			}
		}
		if !found do return fmt.tprintf("%q: %v has no field %q", path, target_type.id, name)
	}
	value_json(out, target_type, target)
	return ""
}

// The element `index_text` names in a value of `type` (value_json_at): `alive` 0 for a Table's dead item.
@(private)
json_element :: proc(
	data: rawptr,
	type: ^runtime.Type_Info,
	index_text: string,
) -> (
	target: rawptr,
	target_type: ^runtime.Type_Info,
	alive: int,
	problem: string,
) {
	index, is_number := strconv.parse_int(index_text, 10)
	bytes := ([^]u8)(data)[:type.size]
	if kind := collection_kind(type); kind == .List || kind == .Queue {
		info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
		last := int(info.field_count) - 1
		array := runtime.type_info_base(info.types[last]).variant.(runtime.Type_Info_Array)
		count, head := collection_field(info, bytes, "count"), collection_field(info, bytes, "head")
		if !is_number || index < 0 || index >= dmath.min(count, array.count) {
			return nil, nil, 0, fmt.tprintf("[%s]: %v holds %d items", index_text, type.id, count)
		}
		place := (head + index) % array.count
		return at(data, int(info.offsets[last]) + place * array.elem_size), array.elem, 1, ""
	}
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Struct:
		items, slots, is_table := table_fields(info)
		if !is_table do break
		array := runtime.type_info_base(info.types[items]).variant.(runtime.Type_Info_Array)
		if !is_number || index < 0 || index >= array.count {
			return nil, nil, 0, fmt.tprintf("[%s]: %v has %d items", index_text, type.id, array.count)
		}
		slot := (^Slot)(at(data, int(info.offsets[slots]) + index * size_of(Slot)))
		return at(data, int(info.offsets[items]) + index * array.elem_size), array.elem, int(slot.alive), ""
	case runtime.Type_Info_Array:
		if !is_number || index < 0 || index >= info.count {
			return nil, nil, 0, fmt.tprintf("[%s]: %v has %d elements", index_text, type.id, info.count)
		}
		return at(data, index * info.elem_size), info.elem, 1, ""
	case runtime.Type_Info_Enumerated_Array:
		if !is_number {
			index = -1
			if names, is_enum := runtime.type_info_base(info.index).variant.(runtime.Type_Info_Enum); is_enum {
				for name, k in names.names {
					if strings.equal_fold(name, index_text) do index = int(i64(names.values[k]) - i64(info.min_value))
				}
			}
		}
		if index < 0 || index >= info.count {
			return nil, nil, 0, fmt.tprintf("[%s]: no element of %v", index_text, type.id)
		}
		return at(data, index * info.elem_size), info.elem, 1, ""
	}
	return nil, nil, 0, fmt.tprintf("[%s]: %v is not an array", index_text, type.id)
}

// A sim.Table's `items` and `slots` fields (by RTTI: an array of Slot beside the items), as diff_value finds them.
@(private)
table_fields :: proc(info: runtime.Type_Info_Struct) -> (items, slots: int, ok: bool) {
	items, slots = -1, -1
	for i in 0 ..< int(info.field_count) {
		switch info.names[i] {
		case "items":
			items = i
		case "slots":
			if array, is_array := info.types[i].variant.(runtime.Type_Info_Array); is_array && array.elem.id == Slot {
				slots = i
			}
		}
	}
	return items, slots, items >= 0 && slots >= 0
}

@(private)
json_table :: proc(out: ^strings.Builder, info: runtime.Type_Info_Struct, items, slots: int, bytes: []u8) {
	array := runtime.type_info_base(info.types[items]).variant.(runtime.Type_Info_Array)
	strings.write_byte(out, '{')
	first := true
	for k in 0 ..< array.count {
		slot := (^Slot)(at(raw_data(bytes), int(info.offsets[slots]) + k * size_of(Slot)))
		if !slot.alive do continue
		if !first do strings.write_byte(out, ',')
		first = false
		fmt.sbprintf(out, `"%d":`, k)
		value_json(out, array.elem, at(raw_data(bytes), int(info.offsets[items]) + k * array.elem_size))
	}
	strings.write_byte(out, '}')
}

@(private)
json_collection :: proc(out: ^strings.Builder, kind: Collection, type: ^runtime.Type_Info, bytes: []u8) {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	last := int(info.field_count) - 1
	items_at := int(info.offsets[last])
	array := runtime.type_info_base(info.types[last]).variant.(runtime.Type_Info_Array)
	strings.write_byte(out, '[')
	if kind == .Bits {
		first := true
		for bit in 0 ..< array.count * 64 {
			if bytes[items_at + bit / 8] & (1 << uint(bit % 8)) == 0 do continue
			if !first do strings.write_byte(out, ',')
			first = false
			fmt.sbprintf(out, "%d", bit)
		}
	} else {
		count := dmath.min(collection_field(info, bytes, "count"), array.count)
		head := dmath.min(collection_field(info, bytes, "head"), array.count - 1)
		for k in 0 ..< count {
			if k > 0 do strings.write_byte(out, ',')
			place := (head + k) % array.count
			value_json(out, array.elem, at(raw_data(bytes), items_at + place * array.elem_size))
		}
	}
	strings.write_byte(out, ']')
}

@(private)
json_array :: proc(out: ^strings.Builder, elem: ^runtime.Type_Info, elem_size, count: int, bytes: []u8) {
	if count <= JSON_ARRAY_FULL {
		strings.write_byte(out, '[')
		for i in 0 ..< count {
			if i > 0 do strings.write_byte(out, ',')
			value_json(out, elem, at(raw_data(bytes), i * elem_size))
		}
		strings.write_byte(out, ']')
		return
	}
	strings.write_byte(out, '{')
	first := true
	for i in 0 ..< count {
		element := bytes[i * elem_size:][:elem_size]
		zero := true
		for b in element do if b != 0 {zero = false; break}
		if zero do continue
		if !first do strings.write_byte(out, ',')
		first = false
		fmt.sbprintf(out, `"%d":`, i)
		value_json(out, elem, raw_data(element))
	}
	strings.write_byte(out, '}')
}

// The address `offset` bytes into a value: a zero-size element (sim.No_Profile) has an address but no bytes to index.
@(private = "file")
at :: proc(data: rawptr, offset: int) -> rawptr {
	return rawptr(uintptr(data) + uintptr(offset))
}
