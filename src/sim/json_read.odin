// A value from JSON, by RTTI: value_json's counterpart, what a save's Setup is read back with (setup_from_json). A
// reader driven by the value's type, so it allocates nothing but a problem's text. Never inside `tick`.
package sim

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

// Reads JSON `text` into the value of `type` at `data`, the way value_json writes it, over what the value holds: a
// struct's fields by name (a field the text lacks keeps its value; a key the type lacks, or a `_` field, is skipped),
// an array's elements in order (fewer: the rest keep theirs) or, as value_json writes a long one, an object of
// elements by index (the rest zeroed), an enumerated array's by member name, a List or Queue rebuilt from its items, a
// Bits from its indices, an enum by member name (any case) or value, a bit_set from its members' names or values, a
// sim.Player by its key, an f32 from a number (or a quoted "NaN" or "Inf"), integers range-checked. A sim.Table does
// not read. `problem` says what does not read and where ("" when all of it does; temp-allocated); the value is partly
// written then. Whether the result reads as sent is the caller's to ask (setup_violation).
value_from_json :: proc(type: ^runtime.Type_Info, data: rawptr, text: string) -> (problem: string) {
	reader := Json_Reader {
		text = text,
	}
	if problem = json_read(&reader, type, data, ""); problem != "" do return problem
	if json_peek(&reader) != 0 do return fmt.tprintf("text after the value at byte %d", reader.pos)
	return ""
}

@(private = "file")
Json_Reader :: struct {
	text: string,
	pos:  int,
}

// The next non-space byte (0 at the end), not taken.
@(private = "file")
json_peek :: proc(reader: ^Json_Reader) -> u8 {
	for reader.pos < len(reader.text) {
		switch reader.text[reader.pos] {
		case ' ', '\t', '\n', '\r':
			reader.pos += 1
		case:
			return reader.text[reader.pos]
		}
	}
	return 0
}

// Takes `c` when it is next.
@(private = "file")
json_take :: proc(reader: ^Json_Reader, c: u8) -> bool {
	if json_peek(reader) != c do return false
	reader.pos += 1
	return true
}

// After an element of an object or array: true at its end (`close` taken), false after a comma, a problem otherwise.
@(private = "file")
json_next :: proc(reader: ^Json_Reader, close: u8, path: string) -> (done: bool, problem: string) {
	if json_take(reader, close) do return true, ""
	if json_take(reader, ',') do return false, ""
	return true, fmt.tprintf("%s: expected ',' or '%c' at byte %d", where_of(path), close, reader.pos)
}

// A string's content (escapes decoded into the temp allocator; none: a slice of the text).
@(private = "file")
json_string :: proc(reader: ^Json_Reader) -> (value: string, ok: bool) {
	if !json_take(reader, '"') do return
	start := reader.pos
	escaped := false
	for reader.pos < len(reader.text) {
		switch reader.text[reader.pos] {
		case '"':
			raw := reader.text[start:reader.pos]
			reader.pos += 1
			if escaped do return json_unescape(raw)
			return raw, true
		case '\\':
			escaped = true
			reader.pos += 2
		case:
			reader.pos += 1
		}
	}
	return
}

@(private = "file")
json_unescape :: proc(raw: string) -> (value: string, ok: bool) {
	out := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(raw); i += 1 {
		if raw[i] != '\\' {
			strings.write_byte(&out, raw[i])
			continue
		}
		i += 1
		if i >= len(raw) do return
		switch raw[i] {
		case '"', '\\', '/':
			strings.write_byte(&out, raw[i])
		case 'b':
			strings.write_byte(&out, '\b')
		case 'f':
			strings.write_byte(&out, '\f')
		case 'n':
			strings.write_byte(&out, '\n')
		case 'r':
			strings.write_byte(&out, '\r')
		case 't':
			strings.write_byte(&out, '\t')
		case 'u':
			if i + 4 >= len(raw) do return
			code, code_ok := strconv.parse_u64(raw[i + 1:i + 5], 16)
			if !code_ok do return
			strings.write_rune(&out, rune(code))
			i += 4
		case:
			return
		}
	}
	return strings.to_string(out), true
}

// A literal's or a number's text (true, false, null, -12, 1.5e3), or a string's content.
@(private = "file")
json_word :: proc(reader: ^Json_Reader) -> (word: string, ok: bool) {
	if json_peek(reader) == '"' do return json_string(reader)
	start := reader.pos
	scan: for reader.pos < len(reader.text) {
		switch reader.text[reader.pos] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '+', '.':
			reader.pos += 1
		case:
			break scan
		}
	}
	return reader.text[start:reader.pos], reader.pos > start
}

// Skips one value of any kind (a key the type lacks).
@(private = "file")
json_skip :: proc(reader: ^Json_Reader) -> bool {
	switch json_peek(reader) {
	case '{', '[':
		close: u8 = '}' if reader.text[reader.pos] == '{' else ']'
		reader.pos += 1
		if json_take(reader, close) do return true
		for {
			if close == '}' {
				if _, ok := json_string(reader); !ok || !json_take(reader, ':') do return false
			}
			if !json_skip(reader) do return false
			if done, problem := json_next(reader, close, ""); done do return problem == ""
		}
	case:
		_, ok := json_word(reader)
		return ok
	}
}

@(private = "file")
where_of :: proc(path: string) -> string {
	return path if path != "" else "the value"
}

@(private = "file")
json_read :: proc(reader: ^Json_Reader, type: ^runtime.Type_Info, data: rawptr, path: string) -> string {
	if type.id == Player do return json_leaf(reader, type, data, path)
	if kind := collection_kind(type); kind != .None do return json_collection_read(reader, kind, type, data, path)
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Struct:
		if _, _, is_table := table_fields(info); is_table {
			return fmt.tprintf("%s: a sim.Table does not read from JSON", where_of(path))
		}
		if !json_take(reader, '{') do return fmt.tprintf("%s: not an object", where_of(path))
		if json_take(reader, '}') do return ""
		for {
			key, ok := json_string(reader)
			if !ok || !json_take(reader, ':') do return fmt.tprintf("%s: a bad key at byte %d", where_of(path), reader.pos)
			field := -1
			if !strings.has_prefix(key, "_") {
				for i in 0 ..< int(info.field_count) do if info.names[i] == key do field = i
			}
			if field < 0 {
				if !json_skip(reader) do return fmt.tprintf("%s: a bad value at byte %d", where_of(path), reader.pos)
			} else {
				inner := key if path == "" else fmt.tprintf("%s.%s", path, key)
				problem := json_read(reader, info.types[field], at(data, int(info.offsets[field])), inner)
				if problem != "" do return problem
			}
			if done, problem := json_next(reader, '}', path); done do return problem
		}
	case runtime.Type_Info_Array:
		if json_take(reader, '{') { 	// value_json's long array: its non-zero elements by index
			runtime.mem_zero(data, type.size)
			if json_take(reader, '}') do return ""
			for {
				key, ok := json_string(reader)
				index, is_index := strconv.parse_int(key, 10)
				if !ok || !json_take(reader, ':') || !is_index || index < 0 || index >= info.count {
					return fmt.tprintf("%s: no element %q", where_of(path), key)
				}
				inner := fmt.tprintf("%s[%d]", path, index)
				if problem := json_read(reader, info.elem, at(data, index * info.elem_size), inner); problem != "" {
					return problem
				}
				if done, problem := json_next(reader, '}', path); done do return problem
			}
		}
		if !json_take(reader, '[') do return fmt.tprintf("%s: not an array", where_of(path))
		if json_take(reader, ']') do return ""
		for index := 0;; index += 1 {
			if index >= info.count do return fmt.tprintf("%s: more than %d elements", where_of(path), info.count)
			inner := fmt.tprintf("%s[%d]", path, index)
			if problem := json_read(reader, info.elem, at(data, index * info.elem_size), inner); problem != "" {
				return problem
			}
			if done, problem := json_next(reader, ']', path); done do return problem
		}
	case runtime.Type_Info_Enumerated_Array:
		if !json_take(reader, '{') do return fmt.tprintf("%s: not an object", where_of(path))
		if json_take(reader, '}') do return ""
		names, is_enum := runtime.type_info_base(info.index).variant.(runtime.Type_Info_Enum)
		for {
			key, ok := json_string(reader)
			if !ok || !json_take(reader, ':') do return fmt.tprintf("%s: a bad key at byte %d", where_of(path), reader.pos)
			index := -1
			if parsed, is_number := strconv.parse_int(key, 10); is_number {
				index = parsed - int(info.min_value)
			} else if is_enum {
				for name, k in names.names {
					if strings.equal_fold(name, key) do index = int(i64(names.values[k]) - i64(info.min_value))
				}
			}
			if index < 0 || index >= info.count do return fmt.tprintf("%s: no element %q", where_of(path), key)
			inner := fmt.tprintf("%s[%s]", path, key)
			if problem := json_read(reader, info.elem, at(data, index * info.elem_size), inner); problem != "" {
				return problem
			}
			if done, problem := json_next(reader, '}', path); done do return problem
		}
	case runtime.Type_Info_Bit_Set:
		// its members joined as text_value reads a bit_set ("a|b", "{}": none)
		if !json_take(reader, '[') do return fmt.tprintf("%s: not an array", where_of(path))
		joined := strings.builder_make(context.temp_allocator)
		if !json_take(reader, ']') {
			for {
				member, ok := json_word(reader)
				if !ok do return fmt.tprintf("%s: a bad member at byte %d", where_of(path), reader.pos)
				if strings.builder_len(joined) > 0 do strings.write_byte(&joined, '|')
				strings.write_string(&joined, member)
				if done, problem := json_next(reader, ']', path); done {
					if problem != "" do return problem
					break
				}
			}
		}
		members := strings.to_string(joined)
		if problem := text_value(data, type, members if members != "" else "{}"); problem != "" {
			return fmt.tprintf("%s: %s", where_of(path), problem)
		}
		return ""
	}
	return json_leaf(reader, type, data, path)
}

// A leaf (an integer, f32, bool, enum or player) from a number, a literal or a string, as text_value reads it (a u64
// past i64's range too).
@(private = "file")
json_leaf :: proc(reader: ^Json_Reader, type: ^runtime.Type_Info, data: rawptr, path: string) -> string {
	text, ok := json_word(reader)
	if !ok || text == "null" do return fmt.tprintf("%s: no value at byte %d", where_of(path), reader.pos)
	if integer, is_integer := runtime.type_info_base(type).variant.(runtime.Type_Info_Integer);
	   is_integer && !integer.signed && type.size == 8 {
		value, parsed := strconv.parse_u64(text, 10)
		if !parsed do return fmt.tprintf("%s: %q is not a u64", where_of(path), text)
		(^u64)(data)^ = value
		return ""
	}
	if problem := text_value(data, type, text); problem != "" do return fmt.tprintf("%s: %s", where_of(path), problem)
	return ""
}

// A List or Queue rebuilt from its items (zeroed first, a Queue's head 0), a Bits from its indices.
@(private = "file")
json_collection_read :: proc(
	reader: ^Json_Reader,
	kind: Collection,
	type: ^runtime.Type_Info,
	data: rawptr,
	path: string,
) -> string {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	last := int(info.field_count) - 1
	items := ([^]u8)(at(data, int(info.offsets[last])))
	array := runtime.type_info_base(info.types[last]).variant.(runtime.Type_Info_Array)
	runtime.mem_zero(data, type.size)
	if !json_take(reader, '[') do return fmt.tprintf("%s: not an array", where_of(path))
	if json_take(reader, ']') do return ""
	for count := 0;; count += 1 {
		if kind == .Bits {
			text, _ := json_word(reader)
			bit, ok := strconv.parse_int(text, 10)
			if !ok || bit < 0 || bit >= array.count * 64 do return fmt.tprintf("%s: %q is no index of the set", where_of(path), text)
			items[bit / 8] |= 1 << uint(bit % 8)
		} else {
			if count >= array.count do return fmt.tprintf("%s: more than %d items", where_of(path), array.count)
			inner := fmt.tprintf("%s[%d]", path, count)
			if problem := json_read(reader, array.elem, &items[count * array.elem_size], inner); problem != "" {
				return problem
			}
			for i in 0 ..< int(info.field_count) {
				if info.names[i] == "count" do write_integer(at(data, int(info.offsets[i])), info.types[i], i64(count + 1))
			}
		}
		if done, problem := json_next(reader, ']', path); done do return problem
	}
}
