package horde_odin_extension

import "unified:dmath"
import "unified:godot"

import g "../../../horde/simulation/horde"

UNIT_PX :: 32 // view pixels per sim unit

// No scene views: everything is drawn in Odin.
View :: union {}

// No MultiMesh views either.
MultiView :: enum u8 {}

// Which UI draws the HUD and the cards (`-- --ui controls`; the default: immediate).
Ui_Kind :: enum {
	Immediate,
	Controls,
}

ui_kind: Maybe(Ui_Kind)

// Glue.draw: the world, the effects, then the UI the command line chose.
draw_all :: proc(d: ^Draw) {
	draw(d)
	kind, known := ui_kind.?
	if !known {
		kind = .Immediate
		args := godot.user_args()
		for arg, i in args do if arg == "--ui" && i + 1 < len(args) && args[i + 1] == "controls" do kind = .Controls
		ui_kind = kind
	}
	switch kind {
	case .Immediate:
		ui_immediate(d)
	case .Controls:
		ui_controls(d)
	}
}

// The stick from the arrow keys (and a pad's d-pad), through Godot's ui_* actions.
sample_input :: proc(_: int, input: ^g.Input) {
	move := godot.action_vector("ui_left", "ui_right", "ui_up", "ui_down")
	input.dx = dmath.axis_i8(move.x)
	input.dy = dmath.axis_i8(move.y)
}
