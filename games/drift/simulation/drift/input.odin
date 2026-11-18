package drift

import "unified:dmath"
import "unified:sim"

Button :: enum u8 {
	Fire, // held: fires every FIRE_EVERY_TICKS
	Boost, // held: boosts whenever the cooldown allows
}

Buttons :: bit_set[Button;u8]

// One player's input for one tick, in world space (the plane's x right, y down): the move as a stick (dmath.stick),
// the aim as a direction (dmath.Dir2; none: keep the heading), the buttons held.
Input :: struct {
	move_x:  i8,
	move_y:  i8,
	aim:     dmath.Dir2,
	buttons: Buttons,
	_pad:    u8,
}

Inputs :: sim.Inputs(Game)

// `start` (GDScript: CommandStart): the lobby becomes a match. Ignored outside the lobby.
Cmd_Start :: struct {}

// `restart` (CommandRestart): an over match goes back to the lobby at once. Ignored unless the match is over.
Cmd_Restart :: struct {}

Cmd :: union {
	Cmd_Start,
	Cmd_Restart,
}
