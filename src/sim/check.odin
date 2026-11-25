// The block check (block_violation): whether a State's bytes are a state the library's own code can hold, checked
// where bytes come from outside the running sim (a snapshot from another machine or a file) before anything indexes
// by them (src/sim/README.md, Bytes from another machine).
package sim

import "base:builtin"
import "base:runtime"
import "core:fmt"
import "core:strings"

// Why a State's bytes can't be a state of this game ("" when they can; temp-allocated), naming the field: a Table
// whose counts, free list or live slots disagree (Table's invariants), a Players whose slots and members don't name
// each other, a List or Queue past its capacity, a Bits index past its size, a bool other than 0 or 1, a bit_set bit
// of no element, an enum neither one of its declared values nor 0 (a State's enum need not declare 0, and dead
// items are zeroed). Every state the sim computes passes. What it does not check: floats (a NaN can't make library
// code index out of bounds: find_nan is the sync-test's) and the game's own fields' ranges (an index the game keeps
// in its State is the game's to check before use). from_snapshot refuses a block that fails it (Block_Rejected); the
// standard rollback scenario runs it after every restore. Walks the State's type info once per call, then its bytes.
block_violation :: proc(state: ^$State) -> string {
	return block_check(rawptr(state), type_info_of(State))
}

// block_violation for a type known at run time.
@(private)
block_check :: proc(data: rawptr, type: ^runtime.Type_Info) -> string {
	nodes := make([dynamic]Block_Node, context.temp_allocator)
	block_compile(&nodes, type, 0)
	offset, failed, reason := block_run(nodes[:], uintptr(data))
	if reason == "" do return ""
	path := block_path(type, offset, failed)
	return fmt.tprintf("%s: %s", path if path != "" else "the State", reason)
}

// The path of the value of type `target` at `offset` in a value of `type`, named as the desync report names fields
// (field_path): "things", "players.data[1].trail", a Table's, List's or Queue's items by their index.
@(private)
block_path :: proc(type: ^runtime.Type_Info, offset: int, target: ^runtime.Type_Info, path := "") -> string {
	if offset == 0 && type == target do return path
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Struct:
		_, is_table := table_fields_of(type)
		collection := is_table || collection_kind(type) == .List || collection_kind(type) == .Queue
		for i in 0 ..< int(info.field_count) {
			start := int(info.offsets[i])
			if offset < start || offset >= start + info.types[i].size do continue
			name := info.names[i] if path == "" else fmt.tprintf("%s.%s", path, info.names[i])
			if collection && info.names[i] == "items" do name = path
			return block_path(info.types[i], offset - start, target, name)
		}
	case runtime.Type_Info_Array:
		k := offset / info.elem_size
		return block_path(info.elem, offset - k * info.elem_size, target, fmt.tprintf("%s[%d]", path, k))
	case runtime.Type_Info_Enumerated_Array:
		k := offset / info.elem_size
		return block_path(info.elem, offset - k * info.elem_size, target, fmt.tprintf("%s[%d]", path, k))
	}
	return path
}

// What a Block_Node checks.
@(private)
Block_Kind :: enum u8 {
	Bool, // 0 or 1, its other bytes 0
	Enum, // a declared value, or 0
	Bit_Set, // no bit outside `allowed`
	Bits, // a sim.Bits: no index at or past `capacity`
	Count, // a sim.List's or Queue's count (and head) within its capacity
	Table, // a sim.Table's bookkeeping (table_violation)
	Players, // a sim.Players' slots and members (players_violation)
	Array, // `count` elements of `stride` bytes, each checked by the `children` nodes after this one
}

// One check of a compiled block check, at `offset` in the value its frame is (the block, or an array's element).
@(private)
Block_Node :: struct {
	kind:       Block_Kind,
	type:       ^runtime.Type_Info, // the checked value's (block_path names it)
	offset:     int,
	size:       int, // the checked value's bytes
	enumerated: Wire_Enum, // .Enum (its offset unused)
	allowed:    u128, // .Bit_Set: the bits a value may set
	capacity:   int, // .Bits: N
	words:      int, // .Bits: the words' offset in the Bits
	counted:    Wire_Count, // .Count: offsets in the collection
	table:      Table_Fields, // .Table
	players:    Players_Fields, // .Players
	count:      int, // .Array: elements
	stride:     int, // .Array: element size
	children:   int, // .Array: the nodes of its element's checks, right after it
}

// Where a sim.Table's bookkeeping is, as offsets in the Table.
@(private)
Table_Fields :: struct {
	slots, free_head, high_water, count, capacity: int,
}

// Where a sim.Players' slots and members are, as offsets in the Players, and how many of each.
@(private)
Players_Fields :: struct {
	members, slots, member_count, slot_count: int,
}

// Appends the nodes that check a value of `type` at `offset` in the current frame; nothing for a type with nothing to
// check (integers, floats).
@(private)
block_compile :: proc(nodes: ^[dynamic]Block_Node, type: ^runtime.Type_Info, offset: int) {
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Boolean:
		builtin.append(nodes, Block_Node{kind = .Bool, offset = offset, type = type, size = type.size})
	case runtime.Type_Info_Enum:
		builtin.append(
			nodes,
			Block_Node {
				kind = .Enum,
				offset = offset,
				type = type,
				size = type.size,
				enumerated = wire_enum_of(info, 0),
			},
		)
	case runtime.Type_Info_Bit_Set:
		allowed: u128
		for i in 0 ..< type.size * 8 {
			if bit_set_holds(info, info.lower + i64(i)) do allowed |= u128(1) << uint(i)
		}
		if type.size < 16 && allowed == u128(1) << uint(type.size * 8) - 1 do return
		builtin.append(
			nodes,
			Block_Node{kind = .Bit_Set, offset = offset, type = type, size = type.size, allowed = allowed},
		)
	case runtime.Type_Info_Array:
		array_compile(nodes, info.elem, offset, info.count, info.elem_size)
	case runtime.Type_Info_Enumerated_Array:
		array_compile(nodes, info.elem, offset, info.count, info.elem_size)
	case runtime.Type_Info_Struct:
		switch collection_kind(type) {
		case .Bits:
			capacity := bits_capacity(type)
			if capacity < info.types[0].size * 8 {
				node := Block_Node {
					kind     = .Bits,
					offset   = offset,
					type     = type,
					size     = info.types[0].size,
					capacity = capacity,
					words    = int(info.offsets[0]),
				}
				builtin.append(nodes, node)
			}
		case .List, .Queue:
			builtin.append(
				nodes,
				Block_Node{kind = .Count, offset = offset, type = type, counted = wire_count_of(type, 0)},
			)
		case .None:
			if fields, is_table := table_fields_of(type); is_table {
				builtin.append(nodes, Block_Node{kind = .Table, offset = offset, type = type, table = fields})
			} else if fields, is_players := players_fields_of(type); is_players {
				builtin.append(nodes, Block_Node{kind = .Players, offset = offset, type = type, players = fields})
			}
		}
		for i in 0 ..< int(info.field_count) do block_compile(nodes, info.types[i], offset + int(info.offsets[i]))
	}
}

// block_compile of an array: an Array node over the element's checks, or nothing when the element has none.
@(private)
array_compile :: proc(nodes: ^[dynamic]Block_Node, elem: ^runtime.Type_Info, offset, count, stride: int) {
	at := len(nodes)
	builtin.append(nodes, Block_Node{kind = .Array, offset = offset, count = count, stride = stride})
	block_compile(nodes, elem, 0)
	children := len(nodes) - at - 1
	if children == 0 || count == 0 {
		builtin.resize(nodes, at)
		return
	}
	nodes[at].children = children
}

// A sim.Table's bookkeeping offsets (by RTTI: sim's `Table(` type); ok false for any other type.
@(private)
table_fields_of :: proc(type: ^runtime.Type_Info) -> (fields: Table_Fields, ok: bool) {
	named, is_named := type.variant.(runtime.Type_Info_Named)
	if !is_named || named.pkg != "sim" || !strings.has_prefix(named.name, "Table(") do return
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	for i in 0 ..< int(info.field_count) {
		at := int(info.offsets[i])
		switch info.names[i] {
		case "slots":
			fields.slots = at
			fields.capacity = runtime.type_info_base(info.types[i]).variant.(runtime.Type_Info_Array).count
		case "free_head":
			fields.free_head = at
		case "high_water":
			fields.high_water = at
		case "count":
			fields.count = at
		}
	}
	return fields, true
}

// A sim.Players' offsets (by RTTI: sim's `Players(` type); ok false for any other type.
@(private)
players_fields_of :: proc(type: ^runtime.Type_Info) -> (fields: Players_Fields, ok: bool) {
	named, is_named := type.variant.(runtime.Type_Info_Named)
	if !is_named || named.pkg != "sim" || !strings.has_prefix(named.name, "Players(") do return
	info := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
	for i in 0 ..< int(info.field_count) {
		count := runtime.type_info_base(info.types[i]).variant.(runtime.Type_Info_Array) or_continue
		switch info.names[i] {
		case "members":
			fields.members, fields.member_count = int(info.offsets[i]), count.count
		case "slots":
			fields.slots, fields.slot_count = int(info.offsets[i]), count.count
		}
	}
	return fields, true
}

// Runs compiled checks over the frame at `data`: the offset in the frame of the first value that fails, its type, and
// why.
@(private)
block_run :: proc(nodes: []Block_Node, data: uintptr) -> (offset: int, type: ^runtime.Type_Info, reason: string) {
	for i := 0; i < len(nodes); i += 1 {
		node := &nodes[i]
		at := data + uintptr(node.offset)
		switch node.kind {
		case .Bool:
			bytes := ([^]u8)(rawptr(at))[:node.size]
			for b, k in bytes {
				if b > 1 || (k > 0 && b != 0) do return node.offset, node.type, fmt.tprintf("a bool whose byte %d is %d", k, b)
			}
		case .Enum:
			value := read_integer(rawptr(at), node.enumerated.base)
			field := &node.enumerated
			declared := value >= field.low && value <= field.high if field.dense else enum_declares(field.info, value)
			if value != 0 && !declared do return node.offset, node.type, fmt.tprintf("%d is no value of its enum", value)
		case .Bit_Set:
			value: u128
			bytes := ([^]u8)(rawptr(at))[:node.size]
			for b, k in bytes do value |= u128(b) << uint(8 * k)
			if value &~ node.allowed != 0 do return node.offset, node.type, "a bit_set holds a bit of no element"
		case .Bits:
			words := ([^]u8)(rawptr(at + uintptr(node.words)))
			for bit in node.capacity ..< node.size * 8 {
				if words[bit / 8] & (1 << uint(bit % 8)) != 0 {
					return node.offset, node.type, fmt.tprintf("a Bits(%d) holds %d", node.capacity, bit)
				}
			}
		case .Count:
			if !wire_count_holds(node.counted, rawptr(at)) {
				return node.offset, node.type, fmt.tprintf("its count or head is past its capacity %d", node.counted.capacity)
			}
		case .Table:
			if why := table_violation(node.table, at); why != "" do return node.offset, node.type, why
		case .Players:
			if why := players_violation(node.players, at); why != "" do return node.offset, node.type, why
		case .Array:
			children := nodes[i + 1:][:node.children]
			for k in 0 ..< node.count {
				element := node.offset + k * node.stride
				if inner, failed, why := block_run(children, data + uintptr(element)); why != "" {
					return element + inner, failed, why
				}
			}
			i += node.children
		}
	}
	return
}

// Why a sim.Table's bookkeeping can't be (""; it can): 0 <= count <= high_water <= N; below high_water the live
// slots number count and every other slot is on the free list, which starts at free_head, stays below high_water
// and ends after exactly high_water - count slots (so it has no cycle); at and past high_water every slot is free and
// unlinked.
@(private)
table_violation :: proc(fields: Table_Fields, at: uintptr) -> string {
	read :: #force_inline proc(at: uintptr, offset: int) -> i32 {return (^i32)(at + uintptr(offset))^}
	slots := ([^]Slot)(rawptr(at + uintptr(fields.slots)))[:fields.capacity]
	free_head, high_water, count := read(at, fields.free_head), read(at, fields.high_water), read(at, fields.count)
	if high_water < 0 || int(high_water) > fields.capacity || count < 0 || count > high_water {
		return fmt.tprintf("a Table of %d with high_water %d and count %d", fields.capacity, high_water, count)
	}
	if free_head < 0 || free_head > high_water {
		return fmt.tprintf("a Table's free_head %d is past its high_water %d", free_head, high_water)
	}
	alive: i32
	for slot, index in slots {
		switch {
		case slot_alive(slot) && index >= int(high_water):
			return fmt.tprintf("a Table's slot %d is alive at or past its high_water %d", index, high_water)
		case slot_alive(slot):
			alive += 1
		case index >= int(high_water) && slot.next_free != 0:
			return fmt.tprintf(
				"a Table's slot %d at or past its high_water %d links %d",
				index,
				high_water,
				slot.next_free,
			)
		}
	}
	if alive != count do return fmt.tprintf("a Table holds %d live slots and counts %d", alive, count)
	link := free_head
	for _ in 0 ..< high_water - count {
		if link <= 0 || link > high_water || slot_alive(slots[link - 1]) {
			return fmt.tprintf(
				"a Table's free list reaches %d, no free slot below its high_water %d",
				link,
				high_water,
			)
		}
		link = slots[link - 1].next_free
	}
	if link != 0 do return "a Table's free list is longer than its free slots"
	return ""
}

// Why a sim.Players can't be (""; it can): each slot holds nobody or a member with that id whose slot is it; each
// member with an id is absent (NO_SLOT) or in a slot below PLAYERS that names it back; no two members share an id.
@(private)
players_violation :: proc(fields: Players_Fields, at: uintptr) -> string {
	members := ([^]Member)(rawptr(at + uintptr(fields.members)))[:fields.member_count]
	slots := ([^]Player)(rawptr(at + uintptr(fields.slots)))[:fields.slot_count]
	for holder, slot in slots {
		if holder == {} do continue
		if int(holder.index) >= len(members) ||
		   holder.id == 0 ||
		   members[holder.index].id != holder.id ||
		   int(members[holder.index].slot) != slot {
			return fmt.tprintf(
				"Players slot %d names member %d (id %d), who is not in it",
				slot,
				holder.index,
				holder.id,
			)
		}
	}
	for member, index in members {
		if member.id == 0 do continue
		if member.slot != NO_SLOT &&
		   (int(member.slot) >= len(slots) || slots[member.slot] != Player{u16(index), member.id}) {
			return fmt.tprintf(
				"Players member %d (id %d) is in slot %d, which names someone else",
				index,
				member.id,
				member.slot,
			)
		}
		for other in members[:index] {
			if other.id == member.id do return fmt.tprintf("two Players members have the id %d", member.id)
		}
	}
	return ""
}
