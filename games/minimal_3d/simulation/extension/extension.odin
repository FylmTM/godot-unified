package extension

import "base:runtime"
import "unified:gdext/gdi"
import "unified:godot"

import g "../minimal_3d"

GLUE := godot.Glue(g.State, g.Input, g.World, View, MultiView) {
	sample_input      = sample_input,
	fill_frame        = fill_frame,
	scripted_input    = scripted_input,
	scripted_commands = g.scripted_commands,
}

scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^g.State) -> g.Input {
	return g.scripted_input(seed, slot, tick)
}

@(export, link_name = "minimal_3d_init")
minimal_3d_init :: proc "c" (
	get_proc_address: gdi.InterfaceGetProcAddress,
	library: gdi.ClassLibraryPtr,
	initialization: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	godot.install(&g.GAME, GLUE)
	return godot.entry(get_proc_address, library, initialization)
}
