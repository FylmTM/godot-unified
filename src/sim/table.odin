// Fixed-capacity entity tables with generational handles (src/sim/README.md, Tables and handles): the game
// owns typed tables inside its State; tooling reads them like the rest of the block, by RTTI.
package sim

// Per-slot bookkeeping, kept apart from the items so `items` holds only game data. A zeroed slot is free and was never
// used, so a zeroed table is empty.
Slot :: struct {
	next_free:  i32, // SLOT_ALIVE while its item is live; else the free list link: index + 1 of the next free slot (0: end)
	generation: u32, // bumped on every spawn; 0 is never live, so Handle{} is the null handle
}

// Slot.next_free of a slot that holds a live item (slot_alive).
SLOT_ALIVE :: -1

// Whether a table slot holds a live item: how tooling that reads a Table by RTTI (the JSON, the diff) tells its live
// items from its free slots.
slot_alive :: #force_inline proc(slot: Slot) -> bool {
	return slot.next_free == SLOT_ALIVE
}

// A reference kept across ticks (in the block, in an event, by a view). Typed: a Handle(Enemy) can't
// be passed where a Handle(Projectile) is expected. A slot reused every tick wraps its generation after
// 2^32 reuses (~2 years at 64 Hz).
Handle :: struct($T: typeid) {
	index:      u32,
	generation: u32, // 0: the null handle
}

// Indices are stable (no swap-remove); freed slots are reused LIFO and zeroed (equal states hash equal).
// The zero value is an empty table (no init call needed). Padding-free for any T of alignment up to 8 (a 16-aligned
// T, a u128, does not compile), as the state block requires: the pads are computed from T and N.
Table :: struct($T: typeid, $N: int) where N > 0 && N <= 1 << 30 && align_of(T) <= 8 {
	items:      [N]T,
	_pad_items: [(4 - N * size_of(T) % 4) % 4]u8, // keeps `slots` 4-aligned
	slots:      [N]Slot,
	free_head:  i32, // index + 1 of the first free slot below high_water (0: none)
	high_water: i32, // one past the highest slot used since the table was last empty by despawn_all or zeroing
	count:      i32,
	_pad:       i32, // keeps the size a multiple of 8
}

// Allocates a zeroed item. ok = false when the table is full.
spawn :: proc(table: ^Table($T, $N)) -> (item: ^T, handle: Handle(T), ok: bool) {
	index: i32
	if table.free_head > 0 {
		index = table.free_head - 1
		table.free_head = table.slots[index].next_free
	} else if table.high_water < i32(N) {
		index = table.high_water
		table.high_water += 1
	} else {
		return
	}
	slot := &table.slots[index] // (generation: kept by despawn and despawn_all)
	slot.generation += 1
	if slot.generation == 0 {
		slot.generation = 1
	}
	slot.next_free = SLOT_ALIVE
	table.count += 1
	return &table.items[index], {u32(index), slot.generation}, true
}

// Frees the item `handle` refers to and zeroes it, so equal states hash equal; false for a stale or null handle.
despawn :: proc(table: ^Table($T, $N), handle: Handle(T)) -> bool {
	if get(table, handle) == nil {
		return false
	}
	index := int(handle.index)
	slot := &table.slots[index]
	table.items[index] = {}
	slot.next_free = table.free_head
	table.free_head = i32(index) + 1
	table.count -= 1
	return true
}

// Despawns every live item, keeping each slot's generation: the next spawns start again from slot 0, and a handle
// (or handle_key) from before the clear never names a new item. What a reset does to a table: zeroing the table
// instead resets the generations, so handles and keys repeat.
despawn_all :: proc(table: ^Table($T, $N)) {
	for &slot, index in table.slots[:table.high_water] {
		if slot_alive(slot) do table.items[index] = {}
		slot.next_free = 0
	}
	table.free_head = 0
	table.high_water = 0
	table.count = 0
}

// The item `handle` refers to, or nil for the null handle, an out-of-range index or a stale handle.
get :: proc(table: ^Table($T, $N), handle: Handle(T)) -> ^T {
	if u64(handle.index) >= u64(N) || handle.generation == 0 {
		return nil
	}
	slot := &table.slots[handle.index]
	return &table.items[handle.index] if slot_alive(slot^) && slot.generation == handle.generation else nil
}

// The live item at table index `index` and its handle; ok is false for a free slot or an index out of range. For an
// index structure the tick builds in scratch (items bucketed by cell, a chain of hits), which holds indices rather
// than handles: despawn the item through the handle. Across ticks hold the handle, never the index.
item_at :: proc(table: ^Table($T, $N), index: int) -> (item: ^T, handle: Handle(T), ok: bool) {
	if index < 0 || index >= N || !slot_alive(table.slots[index]) {
		return
	}
	return &table.items[index], {u32(index), table.slots[index].generation}, true
}


// A u64 key unique among the live and past items of one table (generation << 32 | index): what views
// key an entity by, matching it across predicted and verified frames.
handle_key :: proc(handle: Handle($T)) -> u64 {
	return u64(handle.generation) << 32 | u64(handle.index)
}

// The handle a key names (handle_key's inverse; a physics tag, a view key): `sim.handle_of_key(Coin, hit.tag)`. A
// key of no live item gives a handle that `get` answers nil for.
handle_of_key :: proc($T: typeid, key: u64) -> Handle(T) {
	return {index = u32(key & 0xFFFF_FFFF), generation = u32(key >> 32)}
}


// Walks a table's live items in index order (iterate, then next):
//
//   coins := sim.iterate(&tick.state.coins)
//   for coin, handle in sim.next(&coins) { ... }
//
// Despawning the current item is safe. The walk covers the slots in use when it started: an item spawned during it
// is visited only when it reuses a free slot ahead of the walk, never when it takes a fresh one.
Table_Iterator :: struct($T: typeid, $N: int) {
	table: ^Table(T, N),
	index: i32, // the next slot to look at
	end:   i32, // the high-water mark when the walk started
}

// Starts a walk: over a table's live items in index order (`next` yields each with its handle), or a bit set's
// indices, lowest first (collections.odin).
iterate :: proc {
	iterate_table,
	iterate_bits,
}

// iterate's table form.
iterate_table :: #force_inline proc(table: ^Table($T, $N)) -> Table_Iterator(T, N) {
	return {table = table, end = table.high_water}
}

// The next live item of a table walk and its handle; ok is false once past the slots in use when it started.
table_next :: #force_inline proc(iterator: ^Table_Iterator($T, $N)) -> (item: ^T, handle: Handle(T), ok: bool) {
	table := iterator.table
	for index := iterator.index; index < iterator.end; index += 1 {
		slot := &table.slots[index]
		if slot_alive(slot^) {
			iterator.index = index + 1
			return &table.items[index], {u32(index), slot.generation}, true
		}
	}
	iterator.index = iterator.end
	return
}

// The next item of a table walk (iterate), a player walk (iterate_present, iterate_known: players.odin), a bit-set
// walk (iterate) or a grid's rows (grid_box: grid.odin).
next :: proc {
	table_next,
	players_next,
	bits_next,
	grid_box_next,
}
