// Fixed-capacity entity tables with generational handles (src/sim/SPEC.md "Tables and handles"): the game
// owns typed tables inside its State; tooling discovers them by RTTI (schema.odin).
package sim

// Per-slot bookkeeping, kept apart from the items so `items` holds only game data.
Slot :: struct {
	next_free:  i32, // free list link: index + 1 of the next free slot (0: end)
	generation: u32, // bumped on every spawn; 0 is never live, so Handle{} is the null handle
	alive:      bool,
	_pad:       [3]u8,
}

// A reference kept across ticks (in the block, in an event, by a view). Typed: a Handle(Enemy) can't
// be passed where a Handle(Projectile) is expected. A slot reused every tick wraps its generation after
// 2^32 reuses (~2 years at 64 Hz).
Handle :: struct($T: typeid) {
	index:      u32,
	generation: u32, // 0: the null handle
}

// Indices are stable (no swap-remove); freed slots are reused LIFO and zeroed (equal states hash equal).
// The zero value is an empty table (no init call needed).
Table :: struct($T: typeid, $N: int) where N > 0 && N <= 1 << 30 {
	items:      [N]T,
	slots:      [N]Slot,
	free_head:  i32, // index + 1 of the first free slot below high_water (0: none)
	high_water: i32, // one past the highest slot ever used; never goes down
	count:      i32,
	_pad:       i32,
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
	slot := &table.slots[index]
	slot.generation += 1
	if slot.generation == 0 {
		slot.generation = 1
	}
	slot.alive = true
	slot.next_free = 0
	table.count += 1
	return &table.items[index], {u32(index), slot.generation}, true
}

// Frees the item at `index` (it must be alive) and zeroes it, so equal states hash equal.
despawn_index :: proc(table: ^Table($T, $N), index: int) {
	slot := &table.slots[index]
	assert(slot.alive, "despawn of a dead slot")
	table.items[index] = {}
	slot.alive = false
	slot.next_free = table.free_head
	table.free_head = i32(index) + 1
	table.count -= 1
}

// Frees the item `handle` refers to; returns false for a stale or null handle.
despawn_handle :: proc(table: ^Table($T, $N), handle: Handle(T)) -> bool {
	if get(table, handle) == nil {
		return false
	}
	despawn_index(table, int(handle.index))
	return true
}

// Frees an item by slot index or by handle (despawn_index, despawn_handle).
despawn :: proc {
	despawn_index,
	despawn_handle,
}

// The item `handle` refers to, or nil for the null handle, an out-of-range index or a stale handle.
get :: proc(table: ^Table($T, $N), handle: Handle(T)) -> ^T {
	if u64(handle.index) >= u64(N) || handle.generation == 0 {
		return nil
	}
	slot := &table.slots[handle.index]
	return &table.items[handle.index] if slot.alive && slot.generation == handle.generation else nil
}

// Whether the slot at `index` holds a live item.
alive :: #force_inline proc(table: ^Table($T, $N), index: int) -> bool {
	return table.slots[index].alive
}

// Handle of the (alive) item at `index`.
handle :: proc(table: ^Table($T, $N), index: int) -> Handle(T) {
	return {u32(index), table.slots[index].generation}
}

// A u64 key unique among the live and past items of one table (generation << 32 | index): what views
// key an entity by, matching it across predicted and verified frames.
handle_key :: proc(handle: Handle($T)) -> u64 {
	return u64(handle.generation) << 32 | u64(handle.index)
}

// The same item one tick earlier, for views that interpolate: `previous` is the table in the previous
// tick's state (nil when that state is not available); found when the item at `index` is alive in both
// with the same generation (not a reused slot).
prev_item :: proc(previous, current: ^Table($T, $N), index: int) -> (^T, bool) {
	if previous == nil do return nil, false
	before, now := previous.slots[index], current.slots[index]
	if !before.alive || !now.alive || before.generation != now.generation do return nil, false
	return &previous.items[index], true
}

// Walks a table's live items in index order (iterate, then next):
//
//   coins := sim.iterate(&tick.state.coins)
//   for coin, handle in sim.next(&coins) { ... }
//
// Despawning the current item is safe. An item spawned during the walk is visited when its slot is
// still ahead (a fresh slot past the old high_water, or a reused one above the current index).
Table_Iterator :: struct($T: typeid, $N: int) {
	table: ^Table(T, N),
	index: i32, // the next slot to look at
}

// Starts a walk over the table's live items; `next` yields each one with its handle.
iterate :: #force_inline proc(table: ^Table($T, $N)) -> Table_Iterator(T, N) {
	return {table = table}
}

// The next live item of the walk and its handle; ok is false once past the table's high-water mark.
next :: #force_inline proc(iterator: ^Table_Iterator($T, $N)) -> (item: ^T, handle: Handle(T), ok: bool) {
	table := iterator.table
	for iterator.index < table.high_water {
		index := iterator.index
		iterator.index += 1
		slot := &table.slots[index]
		if slot.alive {
			return &table.items[index], {u32(index), slot.generation}, true
		}
	}
	return
}
