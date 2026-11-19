// A value from JSON, by RTTI: value_json's counterpart, what a save's Setup is read back with (setup_from_json). A
// strict JSON reader driven by the value's type: it allocates nothing unless it reports a problem. Never inside `tick`.
package sim

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

// How deep JSON may nest, in what value_from_json reads and in what it skips: deeper is a problem, never a deep
// recursion.
JSON_DEPTH_MAX :: 64

// Reads JSON `text` into the value of `type` at `data`, the way value_json writes it, over what the value holds: a
// struct's fields by name (a field the text lacks keeps its value; a key the type lacks, or a `_` field, is skipped),
// an array's elements in order (fewer: the rest keep theirs) or, as value_json writes a long one, an object of
// elements by index (the rest zeroed), an enumerated array's by member name, a List or Queue rebuilt from its items, a
// sim.Bits from its indices (each below its size), an enum by member name (any case) or value, a bit_set from its
// members' names or values, a sim.Player by its key, an f32 from a number (or the string "NaN", "+Inf" or "-Inf"),
// integers range-checked. Strict JSON: no comments, no trailing commas, no bare words, no number in quotes, a key at
// most once in an object, nesting at most JSON_DEPTH_MAX deep. A sim.Table does not read. `problem` says what does not
// read and where ("" when all of it does; temp-allocated); the value is partly written then. Whether the result reads
// as sent is the caller's to ask (setup_violation). Allocates only for a problem.
value_from_json :: proc(type: ^runtime.Type_Info, data: rawptr, text: string) -> (problem: string) {
	reader := Json_Reader {
		text = text,
	}
	if problem = json_read(&reader, type, data); problem != "" do return problem
	if json_peek(&reader) != 0 do return json_problem(&reader, "text after the value")
	return ""
}

@(private = "file")
Json_Reader :: struct {
	text:    string,
	pos:     int,
	depth:   int, // the nesting being read or skipped
	trusted: bool, // a rescan of text read before (json_key_seen): no duplicate checks
	path:    [JSON_DEPTH_MAX]Json_Segment, // where the reader is, for a problem
	steps:   int,
}

// One step of a problem's path: a field (`.name`), an element (`[index]`) or an enumerated array's (`[name]`).
@(private = "file")
Json_Segment :: struct {
	name:    string,
	index:   int,
	bracket: bool,
}

// A problem at the reader's place: its path, then what (temp-allocated: the only allocation).
@(private = "file")
json_problem :: proc(reader: ^Json_Reader, format: string, args: ..any) -> string {
	out := strings.builder_make(context.temp_allocator)
	for segment, k in reader.path[:reader.steps] {
		switch {
		case segment.bracket:
			fmt.sbprintf(&out, "[%s]", segment.name)
		case segment.name == "":
			fmt.sbprintf(&out, "[%d]", segment.index)
		case:
			if k > 0 do strings.write_byte(&out, '.')
			strings.write_string(&out, segment.name)
		}
	}
	if reader.steps == 0 do strings.write_string(&out, "the value")
	strings.write_string(&out, ": ")
	fmt.sbprintf(&out, format, ..args)
	fmt.sbprintf(&out, " (at byte %d)", reader.pos)
	return strings.to_string(out)
}

@(private = "file")
json_push :: proc(reader: ^Json_Reader, segment: Json_Segment) {
	reader.path[reader.steps] = segment
	reader.steps += 1
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

// After an element of an object or array: done at its end (`close` taken), not after a comma, a problem otherwise.
@(private = "file")
json_next :: proc(reader: ^Json_Reader, close: u8) -> (done: bool, problem: string) {
	if json_take(reader, close) do return true, ""
	if json_take(reader, ',') && json_peek(reader) != close do return false, ""
	return true, json_problem(reader, "expected ',' or '%c'", close)
}

// A string, as it is in the text between its quotes (escapes checked, not decoded).
@(private = "file")
json_string :: proc(reader: ^Json_Reader) -> (raw: string, escaped, ok: bool) {
	if !json_take(reader, '"') do return
	start := reader.pos
	for reader.pos < len(reader.text) {
		c := reader.text[reader.pos]
		switch {
		case c == '"':
			raw = reader.text[start:reader.pos]
			reader.pos += 1
			return raw, escaped, true
		case c < 0x20:
			return
		case c == '\\':
			escaped = true
			if reader.pos + 1 >= len(reader.text) do return
			switch reader.text[reader.pos + 1] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				reader.pos += 2
			case 'u':
				if reader.pos + 6 > len(reader.text) do return
				for h in reader.text[reader.pos + 2:reader.pos + 6] {
					if !(h >= '0' && h <= '9' || h >= 'a' && h <= 'f' || h >= 'A' && h <= 'F') do return
				}
				reader.pos += 6
			case:
				return
			}
		case:
			reader.pos += 1
		}
	}
	return
}

// A key's or member name's text: `raw` itself, or decoded into `buffer` when it has escapes (one past the buffer, or
// past ASCII, decodes to "": a name it can't be).
@(private = "file")
json_name :: proc(raw: string, escaped: bool, buffer: []u8) -> string {
	if !escaped do return raw
	n := 0
	for i := 0; i < len(raw); i += 1 {
		c := raw[i]
		if c == '\\' {
			i += 1
			switch raw[i] {
			case 'b':
				c = '\b'
			case 'f':
				c = '\f'
			case 'n':
				c = '\n'
			case 'r':
				c = '\r'
			case 't':
				c = '\t'
			case 'u':
				code, _ := strconv.parse_u64(raw[i + 1:i + 5], 16)
				if code >= 0x80 do return ""
				c = u8(code)
				i += 4
			case:
				c = raw[i]
			}
		}
		if n >= len(buffer) do return ""
		buffer[n] = c
		n += 1
	}
	return string(buffer[:n])
}

// A number's text, by JSON's grammar: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?; `integer` when it has no fraction
// or exponent.
@(private = "file")
json_number :: proc(reader: ^Json_Reader) -> (text: string, integer, ok: bool) {
	json_peek(reader)
	start, at := reader.pos, reader.pos
	digits :: proc(text: string, at: ^int) -> int {
		from := at^
		for at^ < len(text) && text[at^] >= '0' && text[at^] <= '9' do at^ += 1
		return at^ - from
	}
	if at < len(reader.text) && reader.text[at] == '-' do at += 1
	whole_at := at
	whole := digits(reader.text, &at)
	if whole == 0 || (whole > 1 && reader.text[whole_at] == '0') do return
	integer = true
	if at < len(reader.text) && reader.text[at] == '.' {
		at += 1
		if digits(reader.text, &at) == 0 do return
		integer = false
	}
	if at < len(reader.text) && (reader.text[at] == 'e' || reader.text[at] == 'E') {
		at += 1
		if at < len(reader.text) && (reader.text[at] == '+' || reader.text[at] == '-') do at += 1
		if digits(reader.text, &at) == 0 do return
		integer = false
	}
	reader.pos = at
	return reader.text[start:at], integer, true
}

// Takes the literal `word` (true, false, null) when it is next.
@(private = "file")
json_literal :: proc(reader: ^Json_Reader, word: string) -> bool {
	json_peek(reader)
	if !strings.has_prefix(reader.text[reader.pos:], word) do return false
	reader.pos += len(word)
	return true
}

// Whether the object that starts at `object` (just after its '{') has the key `raw` before the one at `key`.
@(private = "file")
json_key_seen :: proc(reader: ^Json_Reader, object, key: int, raw: string) -> bool {
	if reader.trusted do return false
	scan := Json_Reader {
		text    = reader.text,
		pos     = object,
		trusted = true,
	}
	for {
		json_peek(&scan)
		if scan.pos >= key do return false
		earlier, _, _ := json_string(&scan)
		if earlier == raw do return true
		json_take(&scan, ':')
		json_skip(&scan)
		json_take(&scan, ',')
	}
}

// Reads an object's next key (`at`: where it starts), refusing a repeated one; then its ':'.
@(private = "file")
json_key :: proc(reader: ^Json_Reader, object: int) -> (raw: string, escaped: bool, problem: string) {
	at := json_peek(reader) == '"' ? reader.pos : -1
	ok: bool
	if raw, escaped, ok = json_string(reader); !ok || at < 0 do return raw, escaped, json_problem(reader, "a bad key")
	if json_key_seen(reader, object, at, raw) do return raw, escaped, json_problem(reader, "the key %q twice", raw)
	if !json_take(reader, ':') do return raw, escaped, json_problem(reader, "expected ':'")
	return raw, escaped, ""
}

// Skips one value of any kind (a key the type lacks), as strictly as a value read.
@(private = "file")
json_skip :: proc(reader: ^Json_Reader) -> string {
	if reader.depth >= JSON_DEPTH_MAX do return json_problem(reader, "nested deeper than %d", JSON_DEPTH_MAX)
	reader.depth += 1
	defer reader.depth -= 1
	switch json_peek(reader) {
	case '{', '[':
		close: u8 = '}' if reader.text[reader.pos] == '{' else ']'
		reader.pos += 1
		object := reader.pos
		if json_take(reader, close) do return ""
		for {
			if close == '}' {
				if _, _, problem := json_key(reader, object); problem != "" do return problem
			}
			if problem := json_skip(reader); problem != "" do return problem
			if done, problem := json_next(reader, close); done do return problem
		}
	case '"':
		if _, _, ok := json_string(reader); !ok do return json_problem(reader, "a bad string")
	case 't', 'f', 'n':
		if !json_literal(reader, "true") && !json_literal(reader, "false") && !json_literal(reader, "null") {
			return json_problem(reader, "not a JSON value")
		}
	case:
		if _, _, ok := json_number(reader); !ok do return json_problem(reader, "not a JSON value")
	}
	return ""
}

@(private = "file")
json_read :: proc(reader: ^Json_Reader, type: ^runtime.Type_Info, data: rawptr) -> string {
	if reader.depth >= JSON_DEPTH_MAX do return json_problem(reader, "nested deeper than %d", JSON_DEPTH_MAX)
	reader.depth += 1
	defer reader.depth -= 1
	if type.id == Player do return json_leaf(reader, type, data)
	if collection := collection_kind(type); collection != .None {
		return json_collection_read(reader, collection, type, data)
	}
	name_buffer: [64]u8
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Struct:
		if _, _, is_table := table_fields(info); is_table do return json_problem(reader, "a sim.Table does not read from JSON")
		if !json_take(reader, '{') do return json_problem(reader, "not an object")
		object := reader.pos
		if json_take(reader, '}') do return ""
		for {
			raw, escaped, problem := json_key(reader, object)
			if problem != "" do return problem
			key := json_name(raw, escaped, name_buffer[:])
			field := -1
			if !strings.has_prefix(key, "_") {
				for i in 0 ..< int(info.field_count) do if info.names[i] == key do field = i
			}
			if field < 0 {
				problem = json_skip(reader)
			} else {
				json_push(reader, {name = info.names[field]})
				problem = json_read(reader, info.types[field], at(data, int(info.offsets[field])))
				reader.steps -= 1
			}
			if problem != "" do return problem
			if done, next_problem := json_next(reader, '}'); done do return next_problem
		}
	case runtime.Type_Info_Array:
		if json_take(reader, '{') { 	// value_json's long array: its non-zero elements by index
			runtime.mem_zero(data, type.size)
			object := reader.pos
			if json_take(reader, '}') do return ""
			for {
				raw, _, problem := json_key(reader, object)
				if problem != "" do return problem
				index, is_index := strconv.parse_int(raw, 10)
				if !is_index || index < 0 || index >= info.count do return json_problem(reader, "no element %q", raw)
				json_push(reader, {index = index})
				problem = json_read(reader, info.elem, at(data, index * info.elem_size))
				reader.steps -= 1
				if problem != "" do return problem
				if done, next_problem := json_next(reader, '}'); done do return next_problem
			}
		}
		if !json_take(reader, '[') do return json_problem(reader, "not an array")
		if json_take(reader, ']') do return ""
		for index := 0;; index += 1 {
			if index >= info.count do return json_problem(reader, "more than %d elements", info.count)
			json_push(reader, {index = index})
			problem := json_read(reader, info.elem, at(data, index * info.elem_size))
			reader.steps -= 1
			if problem != "" do return problem
			if done, next_problem := json_next(reader, ']'); done do return next_problem
		}
	case runtime.Type_Info_Enumerated_Array:
		if !json_take(reader, '{') do return json_problem(reader, "not an object")
		object := reader.pos
		if json_take(reader, '}') do return ""
		names, is_enum := runtime.type_info_base(info.index).variant.(runtime.Type_Info_Enum)
		for {
			raw, escaped, problem := json_key(reader, object)
			if problem != "" do return problem
			key := json_name(raw, escaped, name_buffer[:])
			index := -1
			label := raw // the path's: the member's own name, or the text's
			if is_enum {
				for name, k in names.names {
					if strings.equal_fold(name, key) do index, label = int(i64(names.values[k]) - i64(info.min_value)), name
				}
			}
			if parsed, is_number := strconv.parse_int(key, 10); index < 0 && is_number {
				index = parsed - int(info.min_value)
			}
			if index < 0 || index >= info.count do return json_problem(reader, "no element %q", key)
			json_push(reader, {name = label, bracket = true})
			problem = json_read(reader, info.elem, at(data, index * info.elem_size))
			reader.steps -= 1
			if problem != "" do return problem
			if done, next_problem := json_next(reader, '}'); done do return next_problem
		}
	case runtime.Type_Info_Bit_Set:
		if !json_take(reader, '[') do return json_problem(reader, "not an array")
		runtime.mem_zero(data, type.size)
		if json_take(reader, ']') do return ""
		names, is_enum := runtime.type_info_base(info.elem).variant.(runtime.Type_Info_Enum)
		for {
			bit := i64(-1)
			if json_peek(reader) == '"' {
				raw, escaped, ok := json_string(reader)
				member := json_name(raw, escaped, name_buffer[:])
				if ok && is_enum do for name, k in names.names do if strings.equal_fold(name, member) do bit = i64(names.values[k])
				if bit < 0 do return json_problem(reader, "%q is not a member of %v", member, type.id)
			} else {
				text, integer, ok := json_number(reader)
				value, parsed := strconv.parse_i64(text)
				if !ok || !integer || !parsed do return json_problem(reader, "not a member")
				bit = value
			}
			if bit < info.lower || bit > info.upper do return json_problem(reader, "%d is not an element of %v", bit, type.id)
			offset := bit - info.lower
			([^]u8)(data)[offset / 8] |= 1 << uint(offset % 8)
			if done, problem := json_next(reader, ']'); done do return problem
		}
	}
	return json_leaf(reader, type, data)
}

// A leaf: an integer or a player from a JSON integer, an f32 from a number (or "NaN", "+Inf", "-Inf"), a bool from
// true or false, an enum from a member's name or its value.
@(private = "file")
json_leaf :: proc(reader: ^Json_Reader, type: ^runtime.Type_Info, data: rawptr) -> string {
	if type.id == Player {
		text, integer, ok := json_number(reader)
		key, parsed := strconv.parse_u64(text, 10)
		player := player_of_key(key)
		if !ok || !integer || !parsed || (key != 0 && player == {}) do return json_problem(reader, "not a player's key")
		(^Player)(data)^ = player
		return ""
	}
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Integer:
		text, integer, ok := json_number(reader)
		if !ok || !integer do return json_problem(reader, "not an integer")
		if !info.signed && type.size == 8 {
			value, parsed := strconv.parse_u64(text, 10)
			if !parsed do return json_problem(reader, "%s is out of %v's range", text, type.id)
			(^u64)(data)^ = value
			return ""
		}
		value, parsed := strconv.parse_i64(text, 10)
		if !parsed do return json_problem(reader, "%s is out of %v's range", text, type.id)
		if problem := write_integer(data, type, value); problem != "" do return json_problem(reader, "%s", problem)
	case runtime.Type_Info_Float:
		if type.size != 4 do return json_problem(reader, "%v does not read from JSON", type.id)
		value: f32
		if json_peek(reader) == '"' {
			raw, _, _ := json_string(reader)
			switch raw {
			case "NaN":
				value = transmute(f32)u32(0x7FC0_0000)
			case "+Inf":
				value = transmute(f32)u32(0x7F80_0000)
			case "-Inf":
				value = transmute(f32)u32(0xFF80_0000)
			case:
				return json_problem(reader, "%q is not a number", raw)
			}
		} else {
			text, _, ok := json_number(reader)
			parsed: bool
			value, parsed = strconv.parse_f32(text)
			if !ok || !parsed do return json_problem(reader, "not a number")
		}
		(^f32)(data)^ = value
	case runtime.Type_Info_Boolean:
		set: bool
		if json_literal(reader, "true") {
			set = true
		} else if !json_literal(reader, "false") {
			return json_problem(reader, "not true or false")
		}
		runtime.mem_zero(data, type.size)
		(^u8)(data)^ = u8(set)
	case runtime.Type_Info_Enum:
		if json_peek(reader) == '"' {
			name_buffer: [64]u8
			raw, escaped, _ := json_string(reader)
			member := json_name(raw, escaped, name_buffer[:])
			for name, k in info.names {
				if strings.equal_fold(name, member) do return json_problem_of(reader, write_integer(data, info.base, i64(info.values[k])))
			}
			return json_problem(reader, "%q is not a member of %v", member, type.id)
		}
		text, integer, ok := json_number(reader)
		value, parsed := strconv.parse_i64(text, 10)
		if !ok || !integer || !parsed do return json_problem(reader, "not a member of %v", type.id)
		return json_problem_of(reader, write_integer(data, info.base, value))
	case:
		return json_problem(reader, "%v does not read from JSON", type.id)
	}
	return ""
}

// write_integer's problem at the reader's place ("" stays "").
@(private = "file")
json_problem_of :: proc(reader: ^Json_Reader, problem: string) -> string {
	return json_problem(reader, "%s", problem) if problem != "" else ""
}

// A List or Queue rebuilt from its items (zeroed first, a Queue's head 0), a Bits from its indices.
@(private = "file")
json_collection_read :: proc(
	reader: ^Json_Reader,
	collection: Collection,
	type: ^runtime.Type_Info,
	data: rawptr,
) -> string {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	last := int(info.field_count) - 1
	items := ([^]u8)(at(data, int(info.offsets[last])))
	array := runtime.type_info_base(info.types[last]).variant.(runtime.Type_Info_Array)
	runtime.mem_zero(data, type.size)
	if !json_take(reader, '[') do return json_problem(reader, "not an array")
	if json_take(reader, ']') do return ""
	for count := 0;; count += 1 {
		if collection == .Bits {
			text, integer, ok := json_number(reader)
			bit, parsed := strconv.parse_int(text, 10)
			if !ok || !integer || !parsed || bit < 0 || bit >= bits_capacity(type) {
				return json_problem(reader, "not an index below %d", bits_capacity(type))
			}
			items[bit / 8] |= 1 << uint(bit % 8)
		} else {
			if count >= array.count do return json_problem(reader, "more than %d items", array.count)
			json_push(reader, {index = count})
			problem := json_read(reader, array.elem, &items[count * array.elem_size])
			reader.steps -= 1
			if problem != "" do return problem
			for i in 0 ..< int(info.field_count) {
				if info.names[i] == "count" do write_integer(at(data, int(info.offsets[i])), info.types[i], i64(count + 1))
			}
		}
		if done, problem := json_next(reader, ']'); done do return problem
	}
}
