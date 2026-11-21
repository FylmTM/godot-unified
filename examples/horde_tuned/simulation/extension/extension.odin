// horde_tuned's GDExtension: examples/horde's sim shown the tuned node way (MultiMesh views for the crowds, scene views
// for the few, pooled effects in GDScript).
package horde_tuned_extension

import "unified:godot"

import g "../../../horde/simulation/horde"

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
	is_2d        = true,
	view_scale   = UNIT_PX,
}

@(export, link_name = "horde_tuned_init")
horde_tuned_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	initialization: ^godot.Initialization,
) -> godot.Init_Result {
	return godot.init(&g.GAME, GLUE, get_proc_address, library, initialization)
}
