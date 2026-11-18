// Reused datagram-sized buffers: a queued message, a delayed datagram or an early reliable message takes a
// slot instead of a heap allocation of its own. A pool grows to the most slots it ever held at once, then allocates
// no more, so a session thread's steady state allocates nothing.
package netcode

Slot_Pool :: struct {
	slots: [dynamic][MAX_DATAGRAM]u8,
	free:  [dynamic]i32, // released slots, taken again first
}

// Bytes held in a pool slot.
Pooled :: struct {
	slot: i32,
	size: i32,
}

// Room for `slots` slots before the pool allocates again: a session's usual traffic (a few messages and datagrams
// in flight) never grows it.
pool_reserve :: proc(pool: ^Slot_Pool, slots: int) {
	reserve(&pool.slots, slots)
	reserve(&pool.free, slots)
}

// Copies `bytes` (at most MAX_DATAGRAM) into a free slot.
pool_put :: proc(pool: ^Slot_Pool, bytes: []u8) -> Pooled {
	assert(len(bytes) <= MAX_DATAGRAM)
	slot: i32
	if count := len(pool.free); count > 0 {
		slot = pool.free[count - 1]
		resize(&pool.free, count - 1)
	} else {
		slot = i32(len(pool.slots))
		append_nothing(&pool.slots)
	}
	copy(pool.slots[slot][:], bytes)
	return {slot, i32(len(bytes))}
}

// The bytes of a held slot: valid until the next pool_put (which may move the slots).
pool_bytes :: #force_inline proc(pool: ^Slot_Pool, held: Pooled) -> []u8 {
	return pool.slots[held.slot][:held.size]
}

// Gives a slot back.
pool_release :: proc(pool: ^Slot_Pool, held: Pooled) {
	append(&pool.free, held.slot)
}

pool_destroy :: proc(pool: ^Slot_Pool) {
	delete(pool.slots)
	delete(pool.free)
}
