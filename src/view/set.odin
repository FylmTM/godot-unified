package view

// A deterministic spawn key from the sim (the game defines the encoding, e.g. kind, spawn tick and slot), so
// a view survives rollbacks that re-create its entity under the same key, and a re-used slot gets a new view.
Key :: distinct u64

Phase :: enum u8 {
	Alive,
	Lingering, // gone from the sim; kept for `linger_s` (death animation, or a rollback that brings it back)
}

Entry :: struct($V: typeid) {
	view:    V,
	phase:   Phase,
	seen:    u64, // set_begin counter when last seen
	gone_at: f64, // when it started lingering (seconds, the caller's clock)
	data:    u64, // free for the caller (e.g. the kind)
}

// The views of one frame's entities, keyed by spawn key. Per render frame:
//   set_begin; for each entity in the frame: set_see (spawned = create the view); set_end -> despawned and
//   removed lists (start the exit animation / destroy or pool the view).
View_Set :: struct($V: typeid) {
	entries:   map[Key]Entry(V),
	frame:     u64,
	despawned: [dynamic]Key, // this frame: started lingering
	removed:   [dynamic]V, // this frame: lingered out; the caller destroys or pools these
}

set_destroy :: proc(view_set: ^View_Set($V)) {
	delete(view_set.entries)
	delete(view_set.despawned)
	delete(view_set.removed)
}

set_begin :: proc(view_set: ^View_Set($V)) {
	view_set.frame += 1
	clear(&view_set.despawned)
	clear(&view_set.removed)
}

// Marks `key` present this frame. `spawned`: the key is new (fill entry.view now). A lingering key that shows up
// again is revived (spawned = false, phase back to Alive).
set_see :: proc(view_set: ^View_Set($V), key: Key) -> (entry: ^Entry(V), spawned: bool) {
	_, entry, spawned, _ = map_entry(&view_set.entries, key)
	if spawned do entry^ = {}
	entry.seen = view_set.frame
	entry.phase = .Alive
	return
}

// Keys not seen this frame start lingering (listed in `despawned`); lingerers older than `linger_s` are
// removed (their views listed in `removed`). linger_s = 0 removes at once.
set_end :: proc(view_set: ^View_Set($V), now_s: f64, linger_s: f64) {
	for key, &entry in view_set.entries {
		if entry.seen == view_set.frame do continue
		if entry.phase == .Alive {
			entry.phase = .Lingering
			entry.gone_at = now_s
			append(&view_set.despawned, key)
		}
	}
	for key, entry in view_set.entries {
		if entry.phase == .Lingering && now_s - entry.gone_at >= linger_s {
			append(&view_set.removed, entry.view)
			delete_key(&view_set.entries, key)
		}
	}
}

set_get :: proc(view_set: ^View_Set($V), key: Key) -> ^Entry(V) {
	return &view_set.entries[key] or_else nil
}

// ---- pool of reusable views (scene instances, buffers...)

Pool :: struct($V: typeid) {
	free: [dynamic]V,
}

pool_get :: proc(pool: ^Pool($V)) -> (view: V, ok: bool) {
	return pop_safe(&pool.free)
}

pool_put :: proc(pool: ^Pool($V), view: V) {
	append(&pool.free, view)
}

pool_destroy :: proc(pool: ^Pool($V)) {
	delete(pool.free)
}
