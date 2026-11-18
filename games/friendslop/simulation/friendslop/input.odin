package friendslop

import "unified:dmath"
import "unified:sim"

Button :: enum u8 {
	Jump,
	Grab, // toggle: press to grab, press again to drop; held, it catches
	Throw, // held charges a throw, released throws
}

Buttons :: bit_set[Button;u8]

// One player's input for one tick (8 bytes). Directions are world-space: the client rotates the stick by its camera
// and sends the camera's look direction (dmath.Dir3), so the sim needs no trig. Buttons are held: presses and
// releases come from sim.buttons. Presence (joined or not) comes from the relay, not from the input.
Input :: struct {
	move_x:  i8,
	move_z:  i8,
	buttons: Buttons,
	_spare:  u8,
	aim:     dmath.Dir3,
}
#assert(size_of(Input) == 8)

// The game has no commands (sim.Game's Cmd).
Cmd :: sim.No_Commands
