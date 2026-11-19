package extension

import "unified:dmath"
import "unified:godot"

import g "../drift"

// ---- input (main thread, the one local player)

// What the arena's script sets every frame (Unified.input.aim).
Input_Values :: struct {
	aim: [2]f32, // a world-space direction from the mouse (relative to the local ship) or the right stick; zero: keep
}

// The movement, fire and boost from the InputMap, and the aim. A tap of fire or boost shorter than a frame still
// counts (action_down).
sample_input :: proc(_: int, input: ^g.Input) {
	move := godot.action_vector("move_left", "move_right", "move_up", "move_down") // +y is down, the plane's +y
	input.move_x, input.move_y = dmath.axis_i8(move.x), dmath.axis_i8(move.y)
	input.aim = dmath.dir2(godot.input_values(Input_Values).aim)
	input.buttons = godot.buttons(g.Buttons, {.Fire = "fire", .Boost = "boost"})
}
