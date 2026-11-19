package holdout_extension

import "unified:godot"

import g "../holdout"

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
}

@(export, link_name = "holdout_init")
holdout_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	initialization: ^godot.Initialization,
) -> godot.Init_Result {
	return godot.init(&g.GAME, GLUE, get_proc_address, library, initialization)
}
