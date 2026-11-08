package view

// Predicted events (an explosion, a death) are shown as soon as a predicted tick produces them. A rollback
// re-simulates ticks: an event produced again must not fire twice, one that is no longer produced must be
// cancelled, and one whose tick becomes verified is confirmed. The tracker runs on the sim thread, sees every
// simulated tick (predicted or re-simulated), and outputs actions for the render thread.
//
//   tracker_begin_tick(t, T); for each event of tick T: tracker_event(t, e); tracker_end_tick(t, T)
//   tracker_verified(t, V)            after tick V is verified (no rollback can reach it any more)
//   for a in t.out { ... }; clear(&t.out)   (or push them into a Queue for the render thread)
//
// Events are identified by `Event_Id` (tick, kind, entity, discriminator): the game picks what makes two
// events "the same" across re-simulations.

Event_Id :: struct {
	tick:   u32,
	kind:   u32,
	entity: u64, // spawn key or entity index
	extra:  u64, // discriminator for several events of one kind per entity and tick
}

Event_Action :: enum u8 {
	Fire, // new: show it (predicted unless tick <= verified)
	Cancel, // a re-simulation no longer produces it: undo it (stop the effect)
	Confirm, // its tick is verified: it will never be cancelled
}

Tracked :: struct($E: typeid) {
	action: Event_Action,
	event:  E,
}

@(private)
Pending :: struct($E: typeid) {
	event: E,
	seen:  bool, // produced again by the current re-simulation of its tick
}

Event_Tracker :: struct($E: typeid) {
	id_of:    proc(e: E) -> Event_Id,
	pending:  map[Event_Id]Pending(E), // fired, not yet verified
	verified: u32,
	cur_tick: u32,
	out:      [dynamic]Tracked(E),
}

tracker_init :: proc(t: ^Event_Tracker($E), id_of: proc(e: E) -> Event_Id) {
	t.id_of = id_of
}

tracker_destroy :: proc(t: ^Event_Tracker($E)) {
	delete(t.pending)
	delete(t.out)
}

tracker_begin_tick :: proc(t: ^Event_Tracker($E), tick: u32) {
	t.cur_tick = tick
	for id, &p in t.pending {
		if id.tick == tick do p.seen = false
	}
}

tracker_event :: proc(t: ^Event_Tracker($E), e: E) {
	id := t.id_of(e)
	if p, ok := &t.pending[id]; ok {
		p.seen = true
		p.event = e
		return
	}
	t.pending[id] = {e, true}
	append(&t.out, Tracked(E){.Fire, e})
}

tracker_end_tick :: proc(t: ^Event_Tracker($E), tick: u32) {
	for id, p in t.pending {
		if id.tick == tick && !p.seen {
			append(&t.out, Tracked(E){.Cancel, p.event})
			delete_key(&t.pending, id)
		}
	}
}

// Ticks up to `verified` are final: their pending events are confirmed.
tracker_verified :: proc(t: ^Event_Tracker($E), verified: u32) {
	if verified <= t.verified && t.verified != 0 do return
	t.verified = verified
	for id, p in t.pending {
		if id.tick <= verified {
			append(&t.out, Tracked(E){.Confirm, p.event})
			delete_key(&t.pending, id)
		}
	}
}
