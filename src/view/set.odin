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

set_destroy :: proc(s: ^View_Set($V)) {
	delete(s.entries)
	delete(s.despawned)
	delete(s.removed)
}

set_begin :: proc(s: ^View_Set($V)) {
	s.frame += 1
	clear(&s.despawned)
	clear(&s.removed)
}

// Marks `key` present this frame. `spawned`: the key is new (fill e.view now). A lingering key that shows up
// again is revived (spawned = false, phase back to Alive).
set_see :: proc(s: ^View_Set($V), key: Key) -> (e: ^Entry(V), spawned: bool) {
	_, e, spawned, _ = map_entry(&s.entries, key)
	if spawned do e^ = {}
	e.seen = s.frame
	e.phase = .Alive
	return
}

// Keys not seen this frame start lingering (listed in `despawned`); lingerers older than `linger_s` are
// removed (their views listed in `removed`). linger_s = 0 removes at once.
set_end :: proc(s: ^View_Set($V), now_s: f64, linger_s: f64) {
	for key, &e in s.entries {
		if e.seen == s.frame do continue
		if e.phase == .Alive {
			e.phase = .Lingering
			e.gone_at = now_s
			append(&s.despawned, key)
		}
	}
	for key, e in s.entries {
		if e.phase == .Lingering && now_s - e.gone_at >= linger_s {
			append(&s.removed, e.view)
			delete_key(&s.entries, key)
		}
	}
}

set_get :: proc(s: ^View_Set($V), key: Key) -> ^Entry(V) {
	return &s.entries[key] or_else nil
}

// ---- pool of reusable views (scene instances, buffers...)

Pool :: struct($V: typeid) {
	free: [dynamic]V,
}

pool_get :: proc(p: ^Pool($V)) -> (v: V, ok: bool) {
	return pop_safe(&p.free)
}

pool_put :: proc(p: ^Pool($V), v: V) {
	append(&p.free, v)
}

pool_destroy :: proc(p: ^Pool($V)) {
	delete(p.free)
}
