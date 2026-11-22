package godot

import "base:runtime"

// A sim event's lifecycle on the view side. Events (an explosion, a death) are produced by every simulation of a
// tick: predicted, re-simulated after a rollback, verified. The tracker turns that into exactly two steps per
// event: **Emitted** once, the first time any simulation of its tick produces it; then once either **Confirmed**
// (its tick is verified) or **Cancelled** (a re-simulation no longer produces it). An event first produced when
// its tick is verified is Emitted and Confirmed together. The tracker runs on the sim thread and outputs actions
// for the render thread:
//
//   tracker_begin_tick(t, T); for each event of tick T, in emission order: tracker_event(t, e); tracker_end_tick(t, T)
//   tracker_verified(t, V)       after tick V is verified (no rollback can reach it any more)
//   for a in t.out { ... }; clear(&t.out)   (or push them into a Queue for the render thread)
//
// A tick's Emitted come in emission order; cancels and confirmations come in tick order and, within a tick,
// in emission order.
//
// Events are identified by `Event_Id` (tick, kind, subject, nth): the caller picks what makes two events "the
// same" across re-simulations (src/sim/README.md, Events: the subject convention). Each tracked event also gets a
// serial when it is Emitted, the same on its Confirmed or Cancelled, for the view to match them (an event cancelled
// and produced again later is a new one, with a new serial).

// What makes two events from different simulations of a tick the same one (tracker_init's `id_of` builds it).
Event_Id :: struct {
	tick:   u32,
	kind:   u32,
	entity: u64, // the subject's key (a handle's key, an entity), 0 if none
	player: u64, // the subject player's key (sim.player_key), 0 if none
	nth:    u32, // among the tick's events of the same kind and subject
}

// A step of an event's lifecycle: Emitted once, then Confirmed or Cancelled once (UnifiedSession.EventState).
Event_Action :: enum u8 {
	Emitted, // first produced by a simulation of its tick
	Confirmed, // its tick is verified: it will never be cancelled
	Cancelled, // a re-simulation no longer produces it
}

// One step the tracker outputs (Event_Tracker.out): the event in its newest simulation, and its serial.
Tracked :: struct($E: typeid) {
	action: Event_Action,
	event:  E,
	serial: u64, // assigned at Emitted, the same on its Confirmed or Cancelled; never 0
}

@(private)
Pending :: struct($E: typeid) {
	id:     Event_Id,
	event:  E,
	order:  u32, // its index among the tick's events in the current simulation of the tick
	seen:   bool, // produced again by the current simulation of its tick
	serial: u64,
}

// The pending events (emitted, not yet confirmed or cancelled) live in a ring of per-tick lists, from the first
// unverified tick on, each list in its tick's emission order: a simulated tick costs its own events, nothing else.
Event_Tracker :: struct($E: typeid) {
	id_of:        proc(event: E) -> Event_Id,
	ticks:        [dynamic][dynamic]Pending(E), // a ring: the list of tick first_tick + i is ticks[(head + i) & mask]
	head:         int,
	count:        int, // the ticks the ring holds
	first_tick:   u32,
	verified:     u32,
	has_verified: bool,
	current:      ^[dynamic]Pending(E), // the list of the tick being simulated (nil: a final tick, ignored)
	emitted:      u32, // events of the current tick so far
	out:          [dynamic]Tracked(E),
	last_serial:  u64, // the newest serial given out
	scratch:      [dynamic]Pending(E), // reordering a tick's list after a re-simulation
	index:        Tick_Table(Event_Id, i32), // the current tick's pending events by id (their index in its list)
}

// Sets how the tracker tells that two events from different simulations of a tick are the same one (the
// caller's Event_Id convention), and the serial the first event gets after (a new tracker can continue an old one's,
// so serials never repeat). Call once before the first tick.
tracker_init :: proc(tracker: ^Event_Tracker($E), id_of: proc(event: E) -> Event_Id, last_serial: u64 = 0) {
	tracker.id_of = id_of
	tracker.last_serial = last_serial
}

// Frees the tracker's lists and output buffers and zeroes it: tracker_init makes it a new tracker again.
tracker_destroy :: proc(tracker: ^Event_Tracker($E)) {
	for list in tracker.ticks do delete(list)
	delete(tracker.ticks)
	delete(tracker.out)
	delete(tracker.scratch)
	tick_table_destroy(&tracker.index)
	tracker^ = {}
}

// The list of `tick`'s pending events, the ring grown to hold it.
@(private)
tracker_list :: proc(tracker: ^Event_Tracker($E), tick: u32) -> ^[dynamic]Pending(E) {
	if tracker.count == 0 {
		tracker.first_tick, tracker.head = tick, 0
	}
	if tick < tracker.first_tick { 	// a tick before the first pending one: the ring starts earlier
		tracker_room(tracker, tracker.count + int(tracker.first_tick - tick))
		tracker.head = (tracker.head - int(tracker.first_tick - tick)) & (len(tracker.ticks) - 1)
		tracker.count += int(tracker.first_tick - tick)
		tracker.first_tick = tick
	}
	index := int(tick - tracker.first_tick)
	if index >= tracker.count {
		tracker_room(tracker, index + 1)
		tracker.count = index + 1
	}
	return &tracker.ticks[(tracker.head + index) & (len(tracker.ticks) - 1)]
}

// Grows the ring (a power of two) to hold `needed` ticks, keeping their order from `head`.
@(private)
tracker_room :: proc(tracker: ^Event_Tracker($E), needed: int) {
	if needed <= len(tracker.ticks) do return
	capacity := max(len(tracker.ticks), 16)
	for capacity < needed do capacity *= 2
	grown := make([dynamic][dynamic]Pending(E), capacity)
	for i in 0 ..< len(tracker.ticks) do grown[i] = tracker.ticks[(tracker.head + i) & (len(tracker.ticks) - 1)]
	delete(tracker.ticks)
	tracker.ticks = grown
	tracker.head = 0
}

// Starts a simulation of `tick`. Ticks at or below the verified one are final: re-simulating them (a rollback that
// starts there) changes nothing the view has not already confirmed, so their events are ignored.
tracker_begin_tick :: proc(tracker: ^Event_Tracker($E), tick: u32) {
	tracker.emitted = 0
	tracker.current = nil
	if tracker.has_verified && tick <= tracker.verified do return
	tracker.current = tracker_list(tracker, tick)
	tick_table_reset(&tracker.index)
	for &pending, i in tracker.current {
		pending.seen = false
		tick_table_put(&tracker.index, pending.id, event_id_hash(pending.id), i32(i))
	}
}

// Records one event of the tick being simulated, in emission order. Outputs Emitted only the first time its id is
// seen; a re-simulation that produces it again just marks it seen, so tracker_end_tick keeps it.
tracker_event :: proc(tracker: ^Event_Tracker($E), event: E) {
	if tracker.current == nil do return
	id := tracker.id_of(event)
	order := tracker.emitted
	tracker.emitted += 1
	hash := event_id_hash(id)
	if index := tick_table_get(&tracker.index, id, hash); index != nil {
		pending := &tracker.current[index^]
		pending.seen, pending.event, pending.order = true, event, order
		return
	}
	tracker.last_serial += 1
	tick_table_put(&tracker.index, id, hash, i32(len(tracker.current)))
	append(tracker.current, Pending(E){id, event, order, true, tracker.last_serial})
	append(&tracker.out, Tracked(E){.Emitted, event, tracker.last_serial})
}

// Ends a simulation of the tick: its pending events this simulation did not produce again are Cancelled (a rollback
// changed the outcome), in the order they were emitted; the rest stay in this simulation's emission order.
tracker_end_tick :: proc(tracker: ^Event_Tracker($E), tick: u32) {
	list := tracker.current
	if list == nil do return
	tracker.current = nil
	in_order := true
	for pending, i in list {
		if !pending.seen do append(&tracker.out, Tracked(E){.Cancelled, pending.event, pending.serial})
		in_order &&= pending.seen && pending.order == u32(i)
	}
	if in_order do return // nothing cancelled, nothing reordered: the usual case
	resize(&tracker.scratch, int(tracker.emitted))
	for pending in list do if pending.seen do tracker.scratch[pending.order] = pending
	clear(list)
	append(list, ..tracker.scratch[:])
}

// The client's state was replaced by a snapshot of `tick` (a reconnect that came back as a joiner): every pending
// event was of a prediction nobody will verify, so each is Cancelled, and ticks up to `tick` are final.
tracker_restored :: proc(tracker: ^Event_Tracker($E), tick: u32) {
	for tracker.count > 0 {
		list := &tracker.ticks[tracker.head]
		for pending in list do append(&tracker.out, Tracked(E){.Cancelled, pending.event, pending.serial})
		clear(list)
		tracker.head = (tracker.head + 1) & (len(tracker.ticks) - 1)
		tracker.count -= 1
	}
	tracker.first_tick = tick + 1
	tracker.verified = tick
	tracker.has_verified = true
}

// Ticks up to `verified` are final: their pending events are Confirmed, in tick and emission order.
tracker_verified :: proc(tracker: ^Event_Tracker($E), verified: u32) {
	if tracker.has_verified && verified <= tracker.verified do return
	tracker.verified = verified
	tracker.has_verified = true
	for tracker.count > 0 && tracker.first_tick <= verified {
		list := &tracker.ticks[tracker.head]
		for pending in list do append(&tracker.out, Tracked(E){.Confirmed, pending.event, pending.serial})
		clear(list) // its memory is reused by a later tick
		tracker.head = (tracker.head + 1) & (len(tracker.ticks) - 1)
		tracker.count -= 1
		tracker.first_tick += 1
	}
}

// An Event_Id's hash for a Tick_Table.
@(private)
event_id_hash :: proc(id: Event_Id) -> u64 {
	hash := u64(id.tick) << 32 | u64(id.kind)
	hash = (hash ~ id.entity) * 0x9E3779B97F4A7C15
	hash = (hash ~ id.player) * 0xC2B2AE3D27D4EB4F
	return (hash ~ u64(id.nth)) * 0x9E3779B97F4A7C15
}

// A small open-addressed table for what one tick looks up (session thread): reset by a stamp, so a reset clears
// nothing, and it only allocates when a tick needs more room than any before.
@(private)
Tick_Table :: struct($K, $V: typeid) {
	slots: []Tick_Slot(K, V),
	stamp: u32, // the entries of the current reset (0: never reset)
	count: int,
	alloc: runtime.Allocator, // the slots' (context.allocator at the first put)
}

@(private)
Tick_Slot :: struct($K, $V: typeid) {
	stamp: u32,
	hash:  u64, // the key's (rehashing on growth)
	key:   K,
	value: V,
}

// Empties the table.
@(private)
tick_table_reset :: proc(table: ^Tick_Table($K, $V)) {
	table.stamp += 1
	if table.stamp == 0 { 	// wrapped: a stamp of 0 marks a slot never written
		for &slot in table.slots do slot.stamp = 0
		table.stamp = 1
	}
	table.count = 0
}

// The value stored under `key` (`hash`: the key's hash), nil when there is none.
@(private)
tick_table_get :: proc(table: ^Tick_Table($K, $V), key: K, hash: u64) -> ^V {
	if len(table.slots) == 0 do return nil
	mask := len(table.slots) - 1
	for i := int(hash >> 32) & mask; table.slots[i].stamp == table.stamp; i = (i + 1) & mask {
		if table.slots[i].key == key do return &table.slots[i].value
	}
	return nil
}

// Stores `value` under `key`, which is not in the table yet; grows (doubling) to stay at most half full.
@(private)
tick_table_put :: proc(table: ^Tick_Table($K, $V), key: K, hash: u64, value: V) {
	if table.stamp == 0 do tick_table_reset(table)
	if 2 * (table.count + 1) > len(table.slots) {
		if table.alloc.procedure == nil do table.alloc = context.allocator
		old := table.slots
		table.slots = make([]Tick_Slot(K, V), max(16, 2 * len(old)), table.alloc)
		table.count = 0
		for slot in old do if slot.stamp == table.stamp do tick_table_insert(table, slot.hash, slot.key, slot.value)
		delete(old, table.alloc)
	}
	tick_table_insert(table, hash, key, value)
}

@(private)
tick_table_insert :: proc(table: ^Tick_Table($K, $V), hash: u64, key: K, value: V) {
	mask := len(table.slots) - 1
	i := int(hash >> 32) & mask
	for table.slots[i].stamp == table.stamp do i = (i + 1) & mask
	table.slots[i] = {table.stamp, hash, key, value}
	table.count += 1
}

// Frees the table's slots.
@(private)
tick_table_destroy :: proc(table: ^Tick_Table($K, $V)) {
	if table.alloc.procedure != nil do delete(table.slots, table.alloc)
	table^ = {}
}
