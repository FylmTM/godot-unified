package holdout

import "unified:dmath"
import "unified:sim"

// One player's input for one tick: the stick in the player's own frame, the buttons held, how late the screen they
// acted on was (the host stamps it: sim.Seen) and where they look. 8 bytes.
Input :: struct {
	move_x:  i8, // strafe right, -127..127 (dmath.axis_i8)
	move_z:  i8, // forward
	buttons: Buttons,
	seen:    sim.Seen,
	aim:     dmath.Aim,
}

// What a player holds down (sim.buttons derives presses from the tick before).
Button :: enum u8 {
	Jump,
	Fire, // held: the rifle fires every FIRE_INTERVAL_TICKS
	Grenade, // pressed: a grenade, once its cooldown ran out
	Use, // held beside a downed teammate: revives them
	Ready, // pressed in the lobby: the countdown starts
}

Buttons :: bit_set[Button;u8]

// A tick's inputs, by slot.
Inputs :: sim.Inputs(Game)
