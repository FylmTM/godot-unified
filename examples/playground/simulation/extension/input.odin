// The input (main thread): the stick flies the camera along its look, the camera rig's yaw and pitch are the aim.
package playground_extension

import "unified:dmath"
import "unified:godot"

import g "../playground"

// What the camera rig sets every frame, on the session's input_wanted (Unified.input.yaw_turns, .pitch_turns).
Input_Values :: struct {
	yaw_turns:   f32, // about +Y, counter-clockwise seen from above; 0 looks toward -Z
	pitch_turns: f32, // up
}

sample_input :: proc(_: int, input: ^g.Input) {
	values := godot.input_values(Input_Values)
	// get_vector: x right, y back (Godot's forward is -Z)
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back")
	input.right = dmath.axis_i8(move.x)
	input.forward = dmath.axis_i8(-move.y)
	input.up = dmath.axis_i8(f32(int(godot.action_down("move_up"))) - f32(int(godot.action_down("move_down"))))
	input.aim = dmath.aim(values.yaw_turns, values.pitch_turns)
	input.buttons = godot.buttons(g.Buttons, {.Grab = "grab", .Closer = "closer", .Farther = "farther"})
}
