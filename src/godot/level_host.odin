// The level host (src/godot/README.md, Levels): the active level is state (sim.Active_Level), so each Frame carries the
// level of its tick and of the newest verified tick, and the main thread follows the verified one: it loads that
// level's scene on a thread (the scene its .level file was exported from), swaps it in under
// UnifiedSession.level_root, and syncs the views only from frames of the level on screen.
#+private
package godot

import "core:fmt"

import gd "unified:gdext"
import "unified:gdext/gdi"

// A tick's active level: Active_Level's `since` and `id` (-1: the game keeps none).
Level_Stamp :: struct {
	since: u32,
	id:    i32,
}

NO_LEVEL :: Level_Stamp {
	id = -1,
}

// What the session node keeps of the level it shows.
Level_Host :: struct {
	root:     gd.Node, // where the active level's scene is instanced (UnifiedSession.level_root)
	root_id:  u64,
	shown:    Level_Stamp, // the level on screen (NO_LEVEL: none yet)
	target:   Level_Stamp, // the verified level it goes to (shown when it is there)
	loading:  string, // the scene being loaded for `target` ("": none)
	scene:    gd.Node, // the shown level's instance under root (nil: none)
	scene_id: u64,
	markers:  gd.Array, // the shown scene's markers (level_markers), once asked for
	marked:   bool,
}

// The active level of a state block (`base`: its first byte), by the State's `level` field (install found it).
level_stamp :: proc(base: rawptr) -> Level_Stamp {
	if api.level_offset < 0 do return NO_LEVEL
	field := ([^]u8)(base)[api.level_offset:]
	return {since = (^u32)(&field[0])^, id = i32(field[4])}
}

// A new session: nothing is shown of it yet (the old scene stays until the new one's first level is in).
level_host_reset :: proc(host: ^Level_Host) {
	host.shown, host.target = NO_LEVEL, NO_LEVEL
	host.loading = ""
}

// Follows the frame's verified level: a new one starts its scene's load (level_changing), a loaded one is swapped in
// (level_changed). True when the frame is of another level than the one on screen: its views wait.
level_host_process :: proc(session: ^Session_Node, frame: ^Frame_Data) -> (hold: bool) {
	host := &session.level
	target := frame.verified_level
	if target.id < 0 do return false
	if target != host.target {
		host.target = target
		host.loading = ""
		if target != host.shown {
			gd.emit_signal(session.obj, gd.sn("level_changing"), i64(target.id))
			if path := level_scene_path(target.id); level_root_of(session).ptr != nil && path != "" {
				loader := gd.ResourceLoader_singleton()
				if gd.ResourceLoader_load_threaded_request(loader, path, "PackedScene") == .OK do host.loading = path
			}
		}
	}
	if host.shown != host.target do level_host_advance(session)
	return frame.level != host.shown
}

// Swaps the target level in once its scene is loaded (at once without a level_root or a scene).
@(private = "file")
level_host_advance :: proc(session: ^Session_Node) {
	host := &session.level
	root := level_root_of(session)
	packed: gd.Ref(gd.PackedScene)
	if host.loading != "" && root.ptr != nil {
		loader := gd.ResourceLoader_singleton()
		progress := gd.array_new()
		defer gd.Array_destroy(&progress)
		status := gd.ResourceLoader_load_threaded_get_status(loader, host.loading, progress)
		if status == .THREAD_LOAD_IN_PROGRESS do return
		if status == .THREAD_LOAD_LOADED {
			packed = transmute(gd.Ref(gd.PackedScene))gd.ResourceLoader_load_threaded_get(loader, host.loading)
		} else {
			gd.print_error(
				fmt.tprintf("unified: the scene of level %d (%s) did not load", host.target.id, host.loading),
			)
		}
	}
	// Every scene view goes with the old level (a marker index names another marker in the new one).
	views_root_changed()
	level_scene_free(host)
	if packed.ptr != nil {
		host.scene = gd.PackedScene_instantiate(packed, .GEN_EDIT_STATE_DISABLED)
		gd.unref(&packed)
		if host.scene.ptr != nil {
			gd.Node_add_child(root, host.scene, false, .INTERNAL_MODE_DISABLED)
			host.scene_id = gdi.object_get_instance_id(host.scene.ptr)
		}
	}
	host.loading = ""
	host.shown = host.target
	gd.emit_signal(session.obj, gd.sn("level_changed"), i64(host.shown.id))
}

// Frees the shown level's instance and its marker cache.
level_scene_free :: proc(host: ^Level_Host) {
	if host.marked do gd.Array_destroy(&host.markers)
	host.marked = false
	if host.scene.ptr != nil && alive(host.scene_id) do gd.Node_queue_free(host.scene)
	host.scene, host.scene_id = {}, 0
}

// The scene a level was exported from (its .level file's header; "": none).
level_scene_path :: proc(id: i32) -> string {
	return api.level_scenes[id] if id >= 0 && int(id) < len(api.level_scenes) else ""
}

// level_root as set (nil: none, or a freed node).
level_root_of :: proc(session: ^Session_Node) -> gd.Node {
	return session.level.root if session.level.root.ptr != nil && alive(session.level.root_id) else {}
}

// The shown level's marker node at `index` (Unified.level_markers' order), or nil.
level_marker :: proc(session: ^Session_Node, index: i64) -> gd.Node {
	index := int(index)
	host := &session.level
	if host.scene.ptr == nil || !alive(host.scene_id) do return {}
	if !host.marked {
		host.markers = level_markers(host.scene)
		host.marked = true
	}
	if index < 0 || index >= gd.Array_size(&host.markers) do return {}
	value := gd.Array_get(&host.markers, index)
	defer gd.variant_destroy(&value)
	node, _ := gd.from_variant(gd.Node, &value)
	return node
}
