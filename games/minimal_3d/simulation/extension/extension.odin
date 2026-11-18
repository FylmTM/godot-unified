package extension

import "base:runtime"
import "unified:gdext/gdi"
import "unified:godot"

import g "../minimal_3d"

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
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
