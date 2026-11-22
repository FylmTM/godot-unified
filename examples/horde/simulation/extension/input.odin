package horde_extension

import "unified:dmath"
import "unified:godot"

import g "../horde"

// The stick from the InputMap's move actions (WASD, the arrows, a pad's left stick and d-pad): every input sample,
// on the session thread.
sample_input :: proc(_: int, input: ^g.Input) {
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back")
	input.dx = dmath.axis_i8(move.x)
	input.dy = dmath.axis_i8(move.y)
}
