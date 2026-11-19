// Typed desync reports (src/netcode/README.md, Checksums and desyncs): what differs between two snapshots of the
// same tick, field by field through the State's RTTI (a table's items by index), then the extra's image.
package sim

import "base:runtime"
import "core:fmt"
import "core:strings"

import "unified:dmath"
import "unified:wire"

@(private)
DIFF_MAX :: 8 // differences listed; the rest are counted

@(private)
Diff :: struct {
	text:  strings.Builder,
	count: int,
}

@(private)
diff_note :: proc(diff: ^Diff, format: string, args: ..any) {
	diff.count += 1
	if diff.count > DIFF_MAX {
		return
	}
	if diff.count > 1 {
		strings.write_string(&diff.text, "; ")
	}
	fmt.sbprintf(&diff.text, format, ..args)
}

// What differs between two snapshots of this build ("" when nothing does; temp-allocated): "tick 4160:
// enemies[12].pos.x 3.25 vs 3.5; ..." down to the leaf field of the state's tables and globals, then the extra's
// image by its first differing byte. At most DIFF_MAX are listed.
snapshot_diff :: proc($State: typeid, a, b: []u8) -> string {
	header_a, block_a, reader_a, err_a := snap_read(a, size_of(State), layout_hash(State))
	header_b, block_b, reader_b, err_b := snap_read(b, size_of(State), layout_hash(State))
	if err_a != .None || err_b != .None {
		return fmt.tprintf("the snapshots don't decode (%v, %v)", err_a, err_b)
	}
	return diff_blocks(type_info_of(State), header_a, header_b, block_a, block_b, &reader_a, &reader_b)
}

@(private)
diff_blocks :: proc(
	state: ^runtime.Type_Info,
	header_a, header_b: Snap_Header,
	block_a, block_b: []u8,
	reader_a, reader_b: ^wire.Reader,
) -> string {
	diff := Diff {
		text = strings.builder_make(context.temp_allocator),
	}
	if header_a.tick != header_b.tick {
		diff_note(&diff, "the snapshots are of ticks %d and %d", header_a.tick, header_b.tick)
	}
	diff_value(&diff, "", state, block_a, block_b)
	image_a, ok_a := snap_extra(reader_a)
	image_b, ok_b := snap_extra(reader_b)
	if !ok_a || !ok_b {
		diff_note(&diff, "extra: an image is cut short")
	} else if string(image_a) != string(image_b) {
		first := 0
		for first < dmath.min(len(image_a), len(image_b)) && image_a[first] == image_b[first] {
			first += 1
		}
		diff_note(&diff, "extra: its image differs from byte %d (%d vs %d bytes)", first, len(image_a), len(image_b))
	}
	if diff.count == 0 {
		return ""
	}
	if diff.count > DIFF_MAX {
		fmt.sbprintf(&diff.text, "; and %d more", diff.count - DIFF_MAX)
	}
	return fmt.tprintf("tick %d: %s", header_a.tick, strings.to_string(diff.text))
}

// What differs between two lists of one tick's events ("" when nothing does; temp-allocated): their count, an event's
// kind, or its fields, padding aside ("event 2 of 3, hit: damage 3 vs 4"). The sync-test compares a re-simulated
// tick's events with the first run's: a tick emits the same events every time it is computed.
events_diff :: proc(a, b: []Raw_Event, $Event: typeid) -> string {
	return events_diff_of(a, b, union_variants(Event))
}

// events_diff's body, for the union's variants at run time.
@(private)
events_diff_of :: proc(a, b: []Raw_Event, variants: []^runtime.Type_Info) -> string {
	if len(a) != len(b) {
		return fmt.tprintf("%d events, then %d", len(b), len(a))
	}
	for i in 0 ..< len(a) {
		x, y := &a[i], &b[i]
		if x.kind != y.kind || x.size != y.size || int(x.kind) >= len(variants) {
			return fmt.tprintf("event %d of %d: kind %d, then %d", i + 1, len(a), y.kind, x.kind)
		}
		if string(x.data[:x.size]) == string(y.data[:y.size]) do continue // the usual case: the same bytes
		variant := variants[x.kind]
		diff := Diff {
			text = strings.builder_make(context.temp_allocator),
		}
		diff_value(&diff, "", variant, y.data[:y.size], x.data[:x.size])
		if diff.count > 0 {
			return fmt.tprintf(
				"event %d of %d, %s: %s",
				i + 1,
				len(a),
				variant_name(variant, EVENT_PREFIX),
				strings.to_string(diff.text),
			)
		}
	}
	return ""
}

// Notes where two values of `type` differ: each differing leaf field (a struct's fields and an array's elements are
// walked), "path a vs b". A sim.Table reads as its items by index (`enemies[12].pos.x`), with its slots' liveness
// noted apart; a List, Queue or Bits by its live items (diff_collection).
@(private)
diff_value :: proc(diff: ^Diff, path: string, type: ^runtime.Type_Info, a, b: []u8) {
	if string(a) == string(b) {
		return
	}
	if kind := collection_kind(type); kind != .None {
		diff_collection(diff, path, kind, type, a, b)
		return
	}
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Struct:
		items, slots := -1, -1
		for i in 0 ..< int(info.field_count) {
			switch info.names[i] {
			case "items":
				items = i
			case "slots":
				if array, is_array := info.types[i].variant.(runtime.Type_Info_Array);
				   is_array && array.elem.id == Slot {
					slots = i
				}
			}
		}
		for i in 0 ..< int(info.field_count) {
			field_type, offset := info.types[i], int(info.offsets[i])
			field_a, field_b := a[offset:][:field_type.size], b[offset:][:field_type.size]
			if items >= 0 && slots >= 0 && (i == items || i == slots) {
				array := runtime.type_info_base(field_type).variant.(runtime.Type_Info_Array)
				for k in 0 ..< array.count {
					item_a, item_b :=
						field_a[k *
						array.elem_size:][:array.elem_size],
						field_b[k *
						array.elem_size:][:array.elem_size]
					if i == slots && string(item_a) != string(item_b) {
						diff_note(diff, "%s[%d]: its slot (alive, generation) differs", path, k)
					} else if i == items {
						diff_value(diff, fmt.tprintf("%s[%d]", path, k), array.elem, item_a, item_b)
					}
				}
				continue
			}
			name := info.names[i] if path == "" else fmt.tprintf("%s.%s", path, info.names[i])
			diff_value(diff, name, field_type, field_a, field_b)
		}
		return
	case runtime.Type_Info_Array:
		size := info.elem_size
		for i in 0 ..< info.count {
			diff_value(diff, fmt.tprintf("%s[%d]", path, i), info.elem, a[i * size:][:size], b[i * size:][:size])
		}
		return
	case runtime.Type_Info_Enumerated_Array:
		size := info.elem_size
		for i in 0 ..< info.count {
			diff_value(diff, fmt.tprintf("%s[%d]", path, i), info.elem, a[i * size:][:size], b[i * size:][:size])
		}
		return
	}
	diff_note(diff, "%s %v vs %v", path, any{raw_data(a), type.id}, any{raw_data(b), type.id})
}

// Which of the inline collections (collections.odin) a type is, by its RTTI name: tools read them by their live items.
@(private)
Collection :: enum u8 {
	None,
	List,
	Queue,
	Bits,
}

@(private)
collection_kind :: proc(type: ^runtime.Type_Info) -> Collection {
	named, is_named := type.variant.(runtime.Type_Info_Named)
	if !is_named || named.pkg != "sim" do return .None
	switch {
	case strings.has_prefix(named.name, "List("):
		return .List
	case strings.has_prefix(named.name, "Queue("):
		return .Queue
	case strings.has_prefix(named.name, "Bits("):
		return .Bits
	}
	return .None
}

// A List's or a Queue's field `name` (its count or head) as an integer, from the collection's bytes (0: no such field).
@(private)
collection_field :: proc(info: runtime.Type_Info_Struct, bytes: []u8, name: string) -> int {
	for i in 0 ..< int(info.field_count) {
		if info.names[i] != name do continue
		value := 0
		for k in 0 ..< info.types[i].size do value |= int(bytes[int(info.offsets[i]) + k]) << uint(8 * k)
		return value
	}
	return 0
}

// A collection's differences: a List's or a Queue's count ("bag: 2 vs 3 items"), then its items, a List's by index
// and a Queue's oldest first, up to the larger count; a Bits as the indices each holds ("open: {3, 64} vs {3}").
@(private)
diff_collection :: proc(diff: ^Diff, path: string, kind: Collection, type: ^runtime.Type_Info, a, b: []u8) {
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	last := int(info.field_count) - 1
	items_at := int(info.offsets[last])
	array := runtime.type_info_base(info.types[last]).variant.(runtime.Type_Info_Array)
	if kind == .Bits {
		diff_note(diff, "%s: %s vs %s", path, bits_text(a, array.count), bits_text(b, array.count))
		return
	}
	count_a, count_b := collection_field(info, a, "count"), collection_field(info, b, "count")
	head_a, head_b := collection_field(info, a, "head"), collection_field(info, b, "head")
	if count_a != count_b do diff_note(diff, "%s: %d vs %d items", path, count_a, count_b)
	size := array.elem_size
	for k in 0 ..< dmath.max(count_a, count_b) {
		at_a, at_b := (head_a + k) % array.count, (head_b + k) % array.count
		item_a, item_b := a[items_at + at_a * size:][:size], b[items_at + at_b * size:][:size]
		diff_value(diff, fmt.tprintf("%s[%d]", path, k), array.elem, item_a, item_b)
	}
}

// A Bits' indices as "{3, 64}" from its `words` u64 words, at most 16 listed. Temp-allocated.
@(private)
bits_text :: proc(bytes: []u8, words: int) -> string {
	text := strings.builder_make(context.temp_allocator)
	strings.write_byte(&text, '{')
	listed := 0
	for word in 0 ..< words {
		for bit in 0 ..< 64 {
			if bytes[word * 8 + bit / 8] & (1 << uint(bit % 8)) == 0 do continue
			if listed == 16 {
				strings.write_string(&text, ", ...}")
				return strings.to_string(text)
			}
			if listed > 0 do strings.write_string(&text, ", ")
			fmt.sbprintf(&text, "%d", word * 64 + bit)
			listed += 1
		}
	}
	strings.write_byte(&text, '}')
	return strings.to_string(text)
}
