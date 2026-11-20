// The input (main thread): the stick and the buttons from the InputMap, the aim from the camera rig.
package holdout_extension

import "unified:dmath"
import "unified:godot"

import g "../holdout"

// What the camera rig (game/rig.gd) sets every frame on the session's input_wanted: where it looks, in turns (Godot
// rotation's yaw and pitch divided by TAU), kept by the rig as doubles so a long turn never drifts.
Input_Values :: struct {
	yaw:   f32,
	pitch: f32,
}

// A press shorter than a frame still counts (the buttons latch until a tick takes them).
sample_input :: proc(_: int, input: ^g.Input) {
	values := godot.input_values(Input_Values)
	// get_vector: x right, y back (Godot's forward is -Z): the sim's stick is strafe right, forward
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back")
	input.move_x = dmath.axis_i8(move.x)
	input.move_z = dmath.axis_i8(-move.y)
	input.aim = dmath.aim(values.yaw, values.pitch)
	input.buttons = godot.buttons(
		g.Buttons,
		{.Jump = "jump", .Fire = "fire", .Grenade = "grenade", .Use = "use", .Ready = "ready"},
	)
}
