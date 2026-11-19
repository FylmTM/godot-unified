package extension

import "unified:dmath"
import "unified:godot"

import g "../drift"

// ---- input (main thread, once a frame per local player)

// What the arena's script sets every frame (Unified.input.aim, Unified.local_input(local).aim).
Input_Values :: struct {
	aim: [2]f32, // a world-space direction from the mouse (relative to the local ship) or the right stick; zero: keep
}

// The movement, fire and boost from the InputMap on this local player's device, and the aim: a pad player's own right
// stick, else what the arena set (the mouse, for the players on the keyboard). A tap of fire or boost shorter than a
// frame still counts (action_down).
sample_input :: proc(local: int, input: ^g.Input) {
	move := godot.action_vector("move_left", "move_right", "move_up", "move_down") // +y is down, the plane's +y
	input.move_x, input.move_y = dmath.axis_i8(move.x), dmath.axis_i8(move.y)
	aim := godot.input_values(Input_Values).aim
	if godot.local_device(local) >= 0 { 	// a pad of its own: its right stick
		if stick := godot.action_vector("aim_left", "aim_right", "aim_up", "aim_down"); stick != {} do aim = stick
	}
	input.aim = dmath.dir2(aim)
	input.buttons = godot.buttons(g.Buttons, {.Fire = "fire", .Boost = "boost"})
}
