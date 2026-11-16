// Buttons (src/sim/SPEC.md "Input"): an Input's buttons are state, a bit_set field named `buttons` holding what is
// down. Presses and releases are what changed since the tick before (Players keeps each slot's input of the tick
// before, so a rollback, a snapshot and a replay carry it), so a repeated input (prediction, the relay's
// substitute) never presses twice.
package sim

import "base:intrinsics"

// A player's buttons this tick: `down` (held), `pressed` (down now, up the tick before) and `released` (up now,
// down the tick before), each a set of the Input's button enum.
Button_State :: struct($Set: typeid) {
	down:     Set,
	pressed:  Set,
	released: Set,
}

// The player's buttons this tick, from their Input's `buttons` bit_set (all up when absent; on their first tick in
// a slot, everything down counts as pressed):
//
//   buttons := sim.buttons(t, player)
//   if .Jump in buttons.pressed { ... }
//   if .Throw in buttons.released { ... }
//   if .Fire in buttons.down { ... }
buttons :: proc(
	t: ^Tick($State, $Input, $World, $PLAYERS),
	player: Player,
) -> Button_State(intrinsics.type_field_type(Input, "buttons")) where intrinsics.type_has_field(Input, "buttons") {
	now := input(t, player).buttons
	before := input_before(t, player).buttons
	return {down = now, pressed = now - before, released = before - now}
}
