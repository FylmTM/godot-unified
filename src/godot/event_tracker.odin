package godot

import "core:slice"

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
// same" across re-simulations (src/sim/SPEC.md "Events": the subject convention). Each tracked event also gets a
// serial when it is Emitted, the same on its Confirmed or Cancelled, for the view to match them (an event cancelled
// and produced again later is a new one, with a new serial).

Event_Id :: struct {
	tick:   u32,
	kind:   u32,
	entity: u64, // the subject's key (a handle's key, an entity), 0 if none
	player: u64, // the subject player's key (sim.player_key), 0 if none
	nth:    u32, // among the tick's events of the same kind and subject
}

Event_Action :: enum u8 {
	Emitted, // first produced by a simulation of its tick
	Confirmed, // its tick is verified: it will never be cancelled
	Cancelled, // a re-simulation no longer produces it
}

Tracked :: struct($E: typeid) {
	action: Event_Action,
	event:  E,
	serial: u64, // assigned at Emitted, the same on its Confirmed or Cancelled; never 0
}

@(private)
Pending :: struct($E: typeid) {
	event:  E,
	order:  u32, // its index among the tick's events, the last time the tick was simulated
	seen:   bool, // produced again by the current simulation of its tick
	serial: u64,
}

Event_Tracker :: struct($E: typeid) {
	id_of:        proc(event: E) -> Event_Id,
	pending:      map[Event_Id]Pending(E), // emitted, not yet confirmed or cancelled
	verified:     u32,
	has_verified: bool,
	current_tick: u32,
	emitted:      u32, // events of the current tick so far
	out:          [dynamic]Tracked(E),
	last_serial:  u64, // the newest serial given out
	scratch:      [dynamic]Flush_Item,
}

// Sets how the tracker tells that two events from different simulations of a tick are the same one (the
// caller's Event_Id convention), and the serial the first event gets after (a new tracker can continue an old one's,
// so serials never repeat). Call once before the first tick.
tracker_init :: proc(tracker: ^Event_Tracker($E), id_of: proc(event: E) -> Event_Id, last_serial: u64 = 0) {
	tracker.id_of = id_of
	tracker.last_serial = last_serial
}

// Frees the tracker's pending map and output buffers.
tracker_destroy :: proc(tracker: ^Event_Tracker($E)) {
	delete(tracker.pending)
	delete(tracker.out)
	delete(tracker.scratch)
}

// Ticks at or below the verified one are final: re-simulating them (a rollback that starts there) changes
// nothing the view has not already confirmed, so their events are ignored.
tracker_begin_tick :: proc(tracker: ^Event_Tracker($E), tick: u32) {
	tracker.current_tick = tick
	tracker.emitted = 0
	for id, &pending in tracker.pending {
		if id.tick == tick do pending.seen = false
	}
}

// Records one event of the tick being simulated, in emission order. Outputs Emitted only the first time its id is
// seen; a re-simulation that produces it again just marks it seen, so tracker_end_tick keeps it.
tracker_event :: proc(tracker: ^Event_Tracker($E), event: E) {
	id := tracker.id_of(event)
	if tracker.has_verified && id.tick <= tracker.verified do return
	order := tracker.emitted
	tracker.emitted += 1
	if pending, ok := &tracker.pending[id]; ok {
		pending.seen = true
		pending.event = event
		pending.order = order
		return
	}
	tracker.last_serial += 1
	tracker.pending[id] = {event, order, true, tracker.last_serial}
	append(&tracker.out, Tracked(E){.Emitted, event, tracker.last_serial})
}

// Ends a simulation of `tick`: its pending events this simulation did not produce again are Cancelled (a
// rollback changed the outcome). Ignored for ticks already verified.
tracker_end_tick :: proc(tracker: ^Event_Tracker($E), tick: u32) {
	if tracker.has_verified && tick <= tracker.verified do return
	tracker_flush(tracker, tick, tick, .Cancelled, proc(pending: Pending(E)) -> bool {return !pending.seen})
}

// Ticks up to `verified` are final: their pending events are confirmed.
tracker_verified :: proc(tracker: ^Event_Tracker($E), verified: u32) {
	if tracker.has_verified && verified <= tracker.verified do return
	low := tracker.verified + 1 if tracker.has_verified else 0
	tracker.verified = verified
	tracker.has_verified = true
	tracker_flush(tracker, low, verified, .Confirmed, proc(pending: Pending(E)) -> bool {return true})
}

// Outputs (and forgets) the pending events of ticks low..high that `chosen` picks, in tick and emission order
// (a map has no order of its own: #152).
@(private)
tracker_flush :: proc(
	tracker: ^Event_Tracker($E),
	low, high: u32,
	action: Event_Action,
	chosen: proc(pending: Pending(E)) -> bool,
) {
	clear(&tracker.scratch)
	for id, pending in tracker.pending {
		if id.tick >= low && id.tick <= high && chosen(pending) do append(&tracker.scratch, Flush_Item{id, pending.order})
	}
	slice.sort_by(tracker.scratch[:], proc(a, b: Flush_Item) -> bool {
		return a.id.tick < b.id.tick || (a.id.tick == b.id.tick && a.order < b.order)
	})
	for item in tracker.scratch {
		pending := tracker.pending[item.id]
		delete_key(&tracker.pending, item.id)
		append(&tracker.out, Tracked(E){action, pending.event, pending.serial})
	}
}

@(private)
Flush_Item :: struct {
	id:    Event_Id,
	order: u32,
}
