// The library's containers are padding-free for any element of alignment up to 8 (sim.Table, sim.Players), and the
// layout hash tells apart what compat must: enum values, bit_set elements, an enumerated array's index enum.
package test_sim

import "core:testing"

import "unified:sim"

// Elements of every size from 1 to 24 bytes, aligned 1, 2, 4 and 8.
Bytes_1 :: [1]u8
Bytes_2 :: [2]u8
Bytes_3 :: [3]u8
Halves_3 :: [3]u16
Words_3 :: [3]u32
Wide_1 :: struct {
	value: u64,
}
Wide_3 :: struct {
	value: u64,
	more:  [2]u64,
}
Wide_Odd :: struct {
	value: u64,
	tag:   u8,
	_pad:  [7]u8,
}

// Whether a Table of T, N is plain data with no padding.
table_is_plain :: proc(t: ^testing.T, $T: typeid, $N: int) {
	testing.expectf(
		t,
		sim.plain_violation(type_info_of(sim.Table(T, N))) == "",
		"Table(%v, %d): %s",
		typeid_of(T),
		N,
		sim.plain_violation(type_info_of(sim.Table(T, N))),
	)
}

// Whether a Players of T, Profile, Input and PLAYERS is plain data with no padding.
players_is_plain :: proc(t: ^testing.T, $T, $Profile, $Input: typeid, $PLAYERS: int) {
	type := type_info_of(sim.Players(T, Profile, Input, PLAYERS))
	testing.expectf(t, sim.plain_violation(type) == "", "%v: %s", type.id, sim.plain_violation(type))
}

// Every element size and alignment, odd and even N: no implicit padding a game would have to fix.
@(test)
a_table_of_any_element_is_padding_free :: proc(t: ^testing.T) {
	table_is_plain(t, Bytes_1, 1)
	table_is_plain(t, Bytes_1, 2)
	table_is_plain(t, Bytes_1, 3)
	table_is_plain(t, Bytes_1, 5)
	table_is_plain(t, Bytes_2, 1)
	table_is_plain(t, Bytes_2, 3)
	table_is_plain(t, Bytes_3, 1)
	table_is_plain(t, Bytes_3, 2)
	table_is_plain(t, Bytes_3, 5)
	table_is_plain(t, Halves_3, 1)
	table_is_plain(t, Halves_3, 3)
	table_is_plain(t, u16, 5)
	table_is_plain(t, Words_3, 1)
	table_is_plain(t, Words_3, 2)
	table_is_plain(t, Words_3, 5)
	table_is_plain(t, Wide_1, 1)
	table_is_plain(t, Wide_1, 2)
	table_is_plain(t, Wide_1, 3)
	table_is_plain(t, Wide_1, 5)
	table_is_plain(t, Wide_3, 1)
	table_is_plain(t, Wide_3, 3)
	table_is_plain(t, Wide_Odd, 1)
	table_is_plain(t, Wide_Odd, 3)
	testing.expect_value(t, size_of(sim.Slot), 8)
}

// Any per-player struct, Profile and Input, odd and even PLAYERS (one player with a single bool included).
@(test)
players_of_any_element_are_padding_free :: proc(t: ^testing.T) {
	Ready :: struct {
		ready: bool,
	}
	Wide_Input :: struct {
		held: u64,
	}
	Byte_Input :: struct {
		held: u8,
	}
	players_is_plain(t, Ready, sim.No_Profile, sim.No_Input, 1)
	players_is_plain(t, Ready, sim.No_Profile, Byte_Input, 3)
	players_is_plain(t, Bytes_1, Bytes_3, Wide_Input, 1)
	players_is_plain(t, Bytes_2, sim.No_Profile, Wide_Input, 1)
	players_is_plain(t, Bytes_2, Bytes_1, Wide_Input, 3)
	players_is_plain(t, Bytes_3, sim.No_Profile, Byte_Input, 2)
	players_is_plain(t, Halves_3, Bytes_2, Wide_Input, 3)
	players_is_plain(t, Words_3, sim.No_Profile, Byte_Input, 5)
	players_is_plain(t, Wide_Odd, Bytes_3, Wide_Input, 3)
}

// A table with an odd capacity and an 8-aligned item works like any other: spawn to full, despawn, reuse, walk.
@(test)
an_odd_table_of_wide_items_spawns_and_walks :: proc(t: ^testing.T) {
	table: sim.Table(Wide_1, 3)
	handles: [3]sim.Handle(Wide_1)
	for &handle, i in handles {
		item, spawned, ok := sim.spawn(&table)
		testing.expect(t, ok)
		item.value = u64(i + 1) << 40
		handle = spawned
	}
	_, _, full := sim.spawn(&table)
	testing.expect(t, !full)
	testing.expect(t, sim.despawn(&table, handles[1]))
	testing.expect(t, sim.get(&table, handles[1]) == nil)
	reused, reused_handle, ok := sim.spawn(&table)
	testing.expect(t, ok && reused_handle.index == 1 && reused_handle.generation == 2 && reused.value == 0)
	reused.value = 7
	sum: u64
	walk := sim.iterate(&table)
	for item in sim.next(&walk) do sum += item.value
	testing.expect_value(t, sum, u64(1) << 40 + 7 + u64(3) << 40)
	testing.expect_value(t, sim.block_violation(&table), "")
	sim.despawn_all(&table)
	empty: sim.Table(Wide_1, 3)
	empty_items := transmute([size_of(empty.items)]u8)empty.items
	table_items := transmute([size_of(table.items)]u8)table.items
	testing.expect(t, table.count == 0 && table.high_water == 0 && table.free_head == 0 && table_items == empty_items)
}

// Two builds of one State that differ only in an enum's values, a bit_set's elements or an enumerated array's index
// enum have different layout hashes, so compat_of tells them apart at hello instead of a desync telling later.
@(test)
the_layout_hash_sees_enum_values_and_bit_set_elements :: proc(t: ^testing.T) {
	testing.expect(t, enum_value_old() != enum_value_new(), "an enum member renumbered")
	testing.expect(t, bit_set_old() != bit_set_new(), "a button added to a bit_set")
	testing.expect(t, bit_set_old() != bit_set_reordered(), "a bit_set's elements reordered")
	testing.expect(t, index_old() != index_reordered(), "an enumerated array's index enum reordered")
	testing.expect_value(t, enum_value_old(), enum_value_same()) // the same declaration in another scope
}

enum_value_old :: proc() -> u64 {
	Mode :: enum u8 {
		Idle,
		Walk = 1,
	}
	State :: struct {
		mode: Mode,
	}
	return sim.layout_hash(State)
}

enum_value_same :: proc() -> u64 {
	Mode :: enum u8 {
		Idle,
		Walk = 1,
	}
	State :: struct {
		mode: Mode,
	}
	return sim.layout_hash(State)
}

enum_value_new :: proc() -> u64 {
	Mode :: enum u8 {
		Idle,
		Walk = 5,
	}
	State :: struct {
		mode: Mode,
	}
	return sim.layout_hash(State)
}

bit_set_old :: proc() -> u64 {
	Button :: enum u8 {
		Jump,
		Fire,
	}
	State :: struct {
		held: bit_set[Button;u8],
	}
	return sim.layout_hash(State)
}

bit_set_new :: proc() -> u64 {
	Button :: enum u8 {
		Jump,
		Fire,
		Dash,
	}
	State :: struct {
		held: bit_set[Button;u8],
	}
	return sim.layout_hash(State)
}

bit_set_reordered :: proc() -> u64 {
	Button :: enum u8 {
		Fire,
		Jump,
	}
	State :: struct {
		held: bit_set[Button;u8],
	}
	return sim.layout_hash(State)
}

index_old :: proc() -> u64 {
	Kind :: enum u8 {
		Rock,
		Paper,
	}
	State :: struct {
		count: [Kind]u32,
	}
	return sim.layout_hash(State)
}

index_reordered :: proc() -> u64 {
	Kind :: enum u8 {
		Paper,
		Rock,
	}
	State :: struct {
		count: [Kind]u32,
	}
	return sim.layout_hash(State)
}
