// godot_host: everything that touches Godot for a game built on unified. A game's GDExtension entry calls
// `install` with its sim.Game and a Glue (the game-specific mapping from its State to views, HUD and input),
// and registers these classes:
//
//   UnifiedSession (Node)                 one per app (an autoload's child): runs a session (single player,
//                                         host, join) on our own thread, samples input, syncs the views at
//                                         process priority -1000, routes events, hosts the dev UI.
//   SimView (Node3D), SimView2D (Node2D)  optional typed root for a view scene (`<Glue.scene_dir>/<kind>.tscn`);
//                                         plain Node3D / Node2D roots with script properties kind/entity/slot
//                                         work too.
//   SimBulkView (MultiMeshInstance3D),    optional typed bulk views; plain MultiMeshInstance3D / 2D nodes in
//   SimBulkView2D (MultiMeshInstance2D)   group `sim_bulk` with a script property `kind` work too.
//
// Threads: the session thread (macOS: the real-time thread class) is the only one that touches the sim; it
// publishes Frames through a triple buffer and events/status through SPSC queues. Godot is called only from
// the main thread. Nothing runs in the editor (extension classes run there like @tool scripts).
//
// Files: glue.odin (what a game provides, the Frame), driver.odin (the generic session driver), session.odin
// (UnifiedSession), views.odin (scene and bulk views), input.odin (InputMap sampling), platform.odin.
package godot_host

import "base:runtime"
import "core:fmt"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"

BUILD_TAG :: #config(UNIFIED_BUILD_TAG, "dev")

// The GDExtension entry for a game: call from the exported entry symbol after `install`.
//
//   @(export, link_name = "survivor_init")
//   survivor_init :: proc "c" (gpa: gdi.InterfaceGetProcAddress, lib: gdi.ClassLibraryPtr, init: ^gdi.Initialization) -> gdi.Bool {
//       context = runtime.default_context()
//       godot_host.install(&survivor.GAME, glue())
//       return godot_host.entry(gpa, lib, init)
//   }
entry :: proc(gpa: gdi.InterfaceGetProcAddress, lib: gdi.ClassLibraryPtr, init: ^gdi.Initialization) -> gdi.Bool {
	gd.init(gpa, lib)
	init.minimum_initialization_level = .INITIALIZATION_SCENE
	init.initialize = on_initialize
	init.deinitialize = on_deinitialize
	return 1
}

@(private)
on_initialize :: proc "c" (_: rawptr, level: gdi.InitializationLevel) {
	if level != .INITIALIZATION_SCENE do return
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	register_classes()
	editor := gd.Engine_is_editor_hint(gd.Engine_singleton())
	// release CI's smoke test looks for this line
	fmt.printfln(
		"unified: extension initialized (%s), %s build %s",
		editor ? "editor" : "game",
		api.game_name,
		BUILD_TAG,
	)
}

@(private)
on_deinitialize :: proc "c" (_: rawptr, level: gdi.InitializationLevel) {
	if level != .INITIALIZATION_SCENE do return
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	// Hot reload or exit: the session thread runs code from this library, so it must be gone first.
	session_shutdown_all()
	delete(app_version)
	app_version = ""
	if transport != nil && transport.shutdown != nil do transport.shutdown(transport.user)
	unregister_classes()
	gd.shutdown()
}

is_editor :: proc() -> bool {
	return gd.Engine_is_editor_hint(gd.Engine_singleton())
}

// The game's version: the project setting application/config/version, which a release build stamps from its
// tag. Read on the main thread when the session node is ready, before any session starts, so transports can
// report it (EOS product_version) from the session thread.
app_version: string

@(private)
read_app_version :: proc() {
	if app_version != "" do return
	nil_v := gd.variant_nil()
	v := gd.ProjectSettings_get_setting(gd.ProjectSettings_singleton(), "application/config/version", nil_v)
	defer gd.variant_destroy(&v)
	s, _ := gd.from_variant(string, &v)
	app_version = strings.clone(s != "" ? s : "0")
}
