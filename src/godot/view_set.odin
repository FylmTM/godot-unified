package godot

// Whether a set's view is in the sim or lingering after its key left it.
Phase :: enum u8 {
	Alive,
	Lingering, // gone from the sim; kept for `linger_s` (death animation, or a rollback that brings it back)
}

// One key's view in a View_Set, and when it was last seen or started lingering.
Entry :: struct($V: typeid) {
	view:     V,
	phase:    Phase,
	seen:     u64, // set_begin counter when last seen
	gone_at:  f64, // when it started lingering (seconds, the caller's clock)
	linger_s: f64, // how long it lingers once gone (set by the caller when it spawns; 0: removed at once)
}

// The views of one frame's entities, keyed by spawn key (`K`: a deterministic spawn key from the sim, so a view survives rollbacks that re-create its entity under the same key and a re-used slot gets a new view; the host keys views by kind and key). Per
// render frame:
//   set_begin; for each entity in the frame: set_see (spawned = create the view, set its linger_s); set_end ->
//   despawned and removed lists (start the exit animation / destroy the view).
View_Set :: struct($K, $V: typeid) {
	entries:   map[K]Entry(V),
	frame:     u64,
	despawned: [dynamic]K, // this frame: started lingering
	removed:   [dynamic]V, // this frame: lingered out; the caller destroys these
}

// Frees the set's map and lists; the views still in it are the caller's to free first.
set_destroy :: proc(view_set: ^View_Set($K, $V)) {
	delete(view_set.entries)
	delete(view_set.despawned)
	delete(view_set.removed)
}

// Starts a frame: advances the frame counter set_see stamps and clears the previous frame's despawned and removed
// lists.
set_begin :: proc(view_set: ^View_Set($K, $V)) {
	view_set.frame += 1
	clear(&view_set.despawned)
	clear(&view_set.removed)
}

// Marks `key` present this frame (one map lookup). `spawned`: the key is new (fill entry.view now). `revived`: it was
// lingering and shows up again (phase back to Alive).
set_see :: proc(view_set: ^View_Set($K, $V), key: K) -> (entry: ^Entry(V), spawned: bool, revived: bool) {
	_, entry, spawned, _ = map_entry(&view_set.entries, key)
	if spawned do entry^ = {}
	revived = entry.phase == .Lingering
	entry.seen = view_set.frame
	entry.phase = .Alive
	return
}

// Keys not seen this frame start lingering (listed in `despawned`); lingerers older than their entry's `linger_s`
// are removed (their views listed in `removed`). linger_s = 0 removes at once (still listed in `despawned`).
set_end :: proc(view_set: ^View_Set($K, $V), now_s: f64) {
	for key, &entry in view_set.entries {
		if entry.seen == view_set.frame do continue
		if entry.phase == .Alive {
			entry.phase = .Lingering
			entry.gone_at = now_s
			append(&view_set.despawned, key)
		}
	}
	for key, entry in view_set.entries {
		if entry.phase == .Lingering && now_s - entry.gone_at >= entry.linger_s {
			append(&view_set.removed, entry.view)
			delete_key(&view_set.entries, key)
		}
	}
}

// The entry of `key` (alive or lingering) without marking it seen, or nil: for routing an event or a signal to
// the view of a key.
set_get :: proc(view_set: ^View_Set($K, $V), key: K) -> ^Entry(V) {
	return &view_set.entries[key] or_else nil
}

// Removes `key` at once, without lingering (e.g. a spawn a rollback cancelled), and hands back its view.
set_remove :: proc(view_set: ^View_Set($K, $V), key: K) -> (view: V, ok: bool) {
	entry := view_set.entries[key] or_return
	delete_key(&view_set.entries, key)
	return entry.view, true
}
