// Views (src/godot/SPEC.md): scene views spawned per spawn key under the session's view_root from the scene the view
// index maps their kind to, interpolated and smoothed with unified:view; and MultiMesh views whose buffers are
// written natively. A scene view's scene holds a UnifiedView marker as a direct child of its root; a MultiMesh view
// is a MultiMeshInstance3D / 2D holding a UnifiedMultiView marker. The root's class picks how it is shown: a
// Node3D gets position and quaternion, a Node2D position and rotation, anything else (a Control HUD) only data.
package godot

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"
import "unified:view"

LINGER_S :: 0.25 // a despawned scene view stays this long (exit animation, or a rollback brings it back)
INDEX_PATH :: "res://unified_index.tres" // the view index `uni bake` writes (metadata `views`: kind -> scene path)

@(private)
Root_Mode :: enum u8 {
	Node3D,
	Node2D,
	Other, // data only: no pose, no _sim_update
}

@(private)
Scene_View :: struct {
	node:       gd.Node, // the scene's root
	mode:       Root_Mode,
	id:         u64,
	marker:     gd.Node, // its UnifiedView (nil: the scene has none)
	marker_id:  u64,
	kind:       u8,
	player:     i8,
	entity:     u64,
	track:      view.Track,
	has_update: bool,
	has_event:  bool,
	data:       []u8, // the data last set as properties
}

// One field of a view's data type, set as the view's property of the same name.
@(private)
Data_Field :: struct {
	name:   ^gd.StringName,
	text:   string,
	offset: int,
	conv:   enum u8 {
		Bool,
		Int,
		Uint,
		F32,
		Vec2,
		Vec3,
		Color,
	},
	size:   int, // Int/Uint: bytes
}

// A MultiMesh view: a MultiMeshInstance3D / 2D and its UnifiedMultiView marker.
@(private)
Multi_View :: struct {
	marker:     gd.Node,
	marker_id:  u64,
	node:       gd.Node, // the marker's parent
	id:         u64,
	kind:       int, // index into api.multi_names, -1: unknown
	smooth:     bool,
	mm:         gd.Ref(gd.MultiMesh),
	buf:        gd.PackedFloat32Array,
	cap:        int,
	stride:     int,
	is_2d:      bool, // transform_format TRANSFORM_2D: 8 floats per transform, else 12
	has_col:    bool,
	has_custom: bool,
	ptr:        [^]f32,
	tracks:     map[u64]Multi_Track, // smooth: by key
}

@(private)
Multi_Track :: struct {
	track: view.Track,
	seen:  int, // the fresh frame that last had this key
}

@(private)
V: struct {
	set:         view.View_Set(^Scene_View),
	scenes:      map[u8]gd.Ref(gd.PackedScene),
	missing:     map[u8]bool, // kinds whose scene failed to load (reported once)
	index:       map[string]string, // the view index: kind name -> scene path
	index_read:  bool,
	multis:      [dynamic]Multi_View,
	frame:       int,
	fresh_count: int,
	clock:       time.Tick,
	fields:      map[typeid][]Data_Field, // per data type, built on first use
	reported:    map[string]bool, // warnings and errors given once per process
}

// ---- the marker classes

Unified_View_Node :: struct {
	using hdr: gd.Instance_Header,
	kind:      string,
	entity:    i64,
	player:    i64,
}

Unified_Multi_View_Node :: struct {
	using hdr: gd.Instance_Header,
	kind:      string,
	smooth:    bool,
}

@(private)
unified_view_class, unified_multi_view_class: gd.Class

register_classes :: proc() {
	register_session_class()
	register_sim_classes()
	unified_view_class = {
		name = "UnifiedView",
		parent = "Node",
		size = size_of(Unified_View_Node),
		init = proc(instance: rawptr) {(^Unified_View_Node)(instance).player = -1},
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
	)
	gd.bind_property(
		class,
		"entity",
		proc(node: ^Unified_View_Node) -> i64 {return node.entity},
		proc(node: ^Unified_View_Node, entity: i64) {node.entity = entity},
	)
	gd.bind_property(
		class,
		"player",
		proc(node: ^Unified_View_Node) -> i64 {return node.player},
		proc(node: ^Unified_View_Node, player: i64) {node.player = player},
	)
	gd.bind_signal(class, "despawned")
	gd.bind_signal(class, "revived")
	unified_multi_view_class = {
		name = "UnifiedMultiView",
		parent = "Node",
		size = size_of(Unified_Multi_View_Node),
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
	)
	gd.bind_property(
		class,
		"smooth",
		proc(node: ^Unified_Multi_View_Node) -> bool {return node.smooth},
		proc(node: ^Unified_Multi_View_Node, smooth: bool) {node.smooth = smooth},
	)
}

unregister_classes :: proc() {
	gd.unregister_class(&unified_multi_view_class)
	gd.unregister_class(&unified_view_class)
	unregister_sim_classes()
	gd.unregister_class(&session_class)
}

@(private)
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

@(private)
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

@(private)
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
@(private)
find_marker :: proc(root: gd.Node, class: string) -> gd.Node {
	for i in 0 ..< gd.Node_get_child_count(root, false) {
		child := gd.Node_get_child(root, i, false)
		if marker := gd.object_cast(gd.Node, child, class); marker.ptr != nil do return marker
	}
	return {}
}

@(private)
spawn_view :: proc(root: gd.Node, item: ^View_Out, frame: ^Frame_Data) -> ^Scene_View {
	packed_scene, ok := scene_for(item.kind)
	if !ok do return nil
	node := gd.PackedScene_instantiate(packed_scene, .GEN_EDIT_STATE_DISABLED)
	if node.ptr == nil do return nil
	scene_view := new(Scene_View)
	scene_view.node = node
	switch {
	case gd.object_cast(gd.Node3D, node, "Node3D").ptr != nil:
		scene_view.mode = .Node3D
	case gd.object_cast(gd.Node2D, node, "Node2D").ptr != nil:
		scene_view.mode = .Node2D
	case:
		scene_view.mode = .Other
	}
	kind := api.view_names[item.kind]
	scene_view.id = gdi.object_get_instance_id(node.ptr)
	scene_view.kind, scene_view.player, scene_view.entity = item.kind, item.player, item.entity
	scene_view.marker = find_marker(node, "UnifiedView")
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
		marker := (^Unified_View_Node)(gd.instance_of(scene_view.marker))
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
		marker.entity, marker.player = i64(item.entity), i64(item.player)
	}
	scene_view.has_update = scene_view.mode != .Other && gd.has_script_method(node, gd.sn("_sim_update"))
	scene_view.has_event = gd.has_script_method(node, gd.sn("_sim_event"))
	set_pose(scene_view, {item.pos, item.rot})
	gd.Node_add_child(root, node, false, .INTERNAL_MODE_DISABLED)
	// data after _ready: a script's property setters may use its @onready nodes
	if scene_view.mode == .Node2D && api.smoothing == view.SMOOTHING_DEFAULT {
		report_once(
			"smoothing",
			"unified: 2D scene views with the default smoothing (metres): set Glue.smoothing in the units fill_frame writes, e.g. {tau_s = 0.1, teleport_dist = 64} for pixels",
			false,
		)
	}
	if item.data_type != nil {
		fields := data_fields(item.data_type)
		for &field in fields {
			property := gd.Object_get(node, field.name)
			if gd.variant_type(&property) == .NIL {
				report_once(
					fmt.tprintf("prop:%s:%s", kind, field.text),
					fmt.tprintf(
						"unified: scene view %q has no property %q for its data (%v)",
						kind,
						field.text,
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

// 3D: position and quaternion. 2D: position = pos.xy, rotation = the angle about Z. Other roots: nothing.
@(private)
set_pose :: proc(scene_view: ^Scene_View, pose: view.Pose) {
	switch scene_view.mode {
	case .Node2D:
		node2d := gd.cast_to(gd.Node2D, scene_view.node)
		gd.Node2D_set_position(node2d, {pose.pos.x, pose.pos.y})
		gd.Node2D_set_rotation(node2d, view.angle2d_of(pose.rot))
	case .Node3D:
		node3d := gd.cast_to(gd.Node3D, scene_view.node)
		gd.Node3D_set_position(node3d, {pose.pos.x, pose.pos.y, pose.pos.z})
		gd.Node3D_set_quaternion(node3d, {pose.rot.x, pose.rot.y, pose.rot.z, pose.rot.w})
	case .Other:
	}
}

// The fields of a view data type, built once; an unsupported field type is an error reported once, and the field
// is left out.
@(private)
data_fields :: proc(data_type: typeid) -> []Data_Field {
	if fields, ok := V.fields[data_type]; ok do return fields
	out := make([dynamic]Data_Field)
	type := runtime.type_info_base(type_info_of(data_type))
	struct_info, is_struct := type.variant.(runtime.Type_Info_Struct)
	if !is_struct {
		gd.print_error(fmt.tprintf("unified: view data %v must be a struct", data_type))
	} else {
		for i in 0 ..< int(struct_info.field_count) {
			name := struct_info.names[i]
			if strings.has_prefix(name, "_") do continue // padding
			field_type := runtime.type_info_base(struct_info.types[i])
			field := Data_Field {
				name   = gd.sn(name),
				text   = name,
				offset = int(struct_info.offsets[i]),
				size   = field_type.size,
			}
			ok := true
			#partial switch info in field_type.variant {
			case runtime.Type_Info_Boolean:
				field.conv = .Bool
			case runtime.Type_Info_Integer:
				field.conv = info.signed ? .Int : .Uint
			case runtime.Type_Info_Enum:
				backing := runtime.type_info_base(info.base)
				field.conv = backing.variant.(runtime.Type_Info_Integer).signed ? .Int : .Uint
			case runtime.Type_Info_Float:
				ok = field_type.size == 4
				field.conv = .F32
			case runtime.Type_Info_Array:
				ok = info.elem.id == f32 && info.count >= 2 && info.count <= 4
				field.conv = info.count == 2 ? .Vec2 : info.count == 3 ? .Vec3 : .Color
			case:
				ok = false
			}
			if !ok {
				gd.print_error(
					fmt.tprintf(
						"unified: view data %v: field %q has an unsupported type %v",
						data_type,
						name,
						struct_info.types[i].id,
					),
				)
				continue
			}
			append(&out, field)
		}
	}
	V.fields[data_type] = out[:]
	return out[:]
}

// Sets every data field whose bytes changed (all of them on a fresh view) as a property.
@(private)
set_data :: proc(scene_view: ^Scene_View, fields: []Data_Field, data: []u8, fresh: bool) {
	fresh := fresh
	if len(scene_view.data) != len(data) {
		delete(scene_view.data)
		scene_view.data = make([]u8, len(data))
		fresh = true
	}
	for &field in fields {
		bytes := data[field.offset:][:field.size if field.conv < .F32 else field_bytes(field.conv)]
		if !fresh && string(bytes) == string(scene_view.data[field.offset:][:len(bytes)]) do continue
		raw := raw_data(bytes)
		value: gd.Variant
		switch field.conv {
		case .Bool:
			value = gd.to_variant(raw[0] != 0)
		case .Int:
			switch field.size {
			case 1:
				value = gd.to_variant(i64((^i8)(raw)^))
			case 2:
				value = gd.to_variant(i64((^i16le)(raw)^))
			case 4:
				value = gd.to_variant(i64((^i32le)(raw)^))
			case:
				value = gd.to_variant(i64((^i64le)(raw)^))
			}
		case .Uint:
			switch field.size {
			case 1:
				value = gd.to_variant(i64(raw[0]))
			case 2:
				value = gd.to_variant(i64((^u16le)(raw)^))
			case 4:
				value = gd.to_variant(i64((^u32le)(raw)^))
			case:
				value = gd.to_variant(i64((^u64le)(raw)^))
			}
		case .F32:
			value = gd.to_variant((^f32)(raw)^)
		case .Vec2:
			vector := (^[2]f32)(raw)^
			value = gd.to_variant(gd.Vector2{vector.x, vector.y})
		case .Vec3:
			vector := (^[3]f32)(raw)^
			value = gd.to_variant(gd.Vector3{vector.x, vector.y, vector.z})
		case .Color:
			color := (^[4]f32)(raw)^
			value = gd.to_variant(gd.Color{color[0], color[1], color[2], color[3]})
		}
		set_prop(scene_view.node, field.name, value)
	}
	copy(scene_view.data, data)
}

@(private)
field_bytes :: proc(conv: type_of(Data_Field{}.conv)) -> int {
	#partial switch conv {
	case .F32:
		return 4
	case .Vec2:
		return 8
	case .Vec3:
		return 12
	}
	return 16
}

@(private)
set_prop :: proc(object: gd.Object, name: ^gd.StringName, value: gd.Variant) {
	value := value
	gd.Object_set(object, name, value)
	gd.variant_destroy(&value)
}

@(private)
free_view :: proc(scene_view: ^Scene_View) {
	if scene_view == nil do return
	if alive(scene_view.id) do gd.Node_queue_free(scene_view.node)
	delete(scene_view.data)
	free(scene_view)
}

@(private)
marker_signal :: proc(scene_view: ^Scene_View, signal: string) {
	if scene_view == nil || !alive(scene_view.marker_id) do return
	gd.emit_signal(scene_view.marker, gd.sn(signal))
}

views_clear :: proc() {
	for _, entry in V.set.entries do free_view(entry.view)
	view.set_destroy(&V.set)
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
	V.fields = nil
	for kind, path in V.index {
		delete(kind)
		delete(path)
	}
	delete(V.index)
	V.index, V.index_read = nil, false
}

// The game set or cleared view_root: drop every scene view (they lived under the old root).
views_root_changed :: proc() {
	for _, entry in V.set.entries do free_view(entry.view)
	clear(&V.set.entries)
}

views_sync :: proc(root: gd.Node, frame: ^Frame_Data, fresh: bool, alpha: f32, dt: f32) {
	V.frame += 1
	if root.ptr == nil {
		if len(V.set.entries) > 0 do views_root_changed()
	} else {
		scene_sync(root, frame, fresh, alpha, dt)
	}
	multi_sync(frame, fresh, alpha, dt)
}

@(private)
scene_sync :: proc(root: gd.Node, frame: ^Frame_Data, fresh: bool, alpha: f32, dt: f32) {
	if V.clock == {} do V.clock = time.tick_now()
	now_s := time.duration_seconds(time.tick_since(V.clock))
	if fresh {
		if frame.dropped > 0 {
			report_once(
				"dropped",
				fmt.tprintf(
					"unified: a frame had more items than it holds (%d dropped; raise Glue.max_views, max_multi or view_data_bytes)",
					frame.dropped,
				),
				false,
			)
		}
		view.set_begin(&V.set)
		for &item in frame.views[:frame.n_views] {
			old := view.set_get(&V.set, item.key)
			revived := old != nil && old.phase == .Lingering
			entry, spawned := view.set_see(&V.set, item.key)
			if spawned do entry.view = spawn_view(root, &item, frame)
			scene_view := entry.view
			if scene_view == nil do continue
			if revived do marker_signal(scene_view, "revived") // a rollback brought it back during its linger
			scene_view.entity, scene_view.player = item.entity, item.player
			if !spawned && alive(scene_view.id) && item.data_type != nil {
				set_data(
					scene_view,
					data_fields(item.data_type),
					frame.data[item.data_offset:][:item.data_size],
					false,
				)
			}
			if scene_view.mode == .Other do continue
			if item.has_prev do view.track_push(&scene_view.track, frame.tick - 1, {item.prev_pos, item.prev_rot}, api.smoothing)
			view.track_push(&scene_view.track, frame.tick, {item.pos, item.rot}, api.smoothing)
		}
		view.set_end(&V.set, now_s, LINGER_S)
		for key in V.set.despawned {
			if entry := view.set_get(&V.set, key); entry != nil do marker_signal(entry.view, "despawned")
		}
		for scene_view in V.set.removed do free_view(scene_view)
	}
	for _, &entry in V.set.entries {
		scene_view := entry.view
		if scene_view == nil || scene_view.mode == .Other || !alive(scene_view.id) do continue
		pose := view.track_sample(&scene_view.track, frame.tick, alpha, dt, api.smoothing)
		set_pose(scene_view, pose)
		if !scene_view.has_update do continue
		result: gd.Variant
		if scene_view.mode == .Node2D {
			pos := gd.Vector2{pose.pos.x, pose.pos.y}
			result = gd.call_script(
				scene_view.node,
				gd.sn("_sim_update"),
				pos,
				f64(view.angle2d_of(pose.rot)),
				f64(alpha),
			)
		} else {
			pos := gd.Vector3{pose.pos.x, pose.pos.y, pose.pos.z}
			result = gd.call_script(scene_view.node, gd.sn("_sim_update"), pos, f64(view.yaw_of(pose.rot)), f64(alpha))
		}
		gd.variant_destroy(&result)
	}
}

// An event to its subject's scene view (_sim_event(event, state) on the root's script): with Glue.event_key, the
// view it names; else the view keyed by the event's handle field, else the views whose entity is the event's
// `entity` field, else its player's views.
views_event :: proc(layout: ^Event_Layout, raw: ^sim.Raw_Event, state: i64, event: gd.Variant) {
	key := view.Key(0)
	if api.event_key != nil {
		key = api.event_key(raw)
		if key == 0 do return
	}
	player, entity := event_subject(layout, raw.data[:raw.size])
	if api.event_key == nil && layout.subject_is_handle && entity != 0 {
		if entry := view.set_get(&V.set, view.Key(entity)); entry != nil && entry.view != nil do key = view.Key(entity)
	}
	by_entity := layout.subject >= 0 && !layout.subject_is_handle && entity != 0
	for entry_key, &entry in V.set.entries {
		scene_view := entry.view
		if scene_view == nil || !scene_view.has_event || !alive(scene_view.id) do continue
		match: bool
		switch {
		case key != 0:
			match = entry_key == key
		case by_entity:
			match = scene_view.entity == entity
		case player != u32(sim.NO_PLAYER):
			match = scene_view.player >= 0 && u32(scene_view.player) == player
		}
		if !match do continue
		result := gd.call_script(scene_view.node, gd.sn("_sim_event"), event, state)
		gd.variant_destroy(&result)
	}
}

// ---- MultiMesh views

// A UnifiedMultiView entered the tree: its parent is the MultiMeshInstance it fills.
@(private)
multi_register :: proc(marker: gd.Node, node: ^Unified_Multi_View_Node) {
	if is_editor() do return
	marker_id := gdi.object_get_instance_id(marker.ptr)
	for multi in V.multis do if multi.marker_id == marker_id do return
	parent := gd.Node_get_parent(marker)
	instance: gd.Node
	is_2d := false
	if instance3d := gd.object_cast(gd.MultiMeshInstance3D, parent, "MultiMeshInstance3D"); instance3d.ptr != nil {
		instance = instance3d
	} else if instance2d := gd.object_cast(gd.MultiMeshInstance2D, parent, "MultiMeshInstance2D");
	   instance2d.ptr != nil {
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
				"unified: a UnifiedMultiView has kind %q, which is not a member of the game's Multi enum",
				node.kind,
			),
		)
	}
	append(
		&V.multis,
		Multi_View {
			marker = marker,
			marker_id = marker_id,
			node = instance,
			id = gdi.object_get_instance_id(instance.ptr),
			kind = kind,
			smooth = node.smooth,
			is_2d = is_2d,
		},
	)
}

@(private)
multi_unregister :: proc(marker_id: u64) {
	for i := len(V.multis) - 1; i >= 0; i -= 1 {
		if V.multis[i].marker_id != marker_id do continue
		multi_drop(&V.multis[i])
		ordered_remove(&V.multis, i)
	}
}

@(private)
multi_drop :: proc(multi: ^Multi_View) {
	if multi.mm.ptr != nil do gd.unref(multi.mm)
	if multi.cap > 0 do gd.PackedFloat32Array_destroy(&multi.buf)
	delete(multi.tracks)
	multi^ = {}
}

// The view's MultiMesh, taken when it first has one; the buffer layout follows its own format.
@(private)
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
	return true
}

// One pass over the frame's MultiMesh items: counted per kind, then each written into the buffer of every view of
// its kind (usually one).
@(private)
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
		if multi.kind < 0 || !alive(multi.id) || !multi_mesh(multi) do continue
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
		next[i] = first[multi.kind]
		first[multi.kind] = i32(i)
	}
	for &item in frame.multis[:frame.n_multis] {
		view_index := first[item.kind]
		if view_index < 0 do continue
		pos := item.pos
		yaw := item.yaw
		if item.has_prev {
			pos = view.lerp3(item.prev_pos, item.pos, alpha)
			turn := item.yaw - item.prev_yaw
			turn -= math.TAU * math.round(turn / math.TAU) // the shorter arc
			yaw = item.prev_yaw + turn * alpha
		}
		scale := item.scale == {} ? [3]f32{1, 1, 1} : item.scale
		for ; view_index >= 0; view_index = next[view_index] {
			multi := &V.multis[view_index]
			view_pos, view_yaw := pos, yaw
			if multi.smooth && item.key != 0 {
				view_pos, view_yaw = multi_smooth(multi, &item, frame.tick, fresh, alpha, dt)
			}
			out := multi.ptr[cursor[view_index] * multi.stride:]
			cursor[view_index] += 1
			cos_yaw, sin_yaw := math.cos(view_yaw), math.sin(view_yaw)
			offset: int
			if multi.is_2d {
				// Transform2D rows (x axis = (cos, sin)·sx, y axis = (-sin, cos)·sy): rotation about Z, scale per axis
				out[0], out[1], out[2], out[3] = cos_yaw * scale.x, -sin_yaw * scale.y, 0, view_pos.x
				out[4], out[5], out[6], out[7] = sin_yaw * scale.x, cos_yaw * scale.y, 0, view_pos.y
				offset = 8
			} else {
				// Transform3D rows (yaw about +Y; local axes scaled by scale)
				out[0], out[1], out[2], out[3] = cos_yaw * scale.x, 0, sin_yaw * scale.z, view_pos.x
				out[4], out[5], out[6], out[7] = 0, scale.y, 0, view_pos.y
				out[8], out[9], out[10], out[11] = -sin_yaw * scale.x, 0, cos_yaw * scale.z, view_pos.z
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
	for &multi, i in V.multis {
		if multi.kind < 0 || !alive(multi.id) || multi.cap == 0 do continue
		gd.MultiMesh_set_buffer(multi.mm, multi.buf)
		gd.MultiMesh_set_visible_instance_count(multi.mm, cursor[i])
		if multi.smooth && fresh {
			// forget the keys this frame no longer has
			gone := make([dynamic]u64, context.temp_allocator)
			for key, track in multi.tracks do if track.seen != V.fresh_count do append(&gone, key)
			for key in gone do delete_key(&multi.tracks, key)
		}
	}
}

// A smooth view's instance: its own Track by key, so a rollback correction glides like a scene view's.
@(private)
multi_smooth :: proc(
	multi: ^Multi_View,
	item: ^Multi_Out,
	tick: u32,
	fresh: bool,
	alpha: f32,
	dt: f32,
) -> (
	pos: [3]f32,
	yaw: f32,
) {
	entry, found := &multi.tracks[item.key]
	if !found {
		multi.tracks[item.key] = {}
		entry = &multi.tracks[item.key]
	}
	quat :: proc(is_2d: bool, angle: f32) -> [4]f32 {return is_2d ? view.quat_angle2d(angle) : view.quat_yaw(angle)}
	if fresh && entry.seen != V.fresh_count {
		entry.seen = V.fresh_count
		if item.has_prev do view.track_push(&entry.track, tick - 1, {item.prev_pos, quat(multi.is_2d, item.prev_yaw)}, api.smoothing)
		view.track_push(&entry.track, tick, {item.pos, quat(multi.is_2d, item.yaw)}, api.smoothing)
	}
	pose := view.track_sample(&entry.track, tick, alpha, dt, api.smoothing)
	angle := multi.is_2d ? view.angle2d_of(pose.rot) : view.yaw_of(pose.rot)
	return pose.pos, angle
}
