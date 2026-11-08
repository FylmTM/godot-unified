// The smallest GDExtension: no bindings, no classes. It prints the marker line the release smoke test
// looks for, so the pipeline (build, import, export, sign, run) is checked end to end.
package standin_extension

import "base:runtime"
import "core:fmt"

Initialization_Level :: enum i32 {
	Core,
	Servers,
	Scene,
	Editor,
}

Initialization :: struct {
	minimum_initialization_level: Initialization_Level,
	userdata:                     rawptr,
	initialize:                   proc "c" (userdata: rawptr, level: Initialization_Level),
	deinitialize:                 proc "c" (userdata: rawptr, level: Initialization_Level),
}

@(export, link_name = "unified_init")
unified_init :: proc "c" (get_proc_address: rawptr, library: rawptr, init: ^Initialization) -> u8 {
	init.minimum_initialization_level = .Scene
	init.initialize = on_initialize
	init.deinitialize = on_deinitialize
	return 1
}

on_initialize :: proc "c" (userdata: rawptr, level: Initialization_Level) {
	if level != .Scene do return
	context = runtime.default_context()
	fmt.println("unified: extension initialized (release stand-in)")
}

on_deinitialize :: proc "c" (userdata: rawptr, level: Initialization_Level) {}
