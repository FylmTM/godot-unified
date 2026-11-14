package view

import "core:slice"

// Predicted events (an explosion, a death) are shown as soon as a predicted tick produces them. A rollback
// re-simulates ticks: an event produced again must not be shown twice, one that is no longer produced is
// cancelled, and one whose tick becomes verified is confirmed. The tracker runs on the sim thread, sees every
// simulated tick (predicted, re-simulated or verified), and outputs actions for the render thread:
//
//   tracker_begin_tick(t, T); for each event of tick T, in emission order: tracker_event(t, e); tracker_end_tick(t, T)
//   tracker_verified(t, V)       after tick V is verified (no rollback can reach it any more); a tick fed with
//                                verifying = true just before is the verified tick itself
//   for a in t.out { ... }; clear(&t.out)   (or push them into a Queue for the render thread)
//
// Each event is Predicted (first produced by an unverified tick), then Confirmed or Cancelled; an event first
// seen when its tick is verified is only Confirmed. `first` is true the first time an event is shown (its
// Predicted, or a Confirmed nothing predicted). Cancels and confirmations of one tick come out in emission
// order, and ticks in order.
//
// Events are identified by `Event_Id` (tick, kind, subject, nth): the caller picks what makes two events "the
// same" across re-simulations (src/sim/SPEC.md "Events": the subject convention).

Event_Id :: struct {
	tick:   u32,
	kind:   u32,
	entity: u64, // the subject's key (a handle's key, an entity), 0 if none
	player: u32, // the subject player, sim.NO_PLAYER if none
	nth:    u32, // among the tick's events of the same kind and subject
}

Event_Action :: enum u8 {
	Predicted, // produced by a tick not yet verified: show it
	Confirmed, // its tick is verified: it will never be cancelled (show it if `first`)
	Cancelled, // a re-simulation no longer produces it: undo it (stop the effect)
}

Tracked :: struct($E: typeid) {
	action: Event_Action,
	first:  bool, // the first time this event is shown
	event:  E,
}

@(private)
Pending :: struct($E: typeid) {
	event: E,
	order: u32, // its index among the tick's events, the last time the tick was simulated
	seen:  bool, // produced again by the current simulation of its tick
	shown: bool, // went out as Predicted (false: first seen while verifying its tick)
}

Event_Tracker :: struct($E: typeid) {
	id_of:        proc(event: E) -> Event_Id,
	pending:      map[Event_Id]Pending(E), // seen, not yet verified
	verified:     u32,
	has_verified: bool,
	current_tick: u32,
	verifying:    bool, // the current tick is being verified: new events wait for tracker_verified
	emitted:      u32, // events of the current tick so far
	out:          [dynamic]Tracked(E),
	scratch:      [dynamic]Flush_Item,
}

tracker_init :: proc(tracker: ^Event_Tracker($E), id_of: proc(event: E) -> Event_Id) {
	tracker.id_of = id_of
}

tracker_destroy :: proc(tracker: ^Event_Tracker($E)) {
	delete(tracker.pending)
	delete(tracker.out)
	delete(tracker.scratch)
}

// Ticks at or below the verified one are final: re-simulating them (a rollback that starts there) changes
// nothing the view has not already confirmed, so their events are ignored. `verifying`: this is the tick
// about to be verified (tracker_verified follows), so an event no prediction showed is only Confirmed.
tracker_begin_tick :: proc(tracker: ^Event_Tracker($E), tick: u32, verifying := false) {
	tracker.current_tick = tick
	tracker.verifying = verifying
	tracker.emitted = 0
	for id, &pending in tracker.pending {
		if id.tick == tick do pending.seen = false
	}
}

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
	tracker.pending[id] = {event, order, true, !tracker.verifying}
	if !tracker.verifying do append(&tracker.out, Tracked(E){.Predicted, true, event})
}

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
	tracker.verifying = false
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
		if action == .Cancelled && !pending.shown do continue // never shown: nothing to undo
		append(&tracker.out, Tracked(E){action, action == .Confirmed && !pending.shown, pending.event})
	}
}

@(private)
Flush_Item :: struct {
	id:    Event_Id,
	order: u32,
}
