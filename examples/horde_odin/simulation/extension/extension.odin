// horde_odin's GDExtension: examples/horde's sim with everything the player sees in Odin, immediate mode: the world
// (draw.odin), the effects (fx.odin) and the HUD and level-up cards, two ways (`-- --ui immediate`, the default:
// ui_immediate.odin, drawn and clicked in Odin; `--ui controls`: ui_controls.odin, Godot Controls made from Odin).
// No views, no session data, no GDScript object per event.
package horde_odin_extension

import "unified:godot"

import g "../../../horde/simulation/horde"

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input     = sample_input,
	is_2d            = true,
	view_scale       = UNIT_PX,
	draw             = draw_all,
	event            = on_event,
	no_script_events = true,
}

@(export, link_name = "horde_odin_init")
horde_odin_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	initialization: ^godot.Initialization,
) -> godot.Init_Result {
	return godot.init(&g.GAME, GLUE, get_proc_address, library, initialization)
}
