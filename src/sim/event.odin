// Events (src/sim/SPEC.md "Events"): what a tick tells the view (a shot, a hit, a pickup). The game
// declares one plain struct per event and a union of them (sim.Game's Event; kind = variant index, name =
// type name lowercased). Events are deterministic, kept per tick in the ring as kind + bytes and
// emitted again when a tick is re-simulated, so a view shows predicted events at once and confirms or
// cancels them when the tick is verified. Not state: not in the block, not hashed.
package sim

import "base:intrinsics"

EVENT_MAX :: 64 // bytes of one event's struct

// A point in sim units (2D games: z = 0). The view maps fields of this type to its units (Glue.view_scale).
Position :: distinct [3]f32

// A fixed thing in events and views (a level marker, an item of a fixed array): sim.entity(index). Its zero value is
// none, so index 0 is a thing. Godot routes an event to the views keyed by its first sim.Entity field's index (a
// table's item has a Handle instead).
Entity :: distinct u64

// The Entity of the thing at `index` (0 ..).
entity :: proc(index: int) -> Entity {
	return Entity(index + 1)
}

// The index of the thing an Entity names (false: none).
entity_index :: proc(entity: Entity) -> (index: int, ok: bool) {
	return int(entity) - 1, entity != 0
}

// One event of a tick: its kind and its struct's bytes.
Raw_Event :: struct {
	kind: u8,
	size: u8,
	data: [EVENT_MAX]u8,
}

// A tick's events, in emission order.
Events :: struct {
	list: [dynamic]Raw_Event,
}

// Emits an event from inside `tick`: `sim.emit(t, Event_Coin_Picked{coin = handle, player = player})`. A value
// that is not a variant of the game's Event union does not compile.
emit :: proc(tick: ^Tick($G), event: $E) where intrinsics.type_is_variant_of(part(G, GAME_EVENT), E) {
	Event :: part(G, GAME_EVENT)
	#assert(size_of(E) <= EVENT_MAX)
	event := event
	raw := Raw_Event {
		kind = u8(intrinsics.type_variant_index_of(Event, E)),
		size = size_of(E),
	}
	copy(raw.data[:], ([^]u8)(&event)[:size_of(E)])
	append(&tick.events.list, raw)
}

// The event as the game's union (nil: a kind out of range or the wrong size).
event_value :: proc(raw: ^Raw_Event, $Event: typeid) -> Event {
	return union_value(int(raw.kind), raw.data[:raw.size], Event)
}
