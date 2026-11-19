// sim's inline collections as GDScript sees them, in every class built from the game's types (events, commands,
// data, constants, input values, the Setup and the Profile): a sim.List or sim.Queue as an Array of its live items (a
// Queue's oldest first), typed by the item, and a sim.Bits as an Array of the indices it holds. A settable one (a
// Setup, a Profile, input values, a nested value, a command) takes such an Array back: at most the collection's
// capacity, each item as its field would be.
#+private
package godot

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"

Collection_Kind :: enum u8 {
	List,
	Queue,
	Bits,
}

// Where a collection's parts are in its bytes.
Collection :: struct {
	kind:       Collection_Kind,
	elem:       ^runtime.Type_Info, // an item's type (a Bits: its indices, ints)
	elem_size:  int,
	capacity:   int, // N
	items_at:   int, // the items (a Bits: its words)
	count_at:   int,
	count_size: int,
	head_at:    int, // a Queue's oldest item's place (-1: a List's, none)
}

// The collection a type is (ok false: not one of sim's): by its name, as is_handle finds a handle.
collection_of :: proc(type: ^runtime.Type_Info) -> (collection: Collection, ok: bool) {
	named, is_named := type.variant.(runtime.Type_Info_Named)
	if !is_named || named.pkg != "sim" do return
	switch {
	case strings.has_prefix(named.name, "List("):
		collection.kind = .List
	case strings.has_prefix(named.name, "Queue("):
		collection.kind = .Queue
	case strings.has_prefix(named.name, "Bits("):
		collection.kind = .Bits
	case:
		return
	}
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	collection.head_at = -1
	for i in 0 ..< int(info.field_count) {
		switch info.names[i] {
		case "count":
			collection.count_at, collection.count_size = int(info.offsets[i]), info.types[i].size
		case "head":
			collection.head_at = int(info.offsets[i])
		case "items", "words":
			collection.items_at = int(info.offsets[i])
			array := runtime.type_info_base(info.types[i]).variant.(runtime.Type_Info_Array)
			collection.elem, collection.elem_size, collection.capacity = array.elem, array.elem_size, array.count
		}
	}
	if collection.kind == .Bits {
		// N is the number its name ends in (the words round it up to 64)
		close := strings.last_index_byte(named.name, ')')
		start := close
		for start > 0 && named.name[start - 1] >= '0' && named.name[start - 1] <= '9' do start -= 1
		collection.capacity, _ = strconv.parse_int(named.name[start:close], 10)
		collection.elem = type_info_of(i64)
	}
	assert(collection.elem != nil, "a sim collection without its items")
	return collection, true
}

// A collection's live items (a Bits' indices) as a typed Array.
collection_variant :: proc(type: ^runtime.Type_Info, collection: Collection, bytes: []u8, units: Units) -> gd.Variant {
	array := typed_array(type)
	if collection.kind == .Bits {
		// word by word, each set bit by its trailing zeros (as sim.bits_next walks)
		for word_at := 0; word_at * 64 < collection.capacity; word_at += 1 {
			word := u64(read_uint(bytes[collection.items_at + word_at * 8:][:8]))
			for word != 0 {
				bit := word_at * 64 + int(intrinsics.count_trailing_zeros(word))
				if bit < collection.capacity do gd.array_push(&array, i64(bit))
				word &= word - 1
			}
		}
		return array_variant(&array)
	}
	count := min(int(read_uint(bytes[collection.count_at:][:collection.count_size])), collection.capacity)
	head := 0
	if collection.head_at >= 0 {
		head = int(read_uint(bytes[collection.head_at:][:collection.count_size])) % collection.capacity
	}
	for k in 0 ..< count {
		place := collection.items_at + (head + k) % collection.capacity * collection.elem_size
		element := field_variant(collection.elem, bytes[place:][:collection.elem.size], units)
		gd.Array_push_back(&array, element)
		gdi.variant_destroy(&element)
	}
	return array_variant(&array)
}

// A collection from an Array a script set: its items in order (a Queue's head 0), each written as its field would be;
// a Bits from the indices. More than the capacity, or an item that does not fit, is refused ("" when it fits).
collection_write :: proc(collection: Collection, out: []u8, variant: ^gd.Variant) -> string {
	if gd.variant_type(variant) != .ARRAY do return fmt.tprintf("want an Array, got %v", gd.variant_type(variant))
	array, _ := gd.from_variant(gd.Array, variant)
	defer gd.Array_destroy(&array)
	count := gd.array_len(&array)
	written := make([]u8, len(out), context.temp_allocator)
	if collection.kind == .Bits {
		for i in 0 ..< count {
			item := gd.array_at(&array, i)
			if gd.variant_type(item) != .INT do return fmt.tprintf("item %d: want an int, got %v", i, gd.variant_type(item))
			index, _ := gd.from_variant(i64, item)
			if index < 0 || index >= i64(collection.capacity) do return fmt.tprintf("item %d: %d is not below %d", i, index, collection.capacity)
			written[collection.items_at + int(index) / 8] |= 1 << uint(index % 8)
		}
		copy(out, written)
		return ""
	}
	if count > collection.capacity do return fmt.tprintf("%d items: it holds at most %d", count, collection.capacity)
	for i in 0 ..< count {
		place := written[collection.items_at + i * collection.elem_size:][:collection.elem.size]
		if problem := write_value(collection.elem, place, gd.array_at(&array, i)); problem != "" {
			return fmt.tprintf("item %d: %s", i, problem)
		}
	}
	put_int(written[collection.count_at:][:collection.count_size], i64(count))
	copy(out, written)
	return ""
}
