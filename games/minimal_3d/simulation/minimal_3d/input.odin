package minimal_3d

import "unified:sim"

// One player's input for one tick: the stick, each axis -127..127 (dmath.axis_i8).
Input :: struct {
	dx: i8, // right
	dy: i8, // down
}

// A tick's inputs and commands, by slot.
Inputs :: sim.Inputs(Game)

THROW_SPEED_MAX :: 8 // metres per second: a faster throw is thrown at this speed

// `throw_ball` (GDScript: CommandThrowBall): the sender throws a ball straight up at `speed` metres per second.
Cmd_Throw_Ball :: struct {
	speed: u8,
}

// Every command a player can send.
Cmd :: union {
	Cmd_Throw_Ball,
}
