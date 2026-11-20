// playground's GDExtension (game/playground.gdextension -> .out/bin/libplayground.*): the playground sim run by
// unified:godot, plus the game's glue (this file); the view contract and the frame (frame.odin) and how the InputMap and
// the camera rig become an Input (input.odin). Built by `uni build playground`.
package playground_extension

import "unified:godot"

import g "../playground"

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame = fill_frame,
	data = Data,
	views = {.Camera = {data = Camera_View}, .Sensor = {data = Sensor_View}},
	input_values = Input_Values,
}

@(export, link_name = "playground_init")
playground_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	initialization: ^godot.Initialization,
) -> godot.Init_Result {
	return godot.init(&g.GAME, GLUE, get_proc_address, library, initialization)
}
