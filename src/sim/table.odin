// Fixed-capacity entity tables with generational handles (state model (c): the game owns typed
// tables inside its State; tooling discovers them by RTTI, see schema.odin).
package sim

// Per-slot bookkeeping, kept apart from the items so `items` holds only game data.
Slot :: struct {
	next_free:  i32, // free list link: index + 1 of the next free slot (0: end)
	generation: u16, // bumped on every spawn; 0 is never live, so Handle{} is the null handle
	alive:      bool,
	_pad:       u8,
}

// Typed: a Handle(Enemy) can't be passed where a Handle(Projectile) is expected.
Handle :: struct($T: typeid) {
	index:      u16,
	generation: u16, // 0: the null handle
}

// Indices are stable (no swap-remove); freed slots are reused LIFO; iterate over [0, high_water).
// The zero value is an empty table (no init call needed).
Table :: struct($T: typeid, $N: int) where N > 0 && N <= 1 << 16 {
	items:      [N]T,
	slots:      [N]Slot,
	free_head:  i32, // index + 1 of the first free slot below high_water (0: none)
	high_water: i32,
	count:      i32,
	_pad:       i32,
}

// Allocates a zeroed item. ok = false when the table is full.
spawn :: proc(t: ^Table($T, $N)) -> (item: ^T, h: Handle(T), ok: bool) {
	idx: i32
	if t.free_head > 0 {
		idx = t.free_head - 1
		t.free_head = t.slots[idx].next_free
	} else if t.high_water < i32(N) {
		idx = t.high_water
		t.high_water += 1
	} else {
		return
	}
	s := &t.slots[idx]
	s.generation += 1
	if s.generation == 0 {
		s.generation = 1
	}
	s.alive = true
	s.next_free = 0
	t.count += 1
	return &t.items[idx], {u16(idx), s.generation}, true
}

// Frees the item at `idx` (it must be alive) and zeroes it, so equal states hash equal.
despawn_index :: proc(t: ^Table($T, $N), idx: int) {
	s := &t.slots[idx]
	assert(s.alive, "despawn of a dead slot")
	t.items[idx] = {}
	s.alive = false
	s.next_free = t.free_head
	t.free_head = i32(idx) + 1
	t.count -= 1
}

// Frees the item `h` refers to; returns false for a stale or null handle.
despawn_handle :: proc(t: ^Table($T, $N), h: Handle(T)) -> bool {
	if get(t, h) == nil {
		return false
	}
	despawn_index(t, int(h.index))
	return true
}

despawn :: proc {
	despawn_index,
	despawn_handle,
}

// The item `h` refers to, or nil for the null handle, an out-of-range index or a stale handle.
get :: proc(t: ^Table($T, $N), h: Handle(T)) -> ^T {
	if int(h.index) >= N || h.generation == 0 {
		return nil
	}
	s := &t.slots[h.index]
	return &t.items[h.index] if s.alive && s.generation == h.generation else nil
}

// The item at `idx` and whether it is alive:
// `for i in 0 ..< t.high_water { e := sim.at(&t, i) or_continue; ... }`.
at :: #force_inline proc(t: ^Table($T, $N), idx: i32) -> (^T, bool) {
	return &t.items[idx], t.slots[idx].alive
}

alive :: #force_inline proc(t: ^Table($T, $N), idx: i32) -> bool {
	return t.slots[idx].alive
}

// The same item one tick earlier, for views that interpolate: `prev` is the table in the previous tick's state
// (nil when that state is not available); found when the item at `idx` is alive in both with the same
// generation (not a re-used slot). `if p, ok := sim.prev_item(prev != nil ? &prev.shots : nil, &cur.shots, i); ok`.
prev_item :: proc(prev, cur: ^Table($T, $N), idx: i32) -> (^T, bool) {
	if prev == nil do return nil, false
	ps, cs := prev.slots[idx], cur.slots[idx]
	if !ps.alive || !cs.alive || ps.generation != cs.generation do return nil, false
	return &prev.items[idx], true
}

// Handle of the (alive) item at `idx`.
handle :: proc(t: ^Table($T, $N), idx: i32) -> Handle(T) {
	return {u16(idx), t.slots[idx].generation}
}

// A u32 key unique among the live and past items of one table (generation << 16 | index): the
// deterministic spawn key a view uses to match entities across predicted and verified frames.
handle_key :: proc(h: Handle($T)) -> u32 {
	return u32(h.generation) << 16 | u32(h.index)
}
