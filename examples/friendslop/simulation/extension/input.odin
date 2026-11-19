// The input (main thread): the stick moves relative to the camera, the aim is the camera's look.
package friendslop_extension

import "unified:dmath"
import "unified:godot"

import g "../friendslop"

// What the camera rig sets every frame, on the session's input_wanted (Unified.input.look, .right): movement is
// relative to them.
Input_Values :: struct {
	look:  [3]f32, // the camera's look direction
	right: [3]f32, // its flat right
}

// A jump or grab tap shorter than a frame still counts (action_down).
sample_input :: proc(_: int, input: ^g.Input) {
	values := godot.input_values(Input_Values)
	look, right := values.look, values.right
	if look == {} do look = {0, 0, -1}
	if right == {} do right = {1, 0, 0}
	forward := dmath.normalize(look.xz)
	flat_right := dmath.normalize(right.xz)
	// get_vector: x right, y back (Godot's forward is -Z); the camera's forward is `forward`.
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back")
	input.move_x = dmath.axis_i8(flat_right.x * move.x - forward.x * move.y)
	input.move_z = dmath.axis_i8(flat_right.y * move.x - forward.y * move.y)
	input.aim = dmath.dir3(look)
	input.buttons = godot.buttons(g.Buttons, {.Jump = "jump", .Grab = "grab", .Throw = "throw"})
}
