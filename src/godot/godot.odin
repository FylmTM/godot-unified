// unified:godot: everything that touches Godot for a game built on unified (src/godot/README.md). A game's GDExtension
// entry calls `init` with its sim.Game and a Glue (how Godot's input becomes its Input, and its State views), which
// registers:
//
//   UnifiedSession (Node)       one per app: runs a session (single player, host, join) on its own thread, samples
//                               input, syncs the views at process priority -1000, routes events, hosts the dev UI.
//   UnifiedView (Node)          the marker of a scene view's scene (a direct child of its root).
//   UnifiedMultiView (Node)     the marker under a MultiMeshInstance3D / 2D the host fills.
//   UnifiedEvent, UnifiedCommand (RefCounted) and a class per kind of the game's event and command unions.
//   Unified (the engine singleton), UnifiedData, UnifiedConstants, UnifiedInput, a class per session data type,
//   nested struct and enum.
//
// The session thread is the only one that touches the sim; Godot is called only from the main thread; nothing runs in
// the editor. Threads, the hand-off and the main thread's frame: src/godot/README.md, How it works.
package godot

import "base:runtime"
import "core:fmt"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:netcode"

@(private)
BUILD_TAG :: #config(UNIFIED_BUILD_TAG, "dev")

// What Godot hands a GDExtension's entry point, and what it returns (a game's extension names them here, so it never
// imports unified:gdext).
Get_Proc_Address :: gdi.InterfaceGetProcAddress
Class_Library :: gdi.ClassLibraryPtr
Initialization :: gdi.Initialization
Init_Result :: gdi.Bool

// A game's GDExtension entry point in one call (it sets the context itself): installs the game and its Glue, takes
// its lobby service for online play (nil: LAN and single player only; eos.lobby links the EOS SDK) and its constants
// (Unified.constants: the proc itself, which init calls once it has set the context, so it may format strings or
// compute shapes; its plain `Data_` struct is copied), and hands Godot the extension's callbacks: install, the lobby,
// then entry, in their one valid order.
//
//   @(export, link_name = "survivor_init")
//   survivor_init :: proc "c" (gpa: godot.Get_Proc_Address, lib: godot.Class_Library, init: ^godot.Initialization) -> godot.Init_Result {
//       return godot.init(&survivor.GAME, GLUE, gpa, lib, init, eos.lobby({}), constants = constants)
//   }
//
// A test build (ODIN_TEST) compiles it to nothing, so a game's tests import its extension for its Glue
// (install_problems) without compiling the whole host for the game.
init :: proc {
	init_with_constants,
	init_without_constants,
}

init_with_constants :: proc "c" (
	game: ^$G,
	glue: Glue(G, $View, $MultiView),
	get_proc_address: Get_Proc_Address,
	library: Class_Library,
	initialization: ^Initialization,
	online: ^netcode.Lobby = nil,
	constants: proc() -> $Constants,
) -> Init_Result {
	when ODIN_TEST {
		return 0
	} else {
		context = runtime.default_context()
		value := constants()
		install(game, glue, value)
		lobby = online
		return entry(get_proc_address, library, initialization)
	}
}

init_without_constants :: proc "c" (
	game: ^$G,
	glue: Glue(G, $View, $MultiView),
	get_proc_address: Get_Proc_Address,
	library: Class_Library,
	initialization: ^Initialization,
	online: ^netcode.Lobby = nil,
) -> Init_Result {
	when ODIN_TEST {
		return 0
	} else {
		context = runtime.default_context()
		install(game, glue)
		lobby = online
		return entry(get_proc_address, library, initialization)
	}
}

// The extension's callbacks for Godot (init's last step; after `install`, which tests call alone).
entry :: proc(get_proc_address: Get_Proc_Address, library: Class_Library, init: ^Initialization) -> Init_Result {
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
		gd.load_docs() // the editor's help: each class's and member's doc from where it is bound
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
	control_close()
	delete(app_version)
	app_version = ""
	if lobby != nil && lobby.shutdown != nil do lobby.shutdown()
	data_objects_free()
	input_clear()
	gd.shutdown() // unregisters every class, in reverse
	data_classes_forget()
	clear(&sim_classes) // the classes themselves live as long as the process (a hot reload registers anew)
	clear(&event_classes)
}

// Whether the extension runs inside the Godot editor, where the session node and views stay inert: the editor
// shows scenes, the game never runs in it.
@(private)
is_editor :: proc() -> bool {
	return gd.Engine_is_editor_hint(gd.Engine_singleton())
}

// The game's version: the project setting application/config/version, which a release build stamps from its
// tag. Read on the main thread when the session node is ready, before any session starts, so a lobby can
// report it (EOS product_version) from the session thread.
@(private)
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
