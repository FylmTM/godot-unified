// Typed desync reports (src/netcode/SPEC.md, Desyncs): what differs between two snapshots of the same tick, field by
// field through the State's RTTI (a table's items by index), then the extra's image.
package sim

import "base:runtime"
import "core:fmt"
import "core:strings"

import "unified:wire"

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
		for first < min(len(image_a), len(image_b)) && image_a[first] == image_b[first] {
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

// Notes where two values of `type` differ: each differing leaf field (a struct's fields and an array's elements are
// walked), "path a vs b". A sim.Table reads as its items by index (`enemies[12].pos.x`), with its slots' liveness
// noted apart.
@(private)
diff_value :: proc(diff: ^Diff, path: string, type: ^runtime.Type_Info, a, b: []u8) {
	if string(a) == string(b) {
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
