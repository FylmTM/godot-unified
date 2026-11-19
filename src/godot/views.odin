// Views (src/godot/README.md): scene views spawned per spawn key under the session's view_root from the scene the view
// index maps their kind to, interpolated and smoothed (track.odin); and MultiMesh views whose buffers are
// written natively. A scene view's scene holds a UnifiedView marker as a direct child of its root; a MultiMesh view
// is a MultiMeshInstance3D / 2D holding a UnifiedMultiView marker. The root's class picks how it is shown: a
// Node3D gets position and quaternion, a Node2D position and rotation, anything else (a Control HUD) only data.
#+private
package godot

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"

LINGER_S :: 0.25 // UnifiedView.linger_s's default: a despawned view stays this long (exit animation, or a rollback)
INDEX_PATH :: "res://unified_index.tres" // the view index `uni bake` writes (metadata `views`: kind -> scene path)

Root_Mode :: enum u8 {
	Node3D,
	Node2D,
	Other, // data only: no pose
}

// A scene view is identified by its kind and key (a key is unique within its kind).
View_Id :: struct {
	kind: u8,
	key:  u64,
}

Scene_View :: struct {
	node:        gd.Node, // the scene's root
	mode:        Root_Mode,
	id:          u64,
	marker:      gd.Node, // its UnifiedView (nil: the scene has none)
	marker_id:   u64,
	kind:        u8,
	player:      u64, // the player's key (sim.player_key; 0: none)
	key:         u64, // its subject's key (push_view)
	subject:     typeid, // its subject's type (push_view; nil: none): only events with a subject of this type reach it
	linger_s:    f64, // its marker's
	spawn_tick:  u32, // the tick it first appeared at
	verified:    bool, // its spawn tick has been verified: from then on it can't be a cancelled spawn
	gone:        bool, // _sim_despawned was called (and no _sim_revived since)
	warp:        u8, // the warp epoch last shown: another one resets the track (the view snaps)
	track:       Track,
	shown:       Pose, // the pose last set on the root (view units), so an unchanged one isn't set again
	posed:       bool,
	using hooks: View_Hooks, // the root's script's
	data:        []u8, // the data last set as properties
}

// Which optional callbacks a view kind's root script has: looked up at the kind's first spawn (every view of a kind
// is its scene's instance).
View_Hooks :: struct {
	has_event:    bool,
	has_sim_pose: bool,
	callbacks:    [View_Callback]bool,
}

// The root script's lifecycle callbacks.
View_Callback :: enum u8 {
	Despawned, // its key is gone: it lingers (linger_s; the host no longer sets its pose), then is freed
	Revived, // a rollback brought it back while it lingered
	Cancelled, // a rollback removed it before its spawn tick was verified: freed at once, never despawned
}

VIEW_CALLBACK_NAMES := [View_Callback]string {
	.Despawned = "_sim_despawned",
	.Revived   = "_sim_revived",
	.Cancelled = "_sim_cancelled",
}

// The names the host passes every frame or event, interned once at registration (gd.sn looks a name up by its text).
NAMES: struct {
	view_event: ^gd.StringName, // a scene view's _sim_event
	sim_pose:   ^gd.StringName, // a script-posed view's _sim_pose (Posed_By.Script)
	sim_event:  ^gd.StringName, // UnifiedSession.sim_event (the signal)
	callbacks:  [View_Callback]^gd.StringName,
}


// A MultiMesh view: a MultiMeshInstance3D / 2D and its UnifiedMultiView marker.
Multi_View :: struct {
	marker:     gd.Node,
	marker_id:  u64,
	node:       gd.Node, // the marker's parent
	id:         u64,
	kind:       int, // index into api.multi_names, -1: unknown
	smooth:     bool, // its kind's policy keeps a track per keyed instance (Glue.multi_policy)
	decay:      f32, // this frame's track_decay of its kind's smoothing (smooth)
	mm:         gd.Ref(gd.MultiMesh),
	buf:        gd.PackedFloat32Array,
	cap:        int,
	count:      int, // the instances written this frame
	stride:     int,
	is_2d:      bool, // transform_format TRANSFORM_2D: 8 floats per transform, else 12
	has_col:    bool,
	has_custom: bool,
	bounds:     bool, // the host sets custom_aabb (the game set none): Godot needn't recompute it from the buffer
	low, high:  [3]f32, // this frame's instance origins (bounds)
	reach:      f32, // this frame's largest scale factor (bounds)
	live:       bool, // its node is alive this frame (checked once, by multi_sync)
	mesh:       rawptr, // the mesh `mesh_reach` was measured on
	mesh_reach: f32, // the mesh's farthest point from its origin
	ptr:        [^]f32,
	tracks:     map[u64]Multi_Track, // smooth: by key
}

Multi_Track :: struct {
	track: Track,
	seen:  int, // the fresh frame that last had this key
	warp:  u8, // the warp epoch last shown
}

V: struct {
	set:         View_Set(View_Id, ^Scene_View),
	scenes:      map[u8]gd.Ref(gd.PackedScene),
	missing:     map[u8]bool, // kinds whose scene failed to load (reported once)
	index:       map[string]string, // the view index: kind name -> scene path
	index_read:  bool,
	multis:      [dynamic]Multi_View,
	frame:       int,
	fresh_count: int,
	clock:       time.Tick,
	fields:      map[typeid][]Sim_Field, // per view data type, built on first use
	hooks:       map[u8]View_Hooks, // per scene view kind, at its first spawn
	reported:    map[string]bool, // warnings and errors given once per process
	stats:       Sync_Stats,
}

// The main thread's view-sync cost, summed over frames until a script takes it (UnifiedSession.take_sync_stats:
// the view-sync benchmark, tests/godot_views/view_bench.gd; a game's own performance readout).
Sync_Stats :: struct {
	frames:       int,
	fresh:        int, // frames that showed a new tick
	events:       int, // event deliveries (one per event state)
	scene:        time.Duration, // scene views: spawns, data, poses
	multi_build:  time.Duration, // MultiMesh views: every instance interpolated and written into its buffer
	multi_upload: time.Duration, // MultiMesh views: set_buffer, set_visible_instance_count
	delivery:     time.Duration, // events: their objects, _sim_event, the sim_event signal
	total:        time.Duration, // the whole sync (session_process from the newest frame on)
	total_max:    time.Duration,
}

// ---- the marker classes

Unified_View_Node :: struct {
	using hdr: gd.Instance_Header,
	kind:      string,
	key:       i64,
	player:    i64,
	linger_s:  f64,
}

Unified_Multi_View_Node :: struct {
	using hdr: gd.Instance_Header,
	kind:      string,
}

unified_view_class, unified_multi_view_class: gd.Class

// Registers every class the extension gives Godot (UnifiedSession, the event and command classes, UnifiedView,
// UnifiedMultiView) at SCENE initialization.
register_classes :: proc() {
	if len(api.problems) > 0 {
		for problem in api.problems {
			gd.print_error(fmt.tprintf("unified: the game %s is not installed: %s", api.game_name, problem))
		}
	}
	NAMES.view_event, NAMES.sim_event, NAMES.sim_pose = gd.sn("_sim_event"), gd.sn("sim_event"), gd.sn("_sim_pose")
	for name, callback in VIEW_CALLBACK_NAMES do NAMES.callbacks[callback] = gd.sn(name)
	register_session_class()
	register_nested_classes() // before the classes whose fields hold them
	register_sim_classes()
	register_data_classes()
	unified_view_class = {
		name = "UnifiedView",
		parent = "Node",
		size = size_of(Unified_View_Node),
		doc_brief = "Marks a scene as the view of one kind of the game's scene views.",
		doc = "A direct child of the scene's root. [code]uni bake[/code] indexes the scenes by it; the host sets [member key] and keeps [member player] current. The root may be a Node3D (position and quaternion), a Node2D (position and rotation) or anything else (data only), posed before any other node's [code]_process[/code]; a kind the game's view policy script-poses is not posed: the host calls its script's [code]_sim_pose(position: Vector3, rotation: Quaternion)[/code] (2D: [code](position: Vector2, rotation: float)[/code]) with that pose whenever it changes. Its script may define [code]_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState)[/code], properties named after the fields of the view's data, and the lifecycle callbacks [code]_sim_despawned()[/code] (its key is gone: it lingers [member linger_s], no longer posed, then is freed), [code]_sim_revived()[/code] (a rollback brought it back while it lingered) and [code]_sim_cancelled()[/code] (a rollback removed it before its spawn tick was verified: freed at once).",
		init = proc(instance: rawptr) {(^Unified_View_Node)(instance).linger_s = LINGER_S},
		fini = proc(instance: rawptr) {delete((^Unified_View_Node)(instance).kind)},
	}
	class := &unified_view_class
	gd.register_class(class)
	gd.bind_property(
		class,
		"kind",
		proc(node: ^Unified_View_Node) -> string {return node.kind},
		proc(node: ^Unified_View_Node, kind: string) {
			delete(node.kind)
			node.kind = strings.clone(kind)
		},
		hint = .ENUM_SUGGESTION,
		hint_string = strings.join(api.view_names, ",", context.temp_allocator),
		doc = "The view kind (the game's View enum member, lowercased: the inspector offers them), set in the scene.",
	)
	gd.bind_property(
		class,
		"key",
		proc(node: ^Unified_View_Node) -> i64 {return node.key},
		proc(node: ^Unified_View_Node, key: i64) {node.key = key},
		doc = "The key of the subject fill_frame pushed the view with (a player's key, a fixed thing's index, a handle's key; 0: none): the host sets it.",
	)
	gd.bind_property(
		class,
		"player",
		proc(node: ^Unified_View_Node) -> i64 {return node.player},
		proc(node: ^Unified_View_Node, player: i64) {node.player = player},
		doc = "The key of the player this view shows (0: none).",
	)
	gd.bind_property(
		class,
		"linger_s",
		proc(node: ^Unified_View_Node) -> f64 {return node.linger_s},
		proc(node: ^Unified_View_Node, linger_s: f64) {node.linger_s = max(linger_s, 0)},
		doc = "How long the view stays once its key is gone (an exit animation), in seconds.",
	)
	unified_multi_view_class = {
		name = "UnifiedMultiView",
		parent = "Node",
		size = size_of(Unified_Multi_View_Node),
		doc_brief = "Makes its parent MultiMeshInstance3D or MultiMeshInstance2D show one kind of the game's MultiMesh items.",
		doc = "The MultiMesh's [code]transform_format[/code] (2D or 3D, matching its instance), [code]use_colors[/code] and [code]use_custom_data[/code] decide the buffer's layout. The host owns [code]instance_count[/code], [code]visible_instance_count[/code] and the buffer (position and rotation interpolated between ticks, scale, color and custom data), and [code]custom_aabb[/code] unless the game set one before the first frame (the instances' origins grown by the mesh's reach: without it Godot transforms the mesh's AABB by every instance). Whether rollback corrections glide (a track per instance) is the game's view policy for the kind.",
		fini = proc(instance: rawptr) {delete((^Unified_Multi_View_Node)(instance).kind)},
		notification = proc(instance: rawptr, what: i32) {
			node := (^Unified_Multi_View_Node)(instance)
			switch what {
			case gd.Node_NOTIFICATION_ENTER_TREE:
				multi_register(gd.cast_to(gd.Node, node.obj), node)
			case gd.Node_NOTIFICATION_EXIT_TREE:
				multi_unregister(gdi.object_get_instance_id(node.obj.ptr))
			}
		},
	}
	class = &unified_multi_view_class
	gd.register_class(class)
	gd.bind_property(
		class,
		"kind",
		proc(node: ^Unified_Multi_View_Node) -> string {return node.kind},
		proc(node: ^Unified_Multi_View_Node, kind: string) {
			delete(node.kind)
			node.kind = strings.clone(kind)
		},
		hint = .ENUM_SUGGESTION,
		hint_string = strings.join(api.multi_names, ",", context.temp_allocator),
		doc = "The kind (the game's MultiView enum member, lowercased: the inspector offers them).",
	)
}


report_once :: proc(key, msg: string, error := true) {
	if V.reported[key] do return
	V.reported[strings.clone(key)] = true
	if error {
		gd.print_error(msg)
	} else {
		gd.print_warning(msg)
	}
}

// ---- the view index

index_read :: proc() {
	if V.index_read do return
	V.index_read = true
	if !gd.ResourceLoader_exists(gd.ResourceLoader_singleton(), INDEX_PATH, "") do return
	resource := gd.ResourceLoader_load(gd.ResourceLoader_singleton(), INDEX_PATH, "", .CACHE_MODE_REUSE)
	if resource.ptr == nil do return
	defer gd.unref(resource)
	nil_variant := gd.variant_nil()
	meta := gd.Object_get_meta(resource, "views", nil_variant)
	defer gd.variant_destroy(&meta)
	views, ok := gd.from_variant(gd.Dictionary, &meta)
	if !ok do return
	defer gd.Dictionary_destroy(&views)
	keys := gd.Dictionary_keys(&views)
	defer gd.Array_destroy(&keys)
	for i in 0 ..< gd.array_len(&keys) {
		kind, _ := gd.from_variant(string, gd.array_at(&keys, i))
		value := gd.Dictionary_get(&views, gd.array_at(&keys, i)^, nil_variant)
		path, _ := gd.from_variant(string, &value)
		gd.variant_destroy(&value)
		V.index[strings.clone(kind)] = strings.clone(path)
	}
}

// Before a session starts: every View member has a scene in the view index, and every indexed kind is a member.
views_check_index :: proc() {
	index_read()
	for name in api.view_names {
		if name not_in V.index {
			report_once(
				fmt.tprintf("index:%s", name),
				fmt.tprintf(
					"unified: view kind %q has no scene in the view index (%s): give a scene a UnifiedView marker with kind %q and run `uni bake`",
					name,
					INDEX_PATH,
					name,
				),
			)
		}
	}
	for kind in V.index {
		known := false
		for name in api.view_names do known ||= name == kind
		if !known {
			report_once(
				fmt.tprintf("index-unknown:%s", kind),
				fmt.tprintf(
					"unified: the view index has kind %q, which is not a member of the game's View enum",
					kind,
				),
			)
		}
	}
}

// ---- scene views

scene_for :: proc(kind: u8) -> (gd.PackedScene, bool) {
	if packed_scene, ok := V.scenes[kind]; ok do return packed_scene, true
	if V.missing[kind] do return {}, false
	index_read()
	name := int(kind) < len(api.view_names) ? api.view_names[kind] : fmt.tprintf("kind %d", kind)
	path, indexed := V.index[name]
	resource: gd.Resource
	if indexed do resource = gd.ResourceLoader_load(gd.ResourceLoader_singleton(), path, "", .CACHE_MODE_REUSE)
	if resource.ptr == nil {
		gd.print_error(
			indexed ? fmt.tprintf("unified: cannot load %s (view kind %q)", path, name) : fmt.tprintf("unified: view kind %q has no scene in the view index", name),
		)
		V.missing[kind] = true
		return {}, false
	}
	packed_scene := transmute(gd.Ref(gd.PackedScene))resource
	V.scenes[kind] = packed_scene
	return packed_scene, true
}

// The scene root's UnifiedView marker: its first direct child of that class.
find_marker :: proc(root: gd.Node) -> gd.Node {
	for i in 0 ..< gd.Node_get_child_count(root, false) {
		child := gd.Node_get_child(root, i, false)
		if gd.instance_of(child, &unified_view_class) != nil do return child
	}
	return {}
}

spawn_view :: proc(root: gd.Node, item: ^View_Out, frame: ^Frame_Data) -> ^Scene_View {
	packed_scene, ok := scene_for(item.kind)
	if !ok do return nil
	node := gd.PackedScene_instantiate(packed_scene, .GEN_EDIT_STATE_DISABLED)
	if node.ptr == nil do return nil
	scene_view := new(Scene_View)
	scene_view.node = node
	switch {
	case gd.object_cast(gd.Node3D, node).ptr != nil:
		scene_view.mode = .Node3D
	case gd.object_cast(gd.Node2D, node).ptr != nil:
		scene_view.mode = .Node2D
	case:
		scene_view.mode = .Other
	}
	kind := api.view_names[item.kind]
	scene_view.id = gdi.object_get_instance_id(node.ptr)
	scene_view.kind, scene_view.player, scene_view.key, scene_view.subject =
		item.kind, item.player, item.key, item.subject
	scene_view.linger_s = LINGER_S
	scene_view.spawn_tick = frame.tick
	scene_view.warp = item.warp
	scene_view.marker = find_marker(node)
	if scene_view.marker.ptr == nil {
		report_once(
			fmt.tprintf("marker:%s", kind),
			fmt.tprintf(
				"unified: the scene of view kind %q has no UnifiedView marker as a direct child of its root",
				kind,
			),
		)
	} else {
		scene_view.marker_id = gdi.object_get_instance_id(scene_view.marker.ptr)
		marker := (^Unified_View_Node)(gd.instance_of(scene_view.marker, &unified_view_class))
		if marker.kind != kind {
			report_once(
				fmt.tprintf("marker-kind:%s", kind),
				fmt.tprintf(
					"unified: the scene of view kind %q has a UnifiedView marker of kind %q",
					kind,
					marker.kind,
				),
			)
		}
		marker.key, marker.player = i64(item.key), i64(item.player) // the player's key (0: none)
		scene_view.linger_s = marker.linger_s
	}
	hooks, known := V.hooks[item.kind]
	if !known {
		hooks.has_event = gd.has_script_method(node, NAMES.view_event)
		hooks.has_sim_pose = gd.has_script_method(node, NAMES.sim_pose)
		for name, callback in NAMES.callbacks do hooks.callbacks[callback] = gd.has_script_method(node, name)
		V.hooks[item.kind] = hooks
		if kind_of(item.kind).pose == .Script && !hooks.has_sim_pose && scene_view.mode != .Other {
			report_once(
				fmt.tprintf("sim_pose:%s", kind),
				fmt.tprintf(
					"unified: view kind %q is script-posed (Glue.view_policy) but its root's script has no _sim_pose(position, rotation): the host poses it",
					kind,
				),
			)
		}
	}
	scene_view.hooks = hooks
	pose_view(scene_view, {to_view(item.pos), item.rot})
	gd.Node_add_child(root, node, false, .INTERNAL_MODE_DISABLED)
	// data after _ready: a script's property setters may use its @onready nodes
	if item.data_type != nil {
		fields := data_fields(item.data_type)
		for &field in fields {
			property := gd.Object_get(node, field.name_sn)
			if gd.variant_type(&property) == .NIL {
				report_once(
					fmt.tprintf("prop:%s:%s", kind, field.name),
					fmt.tprintf(
						"unified: scene view %q has no property %q for its data (%v)",
						kind,
						field.name,
						item.data_type,
					),
				)
			}
			gd.variant_destroy(&property)
		}
		set_data(scene_view, fields, frame.data[item.data_offset:][:item.data_size], true)
	}
	return scene_view
}

// A scene view kind's policy (the default for a kind out of range).
kind_of :: proc(kind: u8) -> Kind_Policy {
	return int(kind) < len(api.view_policy) ? api.view_policy[kind] : {smoothing = SMOOTHING_DEFAULT, tracks = true}
}

// Poses the root (set_pose), or hands the pose to its script's _sim_pose when its kind is script-posed.
pose_view :: proc(scene_view: ^Scene_View, pose: Pose) {
	if !scene_view.has_sim_pose || kind_of(scene_view.kind).pose != .Script {
		set_pose(scene_view, pose)
		return
	}
	result: gd.Variant
	switch scene_view.mode {
	case .Node2D:
		position := gd.Vector2{pose.pos.x, pose.pos.y}
		result = gd.call_script(scene_view.node, NAMES.sim_pose, position, f64(angle_2d_of(pose.rot)))
	case .Node3D:
		position := gd.Vector3{pose.pos.x, pose.pos.y, pose.pos.z}
		rotation := gd.Quaternion{pose.rot.x, pose.rot.y, pose.rot.z, pose.rot.w}
		result = gd.call_script(scene_view.node, NAMES.sim_pose, position, rotation)
	case .Other:
		return
	}
	gd.variant_destroy(&result)
}

// 3D: position and quaternion. 2D: position = pos.xy, rotation = the angle about Z. Other roots: nothing. The pose
// is in view units (to_view).
set_pose :: proc(scene_view: ^Scene_View, pose: Pose) {
	switch scene_view.mode {
	case .Node2D:
		node2d := gd.cast_to(gd.Node2D, scene_view.node)
		gd.Node2D_set_position(node2d, {pose.pos.x, pose.pos.y})
		gd.Node2D_set_rotation(node2d, angle_2d_of(pose.rot))
	case .Node3D:
		node3d := gd.cast_to(gd.Node3D, scene_view.node)
		gd.Node3D_set_position(node3d, {pose.pos.x, pose.pos.y, pose.pos.z})
		gd.Node3D_set_quaternion(node3d, {pose.rot.x, pose.rot.y, pose.rot.z, pose.rot.w})
	case .Other:
	}
}

// The fields of a view data type, built once (each set as the view's property of the same name, converted like an
// event's: events.odin field_variant).
data_fields :: proc(data_type: typeid) -> []Sim_Field {
	if fields, ok := V.fields[data_type]; ok do return fields
	fields: []Sim_Field
	if _, is_struct := runtime.type_info_base(type_info_of(data_type)).variant.(runtime.Type_Info_Struct); is_struct {
		fields = struct_sim_fields(type_info_of(data_type))
	} else {
		gd.print_error(fmt.tprintf("unified: view data %v must be a struct", data_type))
	}
	V.fields[data_type] = fields
	return fields
}

// Sets every data field whose bytes changed (all of them on a fresh view) as a property.
set_data :: proc(scene_view: ^Scene_View, fields: []Sim_Field, data: []u8, fresh: bool) {
	fresh := fresh
	if len(scene_view.data) != len(data) {
		delete(scene_view.data)
		scene_view.data = make([]u8, len(data))
		fresh = true
	}
	for &field in fields {
		bytes := data[field.offset:][:field.type.size]
		if !fresh && string(bytes) == string(scene_view.data[field.offset:][:len(bytes)]) do continue
		set_prop(scene_view.node, field.name_sn, field_variant(field.type, bytes, .Sim))
	}
	copy(scene_view.data, data)
}

set_prop :: proc(object: gd.Object, name: ^gd.StringName, value: gd.Variant) {
	value := value
	gd.Object_set(object, name, value)
	gd.variant_destroy(&value)
}

free_view :: proc(scene_view: ^Scene_View) {
	if scene_view == nil do return
	if alive(scene_view.id) do gd.Node_queue_free(scene_view.node)
	delete(scene_view.data)
	free(scene_view)
}

// Calls one of the root script's lifecycle callbacks (_sim_despawned, _sim_revived, _sim_cancelled), if it has it.
view_callback :: proc(scene_view: ^Scene_View, callback: View_Callback) {
	if scene_view == nil || !scene_view.callbacks[callback] || !alive(scene_view.id) do return
	result := gd.call_script(scene_view.node, NAMES.callbacks[callback])
	gd.variant_destroy(&result)
}

// Keeps the marker's player current (it may change after the spawn).
marker_update :: proc(scene_view: ^Scene_View) {
	if !alive(scene_view.marker_id) do return
	marker := (^Unified_View_Node)(gd.instance_of(scene_view.marker, &unified_view_class))
	if marker != nil do marker.player = i64(scene_view.player)
}

// Frees every scene view and MultiMesh binding and forgets the loaded scenes and the view index (main thread),
// when the session node leaves the tree or the extension unloads; the next sync starts from nothing.
views_clear :: proc() {
	debug_draw_clear()
	for _, entry in V.set.entries do free_view(entry.view)
	set_destroy(&V.set)
	V.set = {}
	for &multi in V.multis do multi_drop(&multi)
	delete(V.multis)
	V.multis = nil
	for _, packed_scene in V.scenes do gd.unref(packed_scene)
	delete(V.scenes)
	delete(V.missing)
	V.scenes, V.missing = nil, nil
	for _, fields in V.fields do delete(fields)
	delete(V.fields)
	delete(V.hooks)
	V.fields, V.hooks = nil, nil
	for kind, path in V.index {
		delete(kind)
		delete(path)
	}
	delete(V.index)
	V.index, V.index_read = nil, false
}

// View space is view_root's local space; event and command positions are in it too, so a script that places an
// effect at an event's position under another node, or sends the mouse's world position, is right only while
// view_root sits at the world origin: warned once when it doesn't.
view_space_check :: proc(root: gd.Node) {
	at_origin := true
	if node2d := gd.object_cast(gd.Node2D, root); node2d.ptr != nil {
		transform := gd.CanvasItem_get_global_transform(gd.cast_to(gd.CanvasItem, root))
		at_origin = transform == {x = {1, 0}, y = {0, 1}}
	} else if node3d := gd.object_cast(gd.Node3D, root); node3d.ptr != nil {
		transform := gd.Node3D_get_global_transform(node3d)
		at_origin = transform == {basis = {x = {1, 0, 0}, y = {0, 1, 0}, z = {0, 0, 1}}}
	}
	if !at_origin {
		report_once(
			"view_space",
			"unified: view_root is not at the world origin: view positions (events', commands') are its local space, not the world's",
			false,
		)
	}
}

// The game set or cleared view_root: drop every scene view (they lived under the old root).
views_root_changed :: proc() {
	for _, entry in V.set.entries do free_view(entry.view)
	clear(&V.set.entries)
}

// Brings the scene views under `root` and the MultiMesh instances up to date with the newest frame (main thread,
// every Godot frame): spawns, despawns, data and interpolated poses. A nil root drops the scene views.
views_sync :: proc(root: gd.Node, frame: ^Frame_Data, fresh: bool, alpha: f32, dt: f32) {
	V.frame += 1
	started := time.tick_now()
	if root.ptr == nil {
		if len(V.set.entries) > 0 do views_root_changed()
	} else {
		scene_sync(root, frame, fresh, alpha, dt)
	}
	scened := time.tick_now()
	multi_sync(frame, fresh, alpha, dt)
	built := time.tick_now()
	multi_upload(fresh)
	V.stats.scene += time.tick_diff(started, scened)
	V.stats.multi_build += time.tick_diff(scened, built)
	V.stats.multi_upload += time.tick_since(built)
}

scene_sync :: proc(root: gd.Node, frame: ^Frame_Data, fresh: bool, alpha: f32, dt: f32) {
	if V.clock == {} do V.clock = time.tick_now()
	now_s := time.duration_seconds(time.tick_since(V.clock))
	if fresh {
		set_begin(&V.set)
		for &item in frame.views[:frame.n_views] {
			id := View_Id{item.kind, item.key}
			entry, spawned, revived := set_see(&V.set, id)
			if spawned {
				entry.view = spawn_view(root, &item, frame)
				if entry.view != nil do entry.linger_s = entry.view.linger_s
			}
			scene_view := entry.view
			if scene_view == nil do continue
			if frame.verified >= scene_view.spawn_tick do scene_view.verified = true
			if revived && scene_view.gone { 	// a rollback brought it back during its linger
				scene_view.gone = false
				view_callback(scene_view, .Revived)
			}
			if scene_view.player != item.player {
				scene_view.player = item.player
				marker_update(scene_view)
			}
			if !spawned && alive(scene_view.id) && item.data_type != nil {
				set_data(
					scene_view,
					data_fields(item.data_type),
					frame.data[item.data_offset:][:item.data_size],
					false,
				)
			}
			if scene_view.mode == .Other do continue
			track_warp(&scene_view.track, &scene_view.warp, item.warp) // teleported: snaps
			smoothing := kind_of(item.kind).smoothing
			track_push_prev(&scene_view.track, frame.tick, {item.prev_pos, item.prev_rot}, item.has_prev, smoothing)
			track_push(&scene_view.track, frame.tick, {item.pos, item.rot}, smoothing)
		}
		// gone before their spawn tick was ever verified: cancelled spawns, freed at once
		cancelled := make([dynamic]View_Id, context.temp_allocator)
		for id, entry in V.set.entries {
			if entry.seen != V.set.frame && entry.phase == .Alive && entry.view != nil && !entry.view.verified {
				append(&cancelled, id)
			}
		}
		for id in cancelled {
			scene_view, _ := set_remove(&V.set, id)
			view_callback(scene_view, .Cancelled)
			free_view(scene_view)
		}
		set_end(&V.set, now_s)
		for id in V.set.despawned {
			if entry := set_get(&V.set, id); entry != nil && entry.view != nil {
				entry.view.gone = true
				view_callback(entry.view, .Despawned)
			}
		}
		for scene_view in V.set.removed {
			if scene_view != nil && !scene_view.gone do view_callback(scene_view, .Despawned) // linger_s 0
			free_view(scene_view)
		}
	}
	decays: [256]f32 = -1 // per kind: computed once a frame, when its first view needs it
	for _, &entry in V.set.entries {
		scene_view := entry.view
		if scene_view == nil || scene_view.mode == .Other || entry.phase == .Lingering do continue // lingering: unpinned, an exit animation may move it
		if !alive(scene_view.id) do continue
		smoothing := kind_of(scene_view.kind).smoothing
		decay := &decays[scene_view.kind]
		if decay^ < 0 do decay^ = track_decay(dt, smoothing)
		pose := track_sample_decayed(&scene_view.track, frame.tick, alpha, decay^, dt, smoothing) // sim units
		pose.pos = to_view(pose.pos)
		// before every other node's _process (priority -1000): a view's script reads it. An unchanged pose (a crate at
		// rest, a level marker) isn't set again: each set dirties the root's whole subtree. Unchanged within float noise: a
		// glide started from the last shown pose (frames the main thread skipped) leaves a correction of a few ulps that
		// decays over several frames, which no one can see.
		if scene_view.posed && pose_unchanged(pose, scene_view.shown) do continue
		pose_view(scene_view, pose)
		scene_view.shown, scene_view.posed = pose, true
	}
}

// ---- finding a view (UnifiedSession.get_view, get_player_view, get_views)

// A View kind as a script passes it (an EnumView value), or -1 for none of its members, reported once: a wrong one
// would otherwise read as "no view now".
view_kind_of :: proc(kind: i64, caller: string) -> int {
	if kind >= 0 && kind < i64(len(api.view_names)) do return int(kind)
	report_once(
		fmt.tprintf("view-kind:%d", kind),
		fmt.tprintf("unified: %s: %d is not a member of the game's View enum (EnumView)", caller, kind),
	)
	return -1
}

// A scene view that is in the sim (not lingering, its node alive): its root, else a null handle.
live_view_node :: proc(entry: ^Entry(^Scene_View)) -> gd.Node {
	if entry == nil || entry.view == nil || entry.phase != .Alive || !alive(entry.view.id) do return {}
	return entry.view.node
}

// The scene view of a kind and key.
view_of_key :: proc(view_kind: i64, key: u64) -> gd.Node {
	kind := view_kind_of(view_kind, "get_view")
	if kind < 0 do return {}
	return live_view_node(set_get(&V.set, View_Id{u8(kind), key}))
}

// The scene view of a kind that shows a player (by key).
view_of_player :: proc(view_kind: i64, player: u64) -> gd.Node {
	kind := view_kind_of(view_kind, "get_player_view")
	if kind < 0 || player == 0 do return {}
	for id, &entry in V.set.entries {
		if id.kind != u8(kind) || entry.view == nil || entry.view.player != player do continue
		if node := live_view_node(&entry); node.ptr != nil do return node
	}
	return {}
}

// Every scene view of a kind that is in the sim, by key: an Array[Node].
views_of_kind :: proc(view_kind: i64) -> gd.Array {
	views := gd.array_new()
	gd.array_set_typed(&views, .OBJECT, "Node")
	kind := view_kind_of(view_kind, "get_views")
	if kind < 0 do return views
	keys := make([dynamic]u64, context.temp_allocator)
	for id, &entry in V.set.entries do if id.kind == u8(kind) && live_view_node(&entry).ptr != nil do append(&keys, id.key)
	slice.sort(keys[:])
	for key in keys do gd.array_push(&views, live_view_node(set_get(&V.set, View_Id{u8(kind), key})))
	return views
}

// An event to its subject's scene views (_sim_event(event, state) on the root's script): the view Glue.event_key
// names (or none); else the views pushed with the event's subject (in kind order): its handle field's type and key, or
// its sim.Entity field's index among the views pushed with an Entity; else (no such view, or no such field) its
// player's views. A view named or keyed is found by its id; only the player route walks the views.
views_event :: proc(layout: ^Event_Layout, raw: ^sim.Raw_Event, state: i64, event: gd.Variant) {
	player, subject_key := event_subject(layout, raw.data[:raw.size])
	view_key, keyed_subject := subject_key, subject_key != 0
	if layout.subject >= 0 && !layout.subject_is_handle {
		index, ok := sim.entity_index(sim.Entity(subject_key))
		view_key, keyed_subject = u64(index), ok
	}
	if api.event_key != nil {
		subject := Subject {
			player = sim.player_of_key(player),
			handle = layout.subject_is_handle ? subject_key : 0,
			entity = layout.subject_is_handle ? 0 : sim.Entity(subject_key),
		}
		kind, key, event_route := api.event_key(raw, subject)
		switch event_route {
		case .Subject:
		case .View:
			if entry := set_get(&V.set, View_Id{kind, key}); entry != nil do call_sim_event(entry.view, event, state)
			return
		case .No_View:
			return
		}
	}
	if keyed_subject {
		keyed := false // a view has the subject's key (whether or not it takes events): the event goes to those only
		for kind in 0 ..< len(api.view_names) {
			entry := set_get(&V.set, View_Id{u8(kind), view_key})
			if entry == nil || entry.view == nil || entry.view.subject != layout.subject_type do continue
			keyed = true
			call_sim_event(entry.view, event, state)
		}
		if keyed do return
	}
	if player == 0 do return
	for _, &entry in V.set.entries {
		scene_view := entry.view
		if scene_view != nil && scene_view.player == player do call_sim_event(scene_view, event, state)
	}
}

// Calls the view root script's _sim_event, if it has one.
call_sim_event :: proc(scene_view: ^Scene_View, event: gd.Variant, state: i64) {
	if scene_view == nil || !scene_view.has_event || !alive(scene_view.id) do return
	result := gd.call_script(scene_view.node, NAMES.view_event, event, state)
	gd.variant_destroy(&result)
}

// ---- MultiMesh views

// A UnifiedMultiView entered the tree: its parent is the MultiMeshInstance it fills.
multi_register :: proc(marker: gd.Node, node: ^Unified_Multi_View_Node) {
	if is_editor() do return
	marker_id := gdi.object_get_instance_id(marker.ptr)
	for multi in V.multis do if multi.marker_id == marker_id do return
	parent := gd.Node_get_parent(marker)
	instance: gd.Node
	is_2d := false
	if instance3d := gd.object_cast(gd.MultiMeshInstance3D, parent); instance3d.ptr != nil {
		instance = instance3d
	} else if instance2d := gd.object_cast(gd.MultiMeshInstance2D, parent); instance2d.ptr != nil {
		instance, is_2d = instance2d, true
	} else {
		report_once(
			fmt.tprintf("multi-parent:%s", node.kind),
			fmt.tprintf(
				"unified: a UnifiedMultiView (kind %q) must be a child of a MultiMeshInstance3D or 2D",
				node.kind,
			),
		)
		return
	}
	kind := -1
	for name, i in api.multi_names do if name == node.kind do kind = i
	if kind < 0 {
		report_once(
			fmt.tprintf("multi-kind:%s", node.kind),
			fmt.tprintf(
				"unified: a UnifiedMultiView has kind %q, which is not a member of the game's MultiView enum",
				node.kind,
			),
		)
	}
	append(&V.multis, Multi_View {
		marker    = marker,
		marker_id = marker_id,
		node      = instance,
		id        = gdi.object_get_instance_id(instance.ptr),
		kind      = kind,
		smooth    = kind >= 0 && kind < len(api.multi_policy) && api.multi_policy[kind].tracks,
		is_2d     = is_2d,
	})
}

multi_unregister :: proc(marker_id: u64) {
	for i := len(V.multis) - 1; i >= 0; i -= 1 {
		if V.multis[i].marker_id != marker_id do continue
		multi_drop(&V.multis[i])
		ordered_remove(&V.multis, i)
	}
}

multi_drop :: proc(multi: ^Multi_View) {
	if multi.mm.ptr != nil do gd.unref(multi.mm)
	if multi.cap > 0 do gd.PackedFloat32Array_destroy(&multi.buf)
	delete(multi.tracks)
	multi^ = {}
}

// The view's MultiMesh, taken when it first has one; the buffer layout follows its own format.
multi_mesh :: proc(multi: ^Multi_View) -> bool {
	if multi.mm.ptr != nil do return true
	if multi.is_2d {
		multi.mm = gd.MultiMeshInstance2D_get_multimesh(gd.cast_to(gd.MultiMeshInstance2D, multi.node))
	} else {
		multi.mm = gd.MultiMeshInstance3D_get_multimesh(gd.cast_to(gd.MultiMeshInstance3D, multi.node))
	}
	if multi.mm.ptr == nil do return false
	kind := multi.kind >= 0 ? api.multi_names[multi.kind] : "?"
	format_2d := gd.MultiMesh_get_transform_format(multi.mm) == .TRANSFORM_2D
	if format_2d != multi.is_2d {
		report_once(
			fmt.tprintf("multi-format:%s", kind),
			fmt.tprintf(
				"unified: MultiMesh view %q: a %s needs transform_format TRANSFORM_%s",
				kind,
				multi.is_2d ? "MultiMeshInstance2D" : "MultiMeshInstance3D",
				multi.is_2d ? "2D" : "3D",
			),
		)
	}
	multi.is_2d = format_2d
	multi.stride = format_2d ? 8 : 12
	multi.has_col = gd.MultiMesh_is_using_colors(multi.mm)
	multi.has_custom = gd.MultiMesh_is_using_custom_data(multi.mm)
	if multi.has_col do multi.stride += 4
	if multi.has_custom do multi.stride += 4
	multi.bounds = gd.MultiMesh_get_custom_aabb(multi.mm) == {}
	return true
}

// One pass over the frame's MultiMesh items: counted per kind, then each written into the buffer of every view of
// its kind (usually one).
multi_sync :: proc(frame: ^Frame_Data, fresh: bool, alpha: f32, dt: f32) {
	if fresh do V.fresh_count += 1
	counts: [256]int
	for &item in frame.multis[:frame.n_multis] do counts[item.kind] += 1
	// views by kind: first[kind] -> next[...] (indices into V.multis, -1 ends)
	first: [256]i32 = -1
	next := make([]i32, len(V.multis), context.temp_allocator)
	cursor := make([]int, len(V.multis), context.temp_allocator)
	for i := len(V.multis) - 1; i >= 0; i -= 1 {
		multi := &V.multis[i]
		next[i] = -1
		multi.live = multi.kind >= 0 && alive(multi.id)
		if !multi.live || !multi_mesh(multi) do continue
		count := counts[multi.kind]
		if count > multi.cap {
			new_cap := max(count, 64, multi.cap * 2)
			if multi.cap == 0 do multi.buf = gd.PackedFloat32Array_new0()
			gd.PackedFloat32Array_resize(&multi.buf, new_cap * multi.stride)
			gd.MultiMesh_set_instance_count(multi.mm, new_cap)
			multi.cap = new_cap
		}
		if multi.cap == 0 do continue
		multi.ptr = ([^]f32)(gdi.packed_float32_array_operator_index(&multi.buf, 0))
		multi.low, multi.high, multi.reach = max(f32), min(f32), 0
		if multi.smooth do multi.decay = track_decay(dt, api.multi_policy[multi.kind].smoothing)
		next[i] = first[multi.kind]
		first[multi.kind] = i32(i)
	}
	for &item in frame.multis[:frame.n_multis] {
		view_index := first[item.kind]
		if view_index < 0 do continue
		pos := item.pos
		rot := item.rot
		if item.has_prev {
			pos = lerp3(item.prev_pos, item.pos, alpha)
			rot = nlerp(item.prev_rot, item.rot, alpha) // the shorter arc
		}
		scale := item.scale == {} ? [3]f32{1, 1, 1} : item.scale
		for ; view_index >= 0; view_index = next[view_index] {
			multi := &V.multis[view_index]
			view_pos, view_rot := pos, rot
			if multi.smooth && item.key != 0 {
				view_pos, view_rot = multi_smooth(multi, &item, frame.tick, fresh, alpha, dt)
			}
			view_pos = to_view(view_pos) // the origin only: the mesh is the view's content, `scale` a multiplier
			if multi.is_2d do view_pos.z = 0
			for axis in 0 ..< 3 {
				multi.low[axis] = min(multi.low[axis], view_pos[axis])
				multi.high[axis] = max(multi.high[axis], view_pos[axis])
			}
			multi.reach = max(multi.reach, abs(scale.x), abs(scale.y), abs(scale.z))
			out := multi.ptr[cursor[view_index] * multi.stride:]
			cursor[view_index] += 1
			basis := quat_basis(view_rot)
			offset: int
			if multi.is_2d {
				// Transform2D rows: the rotation about Z (the quaternion's upper-left 2x2), local axes scaled
				out[0], out[1], out[2], out[3] = basis[0][0] * scale.x, basis[0][1] * scale.y, 0, view_pos.x
				out[4], out[5], out[6], out[7] = basis[1][0] * scale.x, basis[1][1] * scale.y, 0, view_pos.y
				offset = 8
			} else {
				// Transform3D rows: the rotation, local axes (columns) scaled by scale
				for row in 0 ..< 3 {
					out[row * 4 + 0] = basis[row][0] * scale.x
					out[row * 4 + 1] = basis[row][1] * scale.y
					out[row * 4 + 2] = basis[row][2] * scale.z
				}
				out[3], out[7], out[11] = view_pos.x, view_pos.y, view_pos.z
				offset = 12
			}
			if multi.has_col {
				color := item.color == {} ? [4]f32{1, 1, 1, 1} : item.color
				out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = color[0], color[1], color[2], color[3]
				offset += 4
			}
			if multi.has_custom do out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = item.custom[0], item.custom[1], item.custom[2], item.custom[3]
		}
	}
	for &multi, i in V.multis do multi.count = cursor[i]
}

// Hands each MultiMesh view's buffer and bounds to Godot and forgets the smooth keys the frame no longer has.
multi_upload :: proc(fresh: bool) {
	for &multi in V.multis {
		if !multi.live || multi.cap == 0 do continue
		if multi.count > 0 {
			// the bounds first: without a custom_aabb, set_buffer transforms the mesh's AABB by every instance
			if multi.bounds do gd.MultiMesh_set_custom_aabb(multi.mm, multi_bounds(&multi))
			gd.MultiMesh_set_buffer(multi.mm, multi.buf)
		}
		gd.MultiMesh_set_visible_instance_count(multi.mm, multi.count)
		if multi.smooth && fresh {
			// forget the keys this frame no longer has
			gone := make([dynamic]u64, context.temp_allocator)
			for key, track in multi.tracks do if track.seen != V.fresh_count do append(&gone, key)
			for key in gone do delete_key(&multi.tracks, key)
		}
	}
}

// Bounds holding every instance written this frame: their origins, grown by the mesh's farthest point from its own
// origin times the largest scale factor (a rotation can turn it any way). Looser than the exact union, never
// smaller; Godot culls the whole MultiMesh by it.
multi_bounds :: proc(multi: ^Multi_View) -> gd.AABB {
	mesh := gd.MultiMesh_get_mesh(multi.mm)
	if mesh.ptr != multi.mesh { 	// measured once per mesh
		multi.mesh, multi.mesh_reach = mesh.ptr, 0
		if mesh.ptr != nil {
			box := gd.Mesh_get_aabb(mesh)
			lo := [3]f32{box.position.x, box.position.y, box.position.z}
			hi := lo + {box.size.x, box.size.y, box.size.z}
			far: [3]f32 // per axis, the face farther from the origin
			for axis in 0 ..< 3 do far[axis] = max(abs(lo[axis]), abs(hi[axis]))
			multi.mesh_reach = math.sqrt(far.x * far.x + far.y * far.y + far.z * far.z)
		}
	}
	gd.unref(mesh)
	grow := multi.mesh_reach * multi.reach
	low, high := multi.low - grow, multi.high + grow
	return {position = {low.x, low.y, low.z}, size = {high.x - low.x, high.y - low.y, high.z - low.z}}
}

// A unit quaternion's rotation matrix, by rows.
quat_basis :: proc(q: [4]f32) -> (basis: [3][3]f32) {
	x, y, z, w := q.x, q.y, q.z, q.w
	basis[0] = {1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)}
	basis[1] = {2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)}
	basis[2] = {2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)}
	return
}

// A smooth view's instance: its own Track by key, so a rollback correction glides like a scene view's (with its
// kind's smoothing).
multi_smooth :: proc(
	multi: ^Multi_View,
	item: ^Multi_Out,
	tick: u32,
	fresh: bool,
	alpha: f32,
	dt: f32,
) -> (
	pos: [3]f32,
	rot: [4]f32,
) {
	smoothing := api.multi_policy[multi.kind].smoothing
	entry, found := &multi.tracks[item.key]
	if !found {
		multi.tracks[item.key] = {
			warp = item.warp,
		}
		entry = &multi.tracks[item.key]
	}
	if fresh && entry.seen != V.fresh_count {
		entry.seen = V.fresh_count
		track_warp(&entry.track, &entry.warp, item.warp) // teleported: snaps
		track_push_prev(&entry.track, tick, {item.prev_pos, item.prev_rot}, item.has_prev, smoothing)
		track_push(&entry.track, tick, {item.pos, item.rot}, smoothing)
	}
	pose := track_sample_decayed(&entry.track, tick, alpha, multi.decay, dt, smoothing)
	return pose.pos, pose.rot
}
