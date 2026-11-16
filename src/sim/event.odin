// Events (src/sim/SPEC.md "Events"): what a tick tells the view (a shot, a hit, a pickup). The game
// declares one plain struct per event and a union of them (Game.events; kind = variant index, name =
// type name lowercased). Events are deterministic, kept per tick in the ring as kind + bytes and
// emitted again when a tick is re-simulated, so a view shows predicted events at once and confirms or
// cancels them when the tick is verified. Not state: not in the block, not hashed.
package sim

import "base:intrinsics"

EVENT_MAX :: 64 // bytes of one event's struct

// A point in sim units (2D games: z = 0). The view maps fields of this type to its units (Glue.view_scale).
Position :: distinct [3]f32

// One event of a tick: its kind and its struct's bytes.
Raw_Event :: struct {
	kind: u8,
	size: u8,
	data: [EVENT_MAX]u8,
}

// A tick's events, in emission order.
Events :: struct {
	type: typeid, // the game's event union (Game.events)
	list: [dynamic]Raw_Event,
}

// Emits an event from inside `tick`: `sim.emit(t, Event_Coin_Picked{coin = handle, player = player})`. A value
// that is not a variant of the game's Event union does not compile.
emit :: proc(
	tick: ^Tick($State, $Input, $World, $Event, $Cmd, $PLAYERS),
	event: $E,
) where intrinsics.type_is_variant_of(Event, E) {
	#assert(size_of(E) <= EVENT_MAX)
	event := event
	raw := Raw_Event {
		kind = u8(intrinsics.type_variant_index_of(Event, E)),
		size = size_of(E),
	}
	copy(raw.data[:], ([^]u8)(&event)[:size_of(E)])
	append(&tick.events.list, raw)
}

// Appends an event to a tick's list, the union known at run time (the harness's own join and leave events); E must
// be one of the union's structs.
emit_to :: proc(events: ^Events, event: $E) {
	kind := variant_kind(events.type, E)
	assert(kind >= 0, "sim.emit: not a variant of the game's event union")
	event := event
	raw := Raw_Event {
		kind = u8(kind),
		size = size_of(E),
	}
	#assert(size_of(E) <= EVENT_MAX)
	copy(raw.data[:], ([^]u8)(&event)[:size_of(E)])
	append(&events.list, raw)
}

// The event as the game's union (nil: a kind out of range or the wrong size).
event_value :: proc(raw: ^Raw_Event, $Event: typeid) -> Event {
	return union_value(int(raw.kind), raw.data[:raw.size], Event)
}
