// Saves (src/sim/README.md, Saves): the Setup that continues a session (Game.save, from verified ticks) and that Setup
// as JSON, which a new build reads back by field names. Never inside `tick`.
package sim

import "base:runtime"
import "core:strings"

// What Game.save gave for tick `tick` (step calls it on every tick it computes, predicted or not, and keeps the answer
// by ring slot), against `saved`, the last save taken (the session's Setup before the first): true when it gave one
// whose bytes differ, now in `saved`. Call it on verified ticks only, every one in order (the netcode client does; an
// offline run on every tick), so a mispredicted state is never saved. False without a Game.save, or when the ring
// has moved past the tick.
save_changed :: proc(simulation: ^Sim($G), tick: u32, saved: ^$Setup) -> bool where Setup == part(G, GAME_SETUP) {
	if simulation.saves == nil do return false
	entry := &simulation.saves[ring_slot(simulation, tick)]
	if entry.tick != tick || !entry.given || string(bytes_of(&entry.setup)) == string(bytes_of(saved)) do return false
	saved^ = entry.setup
	return true
}

// A Setup as JSON (value_json: fields by name, a List by its items, an enum by its member's name), in `allocator`:
// what a game keeps as its save file, which a later build reads back (setup_from_json).
setup_to_json :: proc(setup: ^$Setup, allocator := context.allocator) -> string {
	return value_to_json(type_info_of(Setup), setup, allocator)
}

// The Setup a save's JSON gives this build: the game's default Setup (Game.setup) with the text's values over it
// (value_from_json), so a field the save lacks (a build that added it) keeps its default and a key this build lacks
// is skipped. `problem` says what does not read, or why the result would not read as sent (setup_violation): "" when
// it is the next session's Setup (temp-allocated); the Setup is the default then.
setup_from_json :: proc(game: ^$G, text: string) -> (setup: part(G, GAME_SETUP), problem: string) {
	setup = game.setup
	if problem = value_from_json(type_info_of(part(G, GAME_SETUP)), &setup, text); problem == "" {
		problem = setup_violation(game, &setup)
	}
	if problem != "" do setup = game.setup
	return
}

// value_json into a string of its own (a non-generic home for the strings import: -vet).
@(private)
value_to_json :: proc(type: ^runtime.Type_Info, data: rawptr, allocator: runtime.Allocator) -> string {
	out := strings.builder_make(allocator)
	value_json(&out, type, data)
	return strings.to_string(out)
}
