// unified:godot: everything that touches Godot for a game built on unified (src/godot/SPEC.md). A game's GDExtension
// entry calls `install` with its sim.Game and a Glue (how Godot's input becomes its Input, and its State views),
// then `entry`, which registers:
//
//   UnifiedSession (Node)       one per app: runs a session (single player, host, join) on its own thread, samples
//                               input, syncs the views at process priority -1000, routes events, hosts the dev UI.
//   UnifiedView (Node)          the marker of a scene view's scene (a direct child of its root).
//   UnifiedMultiView (Node)     the marker under a MultiMeshInstance3D / 2D the host fills.
//   UnifiedEvent, UnifiedCommand (RefCounted) and a class per kind of the game's event and command unions.
//
// Threads: the session thread (macOS: the real-time thread class) is the only one that touches the sim; it
// publishes Frames through a triple buffer and events/status through SPSC queues. Godot is called only from the
// main thread. Nothing runs in the editor (extension classes run there like @tool scripts).
//
// Files: glue.odin (what a game provides, the Frame), driver.odin (the generic session driver), poses.odin (the
// previous poses), session.odin (UnifiedSession), views.odin (views and markers), sim_classes.odin (event and
// command classes), command.odin, events.odin, input.odin, docs.odin (the editor's help), platform*.odin.
package godot

import "base:runtime"
import "core:fmt"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"

BUILD_TAG :: #config(UNIFIED_BUILD_TAG, "dev")

// The GDExtension entry for a game: call from the exported entry symbol after `install`.
//
//   @(export, link_name = "survivor_init")
//   survivor_init :: proc "c" (get_proc_address: gdi.InterfaceGetProcAddress, library: gdi.ClassLibraryPtr, init: ^gdi.Initialization) -> gdi.Bool {
//       context = runtime.default_context()
//       godot.install(&survivor.GAME, GLUE)
//       return godot.entry(get_proc_address, library, init)
//   }
entry :: proc(
	get_proc_address: gdi.InterfaceGetProcAddress,
	library: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	gd.init(get_proc_address, library)
	// Before Godot shuts its scripting down: the objects scripts connect to (Unified's data) go first, so a lambda
	// connected to one is never destroyed after GDScript is gone.
	@(static) callbacks := gdi.MainLoopCallbacks {
		shutdown_func = proc "c" () {
			context = runtime.default_context()
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			data_objects_free()
		},
	}
	gdi.register_main_loop_callbacks(library, &callbacks)
	init.minimum_initialization_level = .INITIALIZATION_SCENE
	init.initialize = on_initialize
	init.deinitialize = on_deinitialize
	return 1
}

@(private)
on_initialize :: proc "c" (_: rawptr, level: gdi.InitializationLevel) {
	if level == .INITIALIZATION_EDITOR {
		context = runtime.default_context()
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		load_docs()
		return
	}
	if level != .INITIALIZATION_SCENE do return
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	register_classes()
	editor := gd.Engine_is_editor_hint(gd.Engine_singleton())
	// release CI's smoke test looks for this line
	fmt.printfln(
		"unified: extension initialized (%s), %s build %s, dev ui %s",
		editor ? "editor" : "game",
		api.game_name,
		BUILD_TAG,
		DEVUI ? "on" : "off",
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
	input_clear()
	gd.shutdown()
}

// Whether the extension runs inside the Godot editor, where the session node and views stay inert: the editor
// shows scenes, the game never runs in it.
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
	nil_variant := gd.variant_nil()
	setting := gd.ProjectSettings_get_setting(
		gd.ProjectSettings_singleton(),
		"application/config/version",
		nil_variant,
	)
	defer gd.variant_destroy(&setting)
	version, _ := gd.from_variant(string, &setting)
	app_version = strings.clone(version != "" ? version : "0")
}
