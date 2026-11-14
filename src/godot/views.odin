// Views: scene views spawned per spawn key under the session's view_root, interpolated and smoothed with
// unified:view, and MultiMesh bulk views whose buffers are written natively. 3D and 2D share it all: the game's
// scenes may use the typed SimView / SimView2D / SimBulkView / SimBulkView2D roots or plain Node3D / Node2D /
// MultiMeshInstance3D / MultiMeshInstance2D nodes with script properties (kind, entity, player): the host talks
// to both through Object.set/call. A scene root's class (Node3D or Node2D) picks the 3D or 2D mapping.
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
BULK_GROUP :: "sim_bulk"

@(private)
Scene_View :: struct {
	node:       gd.Node, // a Node3D, or a Node2D when is_2d
	is_2d:      bool,
	id:         u64,
	kind:       u8,
	player:     i8,
	entity:     u64,
	track:      view.Track,
	has_update: bool,
	has_event:  bool,
	data:       [SCENE_DATA_BYTES]u8, // the data last set as properties (Scene_Kind.data)
}

// One field of a kind's data type, set as the view's property of the same name.
@(private)
Data_Field :: struct {
	name:   ^gd.StringName,
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

@(private)
Bulk_View :: struct {
	node:                gd.Node, // a MultiMeshInstance3D or MultiMeshInstance2D
	id:                  u64,
	kind:                int, // index into api.bulk_kinds, -1: unknown
	mm:                  gd.Ref(gd.MultiMesh),
	buf:                 gd.PackedFloat32Array,
	cap:                 int,
	stride:              int,
	is_2d:               bool, // transform_format TRANSFORM_2D: 8 floats per transform, else 12
	// per frame (bulk_sync)
	has_col, has_custom: bool,
	ptr:                 [^]f32,
}

@(private)
V: struct {
	set:        view.View_Set(^Scene_View),
	scenes:     map[u8]gd.Ref(gd.PackedScene),
	missing:    map[u8]bool, // kinds whose scene failed to load (reported once)
	bulks:      [dynamic]Bulk_View,
	scan_frame: int,
	frame:      int,
	clock:      time.Tick,
	root_id:    u64,
	fields:     map[u8][]Data_Field, // per scene kind with data, built on first use
	warned:     map[string]bool, // warnings given once per process
}

// ---- typed view classes

Sim_View_Node :: struct {
	using hdr: gd.Instance_Header,
	kind:      gd.StringName,
	entity:    i64,
	player:    i64,
}

Sim_Bulk_Node :: struct {
	using hdr: gd.Instance_Header,
	kind:      gd.StringName,
}

@(private)
sim_view_class, sim_view2d_class, sim_bulk_class, sim_bulk2d_class: gd.Class

register_classes :: proc() {
	register_session_class()
	register_view_class(&sim_view_class, "SimView", "Node3D", gd.Vector3, "yaw")
	register_view_class(&sim_view2d_class, "SimView2D", "Node2D", gd.Vector2, "rotation")
	register_bulk_class(&sim_bulk_class, "SimBulkView", "MultiMeshInstance3D")
	register_bulk_class(&sim_bulk2d_class, "SimBulkView2D", "MultiMeshInstance2D")
}

// SimView / SimView2D: kind, entity, player and the script virtuals _sim_update(position, yaw | rotation, alpha)
// and _sim_event(event, state, data).
@(private)
register_view_class :: proc(class: ^gd.Class, name, parent: string, position_type: typeid, angle_name: string) {
	class^ = {
		name = name,
		parent = parent,
		size = size_of(Sim_View_Node),
		init = proc(instance: rawptr) {(^Sim_View_Node)(instance).player = -1},
		fini = proc(instance: rawptr) {gd.StringName_destroy(&(^Sim_View_Node)(instance).kind)},
	}
	gd.register_class(class)
	gd.bind_property(
		class,
		"kind",
		proc(node: ^Sim_View_Node) -> string {return gd.string_name_to_odin(&node.kind)},
		proc(node: ^Sim_View_Node, kind: string) {
			gd.StringName_destroy(&node.kind)
			node.kind = gd.string_name_from(kind)
		},
	)
	gd.bind_property(
		class,
		"entity",
		proc(node: ^Sim_View_Node) -> i64 {return node.entity},
		proc(node: ^Sim_View_Node, entity: i64) {node.entity = entity},
	)
	gd.bind_property(
		class,
		"player",
		proc(node: ^Sim_View_Node) -> i64 {return node.player},
		proc(node: ^Sim_View_Node, player: i64) {node.player = player},
	)
	gd.bind_script_virtual(class, "_sim_update", {"position", position_type}, {angle_name, f64}, {"alpha", f64})
	gd.bind_script_virtual(class, "_sim_event", {"event", gd.StringName}, {"state", i64}, {"data", gd.Dictionary})
}

// SimBulkView / SimBulkView2D: `kind`, and the node joins the `sim_bulk` group when it enters the tree.
@(private)
register_bulk_class :: proc(class: ^gd.Class, name, parent: string) {
	class^ = {
		name = name,
		parent = parent,
		size = size_of(Sim_Bulk_Node),
		fini = proc(instance: rawptr) {gd.StringName_destroy(&(^Sim_Bulk_Node)(instance).kind)},
		notification = proc(instance: rawptr, what: i32) {
			if what == gd.Node_NOTIFICATION_ENTER_TREE {
				gd.Node_add_to_group(gd.cast_to(gd.Node, (^Sim_Bulk_Node)(instance).obj), gd.sn(BULK_GROUP), false)
			}
		},
	}
	gd.register_class(class)
	gd.bind_property(
		class,
		"kind",
		proc(node: ^Sim_Bulk_Node) -> string {return gd.string_name_to_odin(&node.kind)},
		proc(node: ^Sim_Bulk_Node, kind: string) {
			gd.StringName_destroy(&node.kind)
			node.kind = gd.string_name_from(kind)
		},
	)
}

unregister_classes :: proc() {
	gd.unregister_class(&sim_bulk2d_class)
	gd.unregister_class(&sim_bulk_class)
	gd.unregister_class(&sim_view2d_class)
	gd.unregister_class(&sim_view_class)
	gd.unregister_class(&session_class)
}

// ---- scene views

@(private)
scene_for :: proc(kind: u8) -> (gd.PackedScene, bool) {
	if packed_scene, ok := V.scenes[kind]; ok do return packed_scene, true
	if V.missing[kind] do return {}, false
	name := int(kind) < len(api.scenes) ? api.scenes[kind].name : fmt.tprintf("kind%d", kind)
	path := fmt.tprintf("%s/%s.tscn", api.scene_dir, name)
	resource := gd.ResourceLoader_load(gd.ResourceLoader_singleton(), path, "", .CACHE_MODE_REUSE)
	if resource.ptr == nil {
		gd.print_error(fmt.tprintf("unified: cannot load %s", path))
		V.missing[kind] = true
		return {}, false
	}
	packed_scene := transmute(gd.Ref(gd.PackedScene))resource
	V.scenes[kind] = packed_scene
	return packed_scene, true
}

@(private)
spawn_view :: proc(root: gd.Node, item: ^Scene_Item) -> ^Scene_View {
	packed_scene, ok := scene_for(item.kind)
	if !ok do return nil
	node := gd.PackedScene_instantiate(packed_scene, .GEN_EDIT_STATE_DISABLED)
	if node.ptr == nil do return nil
	scene_view := new(Scene_View)
	if node3d := gd.object_cast(gd.Node3D, node, "Node3D"); node3d.ptr != nil {
		scene_view.node = node3d
	} else if node2d := gd.object_cast(gd.Node2D, node, "Node2D"); node2d.ptr != nil {
		scene_view.node, scene_view.is_2d = node2d, true
	} else {
		gd.print_error("unified: a view scene's root must be a Node3D or a Node2D")
		gdi.object_destroy(node.ptr)
		free(scene_view)
		return nil
	}
	view_node := scene_view.node
	scene_view.id = gdi.object_get_instance_id(view_node.ptr)
	scene_view.kind, scene_view.player, scene_view.entity = item.kind, item.player, item.entity
	kind := int(item.kind) < len(api.scenes) ? api.scenes[item.kind].name : ""
	set_prop(view_node, gd.sn("kind"), gd.variant_string_name(kind))
	set_prop(view_node, gd.sn("entity"), gd.to_variant(i64(item.entity)))
	set_prop(view_node, gd.sn("player"), gd.to_variant(i64(item.player)))
	scene_view.has_update = gd.has_script_method(view_node, gd.sn("_sim_update"))
	scene_view.has_event = gd.has_script_method(view_node, gd.sn("_sim_event"))
	set_pose(scene_view, {item.pos, quat_or_identity(item.rot)})
	gd.Node_add_child(root, view_node, false, .INTERNAL_MODE_DISABLED)
	// data after _ready: a script's property setters may use its @onready nodes
	if scene_view.is_2d && api.smoothing == view.SMOOTHING_DEFAULT {
		warn_once(
			"smoothing",
			"unified: 2D scene views with the default smoothing (metres): set Glue.smoothing in the units extract writes, e.g. {tau_s = 0.1, teleport_dist = 64} for pixels",
		)
	}
	fields := data_fields(item.kind)
	for &field in fields {
		property := gd.Object_get(view_node, field.name)
		if gd.variant_type(&property) == .NIL {
			warn_once(
				fmt.tprintf("prop:%s:%s", kind, gd.string_name_to_odin(field.name)),
				fmt.tprintf(
					"unified: scene view %q has no property %q for its data",
					kind,
					gd.string_name_to_odin(field.name),
				),
			)
		}
		gd.variant_destroy(&property)
	}
	set_data(scene_view, fields, &item.data)
	return scene_view
}

// 3D: position and quaternion. 2D: position = pos.xy, rotation = the angle about Z.
@(private)
set_pose :: proc(scene_view: ^Scene_View, pose: view.Pose) {
	if scene_view.is_2d {
		node2d := gd.cast_to(gd.Node2D, scene_view.node)
		gd.Node2D_set_position(node2d, {pose.pos.x, pose.pos.y})
		gd.Node2D_set_rotation(node2d, view.angle2d_of(pose.rot))
	} else {
		node3d := gd.cast_to(gd.Node3D, scene_view.node)
		gd.Node3D_set_position(node3d, {pose.pos.x, pose.pos.y, pose.pos.z})
		gd.Node3D_set_quaternion(node3d, {pose.rot.x, pose.rot.y, pose.rot.z, pose.rot.w})
	}
}

@(private)
warn_once :: proc(key, msg: string) {
	if V.warned[key] do return
	V.warned[strings.clone(key)] = true
	gd.print_warning(msg)
}

// The fields of a scene kind's data type (Scene_Kind.data), built once; an unsupported field type is an error
// reported once, and the field is left out.
@(private)
data_fields :: proc(kind: u8) -> []Data_Field {
	if int(kind) >= len(api.scenes) || api.scenes[kind].data == nil do return nil
	if fields, ok := V.fields[kind]; ok do return fields
	data_type := api.scenes[kind].data
	out := make([dynamic]Data_Field)
	type := runtime.type_info_base(type_info_of(data_type))
	struct_info, is_struct := type.variant.(runtime.Type_Info_Struct)
	if !is_struct || type.size > SCENE_DATA_BYTES {
		gd.print_error(
			fmt.tprintf(
				"unified: scene kind %q: data %v must be a struct of at most %d bytes",
				api.scenes[kind].name,
				data_type,
				SCENE_DATA_BYTES,
			),
		)
	} else {
		for i in 0 ..< int(struct_info.field_count) {
			name := struct_info.names[i]
			field_type := runtime.type_info_base(struct_info.types[i])
			field := Data_Field {
				name   = gd.sn(name),
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
			if name == "_" || strings.has_prefix(name, "_") do continue // padding
			if !ok {
				gd.print_error(
					fmt.tprintf(
						"unified: scene kind %q: data field %q has an unsupported type %v",
						api.scenes[kind].name,
						name,
						struct_info.types[i].id,
					),
				)
				continue
			}
			append(&out, field)
		}
	}
	V.fields[kind] = out[:]
	return out[:]
}

// Sets every data field whose bytes changed (all of them on a fresh view) as a property.
@(private)
set_data :: proc(scene_view: ^Scene_View, fields: []Data_Field, data: ^[SCENE_DATA_BYTES]u8, fresh := true) {
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
	scene_view.data = data^
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
quat_or_identity :: proc(rot: [4]f32) -> [4]f32 {
	return rot == {} ? view.IDENTITY : rot
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
	free(scene_view)
}

views_clear :: proc() {
	for _, entry in V.set.entries do free_view(entry.view)
	view.set_destroy(&V.set)
	V.set = {}
	for &bulk in V.bulks do bulk_drop(&bulk)
	delete(V.bulks)
	V.bulks = nil
	for _, packed_scene in V.scenes do gd.unref(packed_scene)
	delete(V.scenes)
	delete(V.missing)
	V.scenes, V.missing = nil, nil
	for _, fields in V.fields do delete(fields)
	delete(V.fields)
	V.fields = nil
}

// The game set or cleared view_root: drop every view (they lived under the old root).
views_root_changed :: proc() {
	for _, entry in V.set.entries do free_view(entry.view)
	clear(&V.set.entries)
	for &bulk in V.bulks do bulk_drop(&bulk)
	clear(&V.bulks)
	V.scan_frame = 0
}

views_sync :: proc(root: gd.Node, frame: ^Frame, fresh: bool, alpha: f32, dt: f32) {
	V.frame += 1
	if root.ptr == nil {
		if len(V.set.entries) > 0 || len(V.bulks) > 0 do views_root_changed()
		return
	}
	if V.clock == {} do V.clock = time.tick_now()
	now_s := time.duration_seconds(time.tick_since(V.clock))
	if fresh {
		if frame.dropped > 0 {
			warn_once(
				"dropped",
				fmt.tprintf(
					"unified: a frame had more items than it holds (%d dropped; MAX_SCENE_ITEMS %d, MAX_BULK_ITEMS %d)",
					frame.dropped,
					MAX_SCENE_ITEMS,
					MAX_BULK_ITEMS,
				),
			)
		}
		view.set_begin(&V.set)
		for &item in frame.scene[:frame.n_scene] {
			old := view.set_get(&V.set, item.key)
			revived := old != nil && old.phase == .Lingering
			entry, spawned := view.set_see(&V.set, item.key)
			if spawned do entry.view = spawn_view(root, &item)
			scene_view := entry.view
			if scene_view == nil do continue
			if revived && scene_view.has_event && alive(scene_view.id) {
				// a rollback brought it back during its linger: undo the exit animation
				dict := gd.dict_new()
				result := gd.call_script(
					scene_view.node,
					gd.sn("_sim_event"),
					gd.sn("revived")^,
					i64(view.Event_Action.Emitted),
					dict,
				)
				gd.variant_destroy(&result)
				gd.Dictionary_destroy(&dict)
			}
			scene_view.entity, scene_view.player = item.entity, item.player
			if !spawned && alive(scene_view.id) do set_data(scene_view, data_fields(item.kind), &item.data, false)
			if item.has_prev {
				view.track_push(
					&scene_view.track,
					frame.tick - 1,
					{item.prev_pos, quat_or_identity(item.prev_rot)},
					api.smoothing,
				)
			}
			view.track_push(&scene_view.track, frame.tick, {item.pos, quat_or_identity(item.rot)}, api.smoothing)
		}
		view.set_end(&V.set, now_s, LINGER_S)
		for key in V.set.despawned {
			if entry := view.set_get(&V.set, key);
			   entry != nil && entry.view != nil && entry.view.has_event && alive(entry.view.id) {
				dict := gd.dict_new()
				result := gd.call_script(
					entry.view.node,
					gd.sn("_sim_event"),
					gd.sn("despawned")^,
					i64(view.Event_Action.Emitted),
					dict,
				)
				gd.variant_destroy(&result)
				gd.Dictionary_destroy(&dict)
			}
		}
		for scene_view in V.set.removed do free_view(scene_view)
	}
	for _, &entry in V.set.entries {
		scene_view := entry.view
		if scene_view == nil || !alive(scene_view.id) do continue
		pose := view.track_sample(&scene_view.track, frame.tick, alpha, dt, api.smoothing)
		set_pose(scene_view, pose)
		if !scene_view.has_update do continue
		result: gd.Variant
		if scene_view.is_2d {
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
	bulk_sync(root, frame, alpha)
}

// An event to its subject's scene view (_sim_event(event, state, data)): with Glue.event_key, the view it names; else the
// view keyed by the event's handle field (a view keyed by sim.handle_key), else the view whose Scene_Item.entity
// is the event's `entity` field, else its player's view (Scene_Item.player).
views_event :: proc(layout: ^Event_Layout, raw: ^sim.Raw_Event, state: i64, data: ^gd.Dictionary) {
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
		result := gd.call_script(scene_view.node, gd.sn("_sim_event"), gd.sn(layout.name)^, state, data^)
		gd.variant_destroy(&result)
	}
}

// ---- bulk views

@(private)
bulk_drop :: proc(bulk: ^Bulk_View) {
	if bulk.mm.ptr != nil do gd.unref(bulk.mm)
	if bulk.cap > 0 do gd.PackedFloat32Array_destroy(&bulk.buf)
	bulk^ = {}
}

@(private)
bulk_scan :: proc(root: gd.Node) {
	tree := gd.Node_get_tree(root)
	nodes := gd.SceneTree_get_nodes_in_group(tree, gd.sn(BULK_GROUP))
	defer gd.Array_destroy(&nodes)
	// drop dead ones
	for i := len(V.bulks) - 1; i >= 0; i -= 1 {
		if !alive(V.bulks[i].id) {
			bulk_drop(&V.bulks[i])
			unordered_remove(&V.bulks, i)
		}
	}
	outer: for i in 0 ..< gd.array_len(&nodes) {
		obj, _ := gd.from_variant(gd.Object, gd.array_at(&nodes, i))
		instance: gd.Node
		is_2d := false
		if instance3d := gd.object_cast(gd.MultiMeshInstance3D, obj, "MultiMeshInstance3D"); instance3d.ptr != nil {
			instance = instance3d
		} else if instance2d := gd.object_cast(gd.MultiMeshInstance2D, obj, "MultiMeshInstance2D");
		   instance2d.ptr != nil {
			instance, is_2d = instance2d, true
		} else {
			continue
		}
		id := gdi.object_get_instance_id(instance.ptr)
		for bulk in V.bulks do if bulk.id == id do continue outer
		multimesh: gd.Ref(gd.MultiMesh) // owned: kept by the Bulk_View, dropped by bulk_drop
		if is_2d {
			multimesh = gd.MultiMeshInstance2D_get_multimesh(gd.cast_to(gd.MultiMeshInstance2D, instance))
		} else {
			multimesh = gd.MultiMeshInstance3D_get_multimesh(gd.cast_to(gd.MultiMeshInstance3D, instance))
		}
		kind_variant := gd.Object_get(instance, gd.sn("kind"))
		defer gd.variant_destroy(&kind_variant)
		kind_name, _ := gd.from_variant(string, &kind_variant)
		kind := -1
		for name, j in api.bulk_kinds do if name == kind_name do kind = j
		if kind < 0 {
			gd.print_warning(fmt.tprintf("unified: bulk view with unknown kind %q", kind_name))
		}
		if multimesh.ptr == nil {
			gd.print_warning(fmt.tprintf("unified: bulk view %q has no MultiMesh", kind_name))
			continue
		}
		// the buffer layout follows the MultiMesh's own format (a 2D node with a 3D MultiMesh renders wrongly)
		multimesh_2d := gd.MultiMesh_get_transform_format(multimesh) == .TRANSFORM_2D
		if multimesh_2d != is_2d {
			gd.print_warning(
				fmt.tprintf(
					"unified: bulk view %q: a %s needs transform_format TRANSFORM_%s",
					kind_name,
					is_2d ? "MultiMeshInstance2D" : "MultiMeshInstance3D",
					is_2d ? "2D" : "3D",
				),
			)
		}
		stride := multimesh_2d ? 8 : 12
		if gd.MultiMesh_is_using_colors(multimesh) do stride += 4
		if gd.MultiMesh_is_using_custom_data(multimesh) do stride += 4
		append(
			&V.bulks,
			Bulk_View{node = instance, id = id, kind = kind, mm = multimesh, stride = stride, is_2d = multimesh_2d},
		)
	}
}

// One pass over the frame's bulk items: counted per kind, then each item written into the buffer of every bulk
// view of its kind (usually one).
@(private)
bulk_sync :: proc(root: gd.Node, frame: ^Frame, alpha: f32) {
	if V.frame >= V.scan_frame {
		bulk_scan(root)
		V.scan_frame = V.frame + 30
	}
	counts: [256]int
	for &item in frame.bulk[:frame.n_bulk] do counts[item.kind] += 1
	// views by kind: first[kind] -> next[...] (indices into V.bulks, -1 ends)
	first: [256]i32 = -1
	next := make([]i32, len(V.bulks), context.temp_allocator)
	cursor := make([]int, len(V.bulks), context.temp_allocator)
	for i := len(V.bulks) - 1; i >= 0; i -= 1 {
		bulk := &V.bulks[i]
		next[i] = -1
		if bulk.kind < 0 || !alive(bulk.id) do continue
		count := counts[bulk.kind]
		if count > bulk.cap {
			new_cap := max(count, 64, bulk.cap * 2)
			if bulk.cap == 0 do bulk.buf = gd.PackedFloat32Array_new0()
			gd.PackedFloat32Array_resize(&bulk.buf, new_cap * bulk.stride)
			gd.MultiMesh_set_instance_count(bulk.mm, new_cap)
			bulk.cap = new_cap
		}
		if bulk.cap == 0 do continue
		bulk.has_col = gd.MultiMesh_is_using_colors(bulk.mm)
		bulk.has_custom = gd.MultiMesh_is_using_custom_data(bulk.mm)
		bulk.ptr = ([^]f32)(gdi.packed_float32_array_operator_index(&bulk.buf, 0))
		next[i] = first[bulk.kind]
		first[bulk.kind] = i32(i)
	}
	for &item in frame.bulk[:frame.n_bulk] {
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
		cos_yaw, sin_yaw := math.cos(yaw), math.sin(yaw)
		for ; view_index >= 0; view_index = next[view_index] {
			bulk := &V.bulks[view_index]
			out := bulk.ptr[cursor[view_index] * bulk.stride:]
			cursor[view_index] += 1
			offset: int
			if bulk.is_2d {
				// Transform2D rows (x axis = (cos, sin)·sx, y axis = (-sin, cos)·sy): rotation about Z, scale per axis
				out[0], out[1], out[2], out[3] = cos_yaw * scale.x, -sin_yaw * scale.y, 0, pos.x
				out[4], out[5], out[6], out[7] = sin_yaw * scale.x, cos_yaw * scale.y, 0, pos.y
				offset = 8
			} else {
				// Transform3D rows (yaw about +Y; local axes scaled by scale)
				out[0], out[1], out[2], out[3] = cos_yaw * scale.x, 0, sin_yaw * scale.z, pos.x
				out[4], out[5], out[6], out[7] = 0, scale.y, 0, pos.y
				out[8], out[9], out[10], out[11] = -sin_yaw * scale.x, 0, cos_yaw * scale.z, pos.z
				offset = 12
			}
			if bulk.has_col {
				color := item.color == {} ? [4]f32{1, 1, 1, 1} : item.color
				out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = color[0], color[1], color[2], color[3]
				offset += 4
			}
			if bulk.has_custom do out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = item.custom[0], item.custom[1], item.custom[2], item.custom[3]
		}
	}
	for &bulk, i in V.bulks {
		if bulk.kind < 0 || !alive(bulk.id) || bulk.cap == 0 do continue
		gd.MultiMesh_set_buffer(bulk.mm, bulk.buf)
		gd.MultiMesh_set_visible_instance_count(bulk.mm, cursor[i])
	}
}
