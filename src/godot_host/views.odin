// Views: scene views spawned per spawn key under the session's view_root, interpolated and smoothed with
// unified:view, and MultiMesh bulk views whose buffers are written natively. 3D and 2D share it all: the game's
// scenes may use the typed SimView / SimView2D / SimBulkView / SimBulkView2D roots or plain Node3D / Node2D /
// MultiMeshInstance3D / MultiMeshInstance2D nodes with script properties (kind, entity, slot): the host talks
// to both through Object.set/call. A scene root's class (Node3D or Node2D) picks the 3D or 2D mapping.
package godot_host

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
	slot:       i8,
	entity:     u32,
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
	slot:      i64,
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

// SimView / SimView2D: kind, entity, slot and the script virtuals _sim_update(position, yaw | rotation, alpha)
// and _sim_event(kind, data).
@(private)
register_view_class :: proc(c: ^gd.Class, name, parent: string, pos: typeid, angle: string) {
	c^ = {
		name = name,
		parent = parent,
		size = size_of(Sim_View_Node),
		init = proc(i: rawptr) {(^Sim_View_Node)(i).slot = -1},
		fini = proc(i: rawptr) {gd.StringName_destroy(&(^Sim_View_Node)(i).kind)},
	}
	gd.register_class(c)
	gd.bind_property(
		c,
		"kind",
		proc(v: ^Sim_View_Node) -> string {return gd.string_name_to_odin(&v.kind)},
		proc(v: ^Sim_View_Node, k: string) {
			gd.StringName_destroy(&v.kind)
			v.kind = gd.string_name_from(k)
		},
	)
	gd.bind_property(
		c,
		"entity",
		proc(v: ^Sim_View_Node) -> i64 {return v.entity},
		proc(v: ^Sim_View_Node, e: i64) {v.entity = e},
	)
	gd.bind_property(
		c,
		"slot",
		proc(v: ^Sim_View_Node) -> i64 {return v.slot},
		proc(v: ^Sim_View_Node, e: i64) {v.slot = e},
	)
	gd.bind_script_virtual(c, "_sim_update", {"position", pos}, {angle, f64}, {"alpha", f64})
	gd.bind_script_virtual(c, "_sim_event", {"kind", gd.StringName}, {"data", gd.Dictionary})
}

// SimBulkView / SimBulkView2D: `kind`, and the node joins the `sim_bulk` group when it enters the tree.
@(private)
register_bulk_class :: proc(c: ^gd.Class, name, parent: string) {
	c^ = {
		name = name,
		parent = parent,
		size = size_of(Sim_Bulk_Node),
		fini = proc(i: rawptr) {gd.StringName_destroy(&(^Sim_Bulk_Node)(i).kind)},
		notification = proc(i: rawptr, what: i32) {
			if what == gd.Node_NOTIFICATION_ENTER_TREE {
				gd.Node_add_to_group(gd.cast_to(gd.Node, (^Sim_Bulk_Node)(i).obj), gd.sn(BULK_GROUP), false)
			}
		},
	}
	gd.register_class(c)
	gd.bind_property(
		c,
		"kind",
		proc(v: ^Sim_Bulk_Node) -> string {return gd.string_name_to_odin(&v.kind)},
		proc(v: ^Sim_Bulk_Node, k: string) {
			gd.StringName_destroy(&v.kind)
			v.kind = gd.string_name_from(k)
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
	if ps, ok := V.scenes[kind]; ok do return ps, true
	if V.missing[kind] do return {}, false
	name := int(kind) < len(api.scenes) ? api.scenes[kind].name : fmt.tprintf("kind%d", kind)
	path := fmt.tprintf("%s/%s.tscn", api.scene_dir, name)
	res := gd.ResourceLoader_load(gd.ResourceLoader_singleton(), path, "", .CACHE_MODE_REUSE)
	if res.ptr == nil {
		gd.print_error(fmt.tprintf("unified: cannot load %s", path))
		V.missing[kind] = true
		return {}, false
	}
	ps := transmute(gd.Ref(gd.PackedScene))res
	V.scenes[kind] = ps
	return ps, true
}

@(private)
spawn_view :: proc(root: gd.Node, it: ^Scene_Item) -> ^Scene_View {
	ps, ok := scene_for(it.kind)
	if !ok do return nil
	node := gd.PackedScene_instantiate(ps, .GEN_EDIT_STATE_DISABLED)
	if node.ptr == nil do return nil
	v := new(Scene_View)
	if n3 := gd.object_cast(gd.Node3D, node, "Node3D"); n3.ptr != nil {
		v.node = n3
	} else if n2 := gd.object_cast(gd.Node2D, node, "Node2D"); n2.ptr != nil {
		v.node, v.is_2d = n2, true
	} else {
		gd.print_error("unified: a view scene's root must be a Node3D or a Node2D")
		gdi.object_destroy(node.ptr)
		free(v)
		return nil
	}
	n := v.node
	v.id = gdi.object_get_instance_id(n.ptr)
	v.kind, v.slot, v.entity = it.kind, it.slot, it.entity
	kind := int(it.kind) < len(api.scenes) ? api.scenes[it.kind].name : ""
	set_prop(n, gd.sn("kind"), gd.variant_string_name(kind))
	set_prop(n, gd.sn("entity"), gd.to_variant(i64(it.entity)))
	set_prop(n, gd.sn("slot"), gd.to_variant(i64(it.slot)))
	v.has_update = gd.has_script_method(n, gd.sn("_sim_update"))
	v.has_event = gd.has_script_method(n, gd.sn("_sim_event"))
	set_pose(v, {it.pos, quat_or_identity(it.rot)})
	gd.Node_add_child(root, n, false, .INTERNAL_MODE_DISABLED)
	// data after _ready: a script's property setters may use its @onready nodes
	if v.is_2d && api.smoothing == view.SMOOTHING_DEFAULT {
		warn_once(
			"smoothing",
			"unified: 2D scene views with the default smoothing (metres): set Glue.smoothing in the units extract writes, e.g. {tau_s = 0.1, teleport_dist = 64} for pixels",
		)
	}
	fields := data_fields(it.kind)
	for &fd in fields {
		r := gd.Object_get(n, fd.name)
		if gd.variant_type(&r) == .NIL {
			warn_once(
				fmt.tprintf("prop:%s:%s", kind, gd.string_name_to_odin(fd.name)),
				fmt.tprintf(
					"unified: scene view %q has no property %q for its data",
					kind,
					gd.string_name_to_odin(fd.name),
				),
			)
		}
		gd.variant_destroy(&r)
	}
	set_data(v, fields, &it.data)
	return v
}

// 3D: position and quaternion. 2D: position = pos.xy, rotation = the angle about Z.
@(private)
set_pose :: proc(v: ^Scene_View, p: view.Pose) {
	if v.is_2d {
		n := gd.cast_to(gd.Node2D, v.node)
		gd.Node2D_set_position(n, {p.pos.x, p.pos.y})
		gd.Node2D_set_rotation(n, view.angle2d_of(p.rot))
	} else {
		n := gd.cast_to(gd.Node3D, v.node)
		gd.Node3D_set_position(n, {p.pos.x, p.pos.y, p.pos.z})
		gd.Node3D_set_quaternion(n, {p.rot.x, p.rot.y, p.rot.z, p.rot.w})
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
	if f, ok := V.fields[kind]; ok do return f
	tid := api.scenes[kind].data
	out := make([dynamic]Data_Field)
	ti := runtime.type_info_base(type_info_of(tid))
	st, is_struct := ti.variant.(runtime.Type_Info_Struct)
	if !is_struct || ti.size > SCENE_DATA_BYTES {
		gd.print_error(
			fmt.tprintf(
				"unified: scene kind %q: data %v must be a struct of at most %d bytes",
				api.scenes[kind].name,
				tid,
				SCENE_DATA_BYTES,
			),
		)
	} else {
		for i in 0 ..< int(st.field_count) {
			name := st.names[i]
			ft := runtime.type_info_base(st.types[i])
			fd := Data_Field {
				name   = gd.sn(name),
				offset = int(st.offsets[i]),
				size   = ft.size,
			}
			ok := true
			#partial switch fv in ft.variant {
			case runtime.Type_Info_Boolean:
				fd.conv = .Bool
			case runtime.Type_Info_Integer:
				fd.conv = fv.signed ? .Int : .Uint
			case runtime.Type_Info_Enum:
				eb := runtime.type_info_base(fv.base)
				fd.conv = eb.variant.(runtime.Type_Info_Integer).signed ? .Int : .Uint
			case runtime.Type_Info_Float:
				ok = ft.size == 4
				fd.conv = .F32
			case runtime.Type_Info_Array:
				ok = fv.elem.id == f32 && fv.count >= 2 && fv.count <= 4
				fd.conv = fv.count == 2 ? .Vec2 : fv.count == 3 ? .Vec3 : .Color
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
						st.types[i].id,
					),
				)
				continue
			}
			append(&out, fd)
		}
	}
	V.fields[kind] = out[:]
	return out[:]
}

// Sets every data field whose bytes changed (all of them on a fresh view) as a property.
@(private)
set_data :: proc(v: ^Scene_View, fields: []Data_Field, data: ^[SCENE_DATA_BYTES]u8, fresh := true) {
	for &fd in fields {
		a := data[fd.offset:][:fd.size if fd.conv < .F32 else field_bytes(fd.conv)]
		if !fresh && string(a) == string(v.data[fd.offset:][:len(a)]) do continue
		p := raw_data(a)
		val: gd.Variant
		switch fd.conv {
		case .Bool:
			val = gd.to_variant(p[0] != 0)
		case .Int:
			switch fd.size {
			case 1:
				val = gd.to_variant(i64((^i8)(p)^))
			case 2:
				val = gd.to_variant(i64((^i16le)(p)^))
			case 4:
				val = gd.to_variant(i64((^i32le)(p)^))
			case:
				val = gd.to_variant(i64((^i64le)(p)^))
			}
		case .Uint:
			switch fd.size {
			case 1:
				val = gd.to_variant(i64(p[0]))
			case 2:
				val = gd.to_variant(i64((^u16le)(p)^))
			case 4:
				val = gd.to_variant(i64((^u32le)(p)^))
			case:
				val = gd.to_variant(i64((^u64le)(p)^))
			}
		case .F32:
			val = gd.to_variant((^f32)(p)^)
		case .Vec2:
			f := (^[2]f32)(p)^
			val = gd.to_variant(gd.Vector2{f.x, f.y})
		case .Vec3:
			f := (^[3]f32)(p)^
			val = gd.to_variant(gd.Vector3{f.x, f.y, f.z})
		case .Color:
			f := (^[4]f32)(p)^
			val = gd.to_variant(gd.Color{f[0], f[1], f[2], f[3]})
		}
		set_prop(v.node, fd.name, val)
	}
	v.data = data^
}

@(private)
field_bytes :: proc(c: type_of(Data_Field{}.conv)) -> int {
	#partial switch c {
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
quat_or_identity :: proc(q: [4]f32) -> [4]f32 {
	return q == {} ? view.IDENTITY : q
}

@(private)
set_prop :: proc(o: gd.Object, name: ^gd.StringName, v: gd.Variant) {
	v := v
	gd.Object_set(o, name, v)
	gd.variant_destroy(&v)
}

@(private)
free_view :: proc(v: ^Scene_View) {
	if v == nil do return
	if alive(v.id) do gd.Node_queue_free(v.node)
	free(v)
}

views_clear :: proc() {
	for _, e in V.set.entries do free_view(e.view)
	view.set_destroy(&V.set)
	V.set = {}
	for &b in V.bulks do bulk_drop(&b)
	delete(V.bulks)
	V.bulks = nil
	for _, ps in V.scenes do gd.unref(ps)
	delete(V.scenes)
	delete(V.missing)
	V.scenes, V.missing = nil, nil
	for _, f in V.fields do delete(f)
	delete(V.fields)
	V.fields = nil
}

// The game set or cleared view_root: drop every view (they lived under the old root).
views_root_changed :: proc() {
	for _, e in V.set.entries do free_view(e.view)
	clear(&V.set.entries)
	for &b in V.bulks do bulk_drop(&b)
	clear(&V.bulks)
	V.scan_frame = 0
}

views_sync :: proc(root: gd.Node, f: ^Frame, fresh: bool, alpha: f32, dt: f32) {
	V.frame += 1
	if root.ptr == nil {
		if len(V.set.entries) > 0 || len(V.bulks) > 0 do views_root_changed()
		return
	}
	if V.clock == {} do V.clock = time.tick_now()
	now_s := time.duration_seconds(time.tick_since(V.clock))
	if fresh {
		if f.dropped > 0 {
			warn_once(
				"dropped",
				fmt.tprintf(
					"unified: a frame had more items than it holds (%d dropped; MAX_SCENE_ITEMS %d, MAX_BULK_ITEMS %d)",
					f.dropped,
					MAX_SCENE_ITEMS,
					MAX_BULK_ITEMS,
				),
			)
		}
		view.set_begin(&V.set)
		for &it in f.scene[:f.n_scene] {
			old := view.set_get(&V.set, it.key)
			revived := old != nil && old.phase == .Lingering
			e, spawned := view.set_see(&V.set, it.key)
			if spawned do e.view = spawn_view(root, &it)
			v := e.view
			if v == nil do continue
			if revived && v.has_event && alive(v.id) {
				// a rollback brought it back during its linger: undo the exit animation
				d := gd.dict_new()
				r := gd.call_script(v.node, gd.sn("_sim_event"), gd.sn("revived")^, d)
				gd.variant_destroy(&r)
				gd.Dictionary_destroy(&d)
			}
			v.entity, v.slot = it.entity, it.slot
			if !spawned && alive(v.id) do set_data(v, data_fields(it.kind), &it.data, false)
			if it.has_prev {
				view.track_push(&v.track, f.tick - 1, {it.prev_pos, quat_or_identity(it.prev_rot)}, api.smoothing)
			}
			view.track_push(&v.track, f.tick, {it.pos, quat_or_identity(it.rot)}, api.smoothing)
		}
		view.set_end(&V.set, now_s, LINGER_S)
		for key in V.set.despawned {
			if e := view.set_get(&V.set, key); e != nil && e.view != nil && e.view.has_event && alive(e.view.id) {
				d := gd.dict_new()
				r := gd.call_script(e.view.node, gd.sn("_sim_event"), gd.sn("despawned")^, d)
				gd.variant_destroy(&r)
				gd.Dictionary_destroy(&d)
			}
		}
		for v in V.set.removed do free_view(v)
	}
	for _, &e in V.set.entries {
		v := e.view
		if v == nil || !alive(v.id) do continue
		p := view.track_sample(&v.track, f.tick, alpha, dt, api.smoothing)
		set_pose(v, p)
		if !v.has_update do continue
		r: gd.Variant
		if v.is_2d {
			pos := gd.Vector2{p.pos.x, p.pos.y}
			r = gd.call_script(v.node, gd.sn("_sim_update"), pos, f64(view.angle2d_of(p.rot)), f64(alpha))
		} else {
			pos := gd.Vector3{p.pos.x, p.pos.y, p.pos.z}
			r = gd.call_script(v.node, gd.sn("_sim_update"), pos, f64(view.yaw_of(p.rot)), f64(alpha))
		}
		gd.variant_destroy(&r)
	}
	bulk_sync(root, f, alpha)
}

// Predicted events (and their cancellations) go to the view of their entity, or of their player slot.
views_event :: proc(e: sim.Event, name: string, tick: u32, cancelled, predicted: bool) {
	key := api.event_key != nil ? api.event_key(e) : view.Key(0)
	if api.event_key != nil && key == 0 do return
	for k, &en in V.set.entries {
		v := en.view
		if v == nil || !v.has_event || !alive(v.id) do continue
		match: bool
		if api.event_key != nil {
			match = k == key
		} else if e.slot != sim.NO_SLOT {
			match = v.slot >= 0 && u8(v.slot) == e.slot
		} else {
			match = e.entity != 0 && v.entity == e.entity
		}
		if !match do continue
		d := gd.dict_new()
		gd.dict_set(&d, "tick", i64(tick))
		gd.dict_set(&d, "entity", i64(e.entity))
		gd.dict_set(&d, "slot", e.slot == 0xFF ? i64(-1) : i64(e.slot))
		if v.is_2d {
			gd.dict_set(&d, "position", gd.Vector2{e.pos.x, e.pos.y})
		} else {
			gd.dict_set(&d, "position", gd.Vector3{e.pos.x, e.pos.y, e.pos.z})
		}
		gd.dict_set(&d, "value", f64(e.value))
		gd.dict_set(&d, "predicted", predicted)
		gd.dict_set(&d, "cancelled", cancelled)
		r := gd.call_script(v.node, gd.sn("_sim_event"), gd.sn(name)^, d)
		gd.variant_destroy(&r)
		gd.Dictionary_destroy(&d)
	}
}

// ---- bulk views

@(private)
bulk_drop :: proc(b: ^Bulk_View) {
	if b.mm.ptr != nil do gd.unref(b.mm)
	if b.cap > 0 do gd.PackedFloat32Array_destroy(&b.buf)
	b^ = {}
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
		mmi: gd.Node
		is_2d := false
		if n3 := gd.object_cast(gd.MultiMeshInstance3D, obj, "MultiMeshInstance3D"); n3.ptr != nil {
			mmi = n3
		} else if n2 := gd.object_cast(gd.MultiMeshInstance2D, obj, "MultiMeshInstance2D"); n2.ptr != nil {
			mmi, is_2d = n2, true
		} else {
			continue
		}
		id := gdi.object_get_instance_id(mmi.ptr)
		for b in V.bulks do if b.id == id do continue outer
		mm: gd.Ref(gd.MultiMesh) // owned: kept by the Bulk_View, dropped by bulk_drop
		if is_2d {
			mm = gd.MultiMeshInstance2D_get_multimesh(gd.cast_to(gd.MultiMeshInstance2D, mmi))
		} else {
			mm = gd.MultiMeshInstance3D_get_multimesh(gd.cast_to(gd.MultiMeshInstance3D, mmi))
		}
		kv := gd.Object_get(mmi, gd.sn("kind"))
		defer gd.variant_destroy(&kv)
		kind_name, _ := gd.from_variant(string, &kv)
		kind := -1
		for k, j in api.bulk_kinds do if k == kind_name do kind = j
		if kind < 0 {
			gd.print_warning(fmt.tprintf("unified: bulk view with unknown kind %q", kind_name))
		}
		if mm.ptr == nil {
			gd.print_warning(fmt.tprintf("unified: bulk view %q has no MultiMesh", kind_name))
			continue
		}
		// the buffer layout follows the MultiMesh's own format (a 2D node with a 3D MultiMesh renders wrongly)
		mm_2d := gd.MultiMesh_get_transform_format(mm) == .TRANSFORM_2D
		if mm_2d != is_2d {
			gd.print_warning(
				fmt.tprintf(
					"unified: bulk view %q: a %s needs transform_format TRANSFORM_%s",
					kind_name,
					is_2d ? "MultiMeshInstance2D" : "MultiMeshInstance3D",
					is_2d ? "2D" : "3D",
				),
			)
		}
		stride := mm_2d ? 8 : 12
		if gd.MultiMesh_is_using_colors(mm) do stride += 4
		if gd.MultiMesh_is_using_custom_data(mm) do stride += 4
		append(&V.bulks, Bulk_View{node = mmi, id = id, kind = kind, mm = mm, stride = stride, is_2d = mm_2d})
	}
}

// One pass over the frame's bulk items: counted per kind, then each item written into the buffer of every bulk
// view of its kind (usually one).
@(private)
bulk_sync :: proc(root: gd.Node, f: ^Frame, alpha: f32) {
	if V.frame >= V.scan_frame {
		bulk_scan(root)
		V.scan_frame = V.frame + 30
	}
	counts: [256]int
	for &it in f.bulk[:f.n_bulk] do counts[it.kind] += 1
	// views by kind: first[kind] -> next[...] (indices into V.bulks, -1 ends)
	first: [256]i32 = -1
	next := make([]i32, len(V.bulks), context.temp_allocator)
	cursor := make([]int, len(V.bulks), context.temp_allocator)
	for i := len(V.bulks) - 1; i >= 0; i -= 1 {
		b := &V.bulks[i]
		next[i] = -1
		if b.kind < 0 || !alive(b.id) do continue
		n := counts[b.kind]
		if n > b.cap {
			newcap := max(n, 64, b.cap * 2)
			if b.cap == 0 do b.buf = gd.PackedFloat32Array_new0()
			gd.PackedFloat32Array_resize(&b.buf, newcap * b.stride)
			gd.MultiMesh_set_instance_count(b.mm, newcap)
			b.cap = newcap
		}
		if b.cap == 0 do continue
		b.has_col = gd.MultiMesh_is_using_colors(b.mm)
		b.has_custom = gd.MultiMesh_is_using_custom_data(b.mm)
		b.ptr = ([^]f32)(gdi.packed_float32_array_operator_index(&b.buf, 0))
		next[i] = first[b.kind]
		first[b.kind] = i32(i)
	}
	for &it in f.bulk[:f.n_bulk] {
		vi := first[it.kind]
		if vi < 0 do continue
		p := it.pos
		yaw := it.yaw
		if it.has_prev {
			p = view.lerp3(it.prev_pos, it.pos, alpha)
			d := it.yaw - it.prev_yaw
			d -= math.TAU * math.round(d / math.TAU) // the shorter arc
			yaw = it.prev_yaw + d * alpha
		}
		sc := it.scale == {} ? [3]f32{1, 1, 1} : it.scale
		cs, sn := math.cos(yaw), math.sin(yaw)
		for ; vi >= 0; vi = next[vi] {
			b := &V.bulks[vi]
			o := b.ptr[cursor[vi] * b.stride:]
			cursor[vi] += 1
			k: int
			if b.is_2d {
				// Transform2D rows (x axis = (cs, sn)·sx, y axis = (-sn, cs)·sy): rotation about Z, scale per axis
				o[0], o[1], o[2], o[3] = cs * sc.x, -sn * sc.y, 0, p.x
				o[4], o[5], o[6], o[7] = sn * sc.x, cs * sc.y, 0, p.y
				k = 8
			} else {
				// Transform3D rows (yaw about +Y; local axes scaled by sc)
				o[0], o[1], o[2], o[3] = cs * sc.x, 0, sn * sc.z, p.x
				o[4], o[5], o[6], o[7] = 0, sc.y, 0, p.y
				o[8], o[9], o[10], o[11] = -sn * sc.x, 0, cs * sc.z, p.z
				k = 12
			}
			if b.has_col {
				c := it.color == {} ? [4]f32{1, 1, 1, 1} : it.color
				o[k], o[k + 1], o[k + 2], o[k + 3] = c[0], c[1], c[2], c[3]
				k += 4
			}
			if b.has_custom do o[k], o[k + 1], o[k + 2], o[k + 3] = it.custom[0], it.custom[1], it.custom[2], it.custom[3]
		}
	}
	for &b, i in V.bulks {
		if b.kind < 0 || !alive(b.id) || b.cap == 0 do continue
		gd.MultiMesh_set_buffer(b.mm, b.buf)
		gd.MultiMesh_set_visible_instance_count(b.mm, cursor[i])
	}
}
