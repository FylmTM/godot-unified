package extension

import "unified:godot"

import g "../minimal_3d"

sample_input :: proc(input: ^g.Input) {
	move := godot.action_vector("ui_left", "ui_right", "ui_up", "ui_down")
	input.dx = godot.axis_i8(move.x)
	input.dy = godot.axis_i8(move.y)
}
