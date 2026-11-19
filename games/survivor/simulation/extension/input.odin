package survivor_extension

import "unified:dmath"
import "unified:godot"

import g "../survivor"

// The input, sampled on the main thread for the one local player: movement and the dash from the InputMap. The
// level-up pick is a command: the HUD sends it (a Pick).
sample_input :: proc(_: int, input: ^g.Input) {
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back") // +y = move_back = +Z
	input.move_x, input.move_z = dmath.axis_i8(move.x), dmath.axis_i8(move.y)
	// the sim dashes on the press (sim.buttons); a tap shorter than a frame still counts
	input.buttons = godot.buttons(g.Buttons, {.Dash = "dash"})
}
