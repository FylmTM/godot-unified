// horde_hybrid's GDExtension: examples/horde's sim drawn in Odin, immediate mode (draw.odin: the world from the State
// every frame, effects from the events as Odin unions), with the HUD left to GDScript Controls (game/ui/hud.gd) on
// session data.
package horde_hybrid_extension

import "unified:godot"

import g "../../../horde/simulation/horde"

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input     = sample_input,
	fill_frame       = fill_frame,
	data             = Data,
	is_2d            = true,
	view_scale       = UNIT_PX,
	draw             = draw,
	event            = on_event,
	no_script_events = true,
}

@(export, link_name = "horde_hybrid_init")
horde_hybrid_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	initialization: ^godot.Initialization,
) -> godot.Init_Result {
	return godot.init(&g.GAME, GLUE, get_proc_address, library, initialization)
}
