// Views: scene views spawned per spawn key under the session's view_root, interpolated and smoothed with
// unified:view, and MultiMesh bulk views whose buffers are written natively. The game's scenes may use the
// typed SimView / SimBulkView roots or plain Node3D / MultiMeshInstance3D nodes with script properties
// (kind, entity, slot): the host talks to both through Object.set/call.
package godot_host

import "core:fmt"
import "core:math"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"
import "unified:view"

LINGER_S :: 0.25 // a despawned scene view stays this long (exit animation, or a rollback brings it back)
BULK_GROUP :: "sim_bulk"

@(private)
Scene_View :: struct {
	node:       gd.Node3D,
	id:         u64,
	kind:       u8,
	slot:       i8,
	entity:     u32,
	track:      view.Track,
	has_update: bool,
	has_event:  bool,
}

@(private)
Bulk_View :: struct {
	node:   gd.MultiMeshInstance3D,
	id:     u64,
	kind:   int, // index into api.bulk_kinds, -1: unknown
	mm:     gd.Ref(gd.MultiMesh),
	buf:    gd.PackedFloat32Array,
	cap:    int,
	stride: int,
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
sim_view_class: gd.Class
@(private)
sim_bulk_class: gd.Class

register_classes :: proc() {
	register_session_class()
	sim_view_class = {
		name = "SimView",
		parent = "Node3D",
		size = size_of(Sim_View_Node),
		init = proc(i: rawptr) {(^Sim_View_Node)(i).slot = -1},
		fini = proc(i: rawptr) {gd.StringName_destroy(&(^Sim_View_Node)(i).kind)},
	}
	c := &sim_view_class
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
	gd.bind_script_virtual(c, "_sim_update", {"position", gd.Vector3}, {"yaw", f64}, {"alpha", f64})
	gd.bind_script_virtual(c, "_sim_event", {"kind", gd.StringName}, {"data", gd.Dictionary})

	sim_bulk_class = {
		name = "SimBulkView",
		parent = "MultiMeshInstance3D",
		size = size_of(Sim_Bulk_Node),
		fini = proc(i: rawptr) {gd.StringName_destroy(&(^Sim_Bulk_Node)(i).kind)},
		notification = proc(i: rawptr, what: i32) {
			if what == gd.Node_NOTIFICATION_ENTER_TREE {
				gd.Node_add_to_group(gd.cast_to(gd.Node, (^Sim_Bulk_Node)(i).obj), BULK_GROUP, false)
			}
		},
	}
	c = &sim_bulk_class
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
	gd.unregister_class(&sim_bulk_class)
	gd.unregister_class(&sim_view_class)
	gd.unregister_class(&session_class)
}

// ---- scene views

@(private)
scene_for :: proc(kind: u8) -> (gd.PackedScene, bool) {
	if ps, ok := V.scenes[kind]; ok do return ps, true
	if V.missing[kind] do return {}, false
	name := int(kind) < len(api.scene_kinds) ? api.scene_kinds[kind] : fmt.tprintf("kind%d", kind)
	path := fmt.tprintf("res://game/views/%s.tscn", name)
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
spawn_view :: proc(root: gd.Node3D, it: ^Scene_Item) -> ^Scene_View {
	ps, ok := scene_for(it.kind)
	if !ok do return nil
	node := gd.PackedScene_instantiate(ps, .GEN_EDIT_STATE_DISABLED)
	if node.ptr == nil do return nil
	n3 := gd.object_cast(gd.Node3D, node, "Node3D")
	if n3.ptr == nil {
		gd.print_error("unified: a view scene's root must be a Node3D")
		gdi.object_destroy(node.ptr)
		return nil
	}
	v := new(Scene_View)
	v.node = n3
	v.id = gdi.object_get_instance_id(n3.ptr)
	v.kind, v.slot, v.entity = it.kind, it.slot, it.entity
	kind := int(it.kind) < len(api.scene_kinds) ? api.scene_kinds[it.kind] : ""
	set_prop(n3, "kind", gd.variant_string_name(kind))
	set_prop(n3, "entity", gd.to_variant(i64(it.entity)))
	set_prop(n3, "slot", gd.to_variant(i64(it.slot)))
	v.has_update = gd.has_script_method(n3, gd.sn("_sim_update"))
	v.has_event = gd.has_script_method(n3, gd.sn("_sim_event"))
	gd.Node3D_set_position(n3, {it.pos.x, it.pos.y, it.pos.z})
	q := quat_or_identity(it.rot)
	gd.Node3D_set_quaternion(n3, {q.x, q.y, q.z, q.w})
	gd.Node_add_child(root, n3, false, .INTERNAL_MODE_DISABLED)
	return v
}

@(private)
quat_or_identity :: proc(q: [4]f32) -> [4]f32 {
	return q == {} ? view.IDENTITY : q
}

@(private)
set_prop :: proc(o: gd.Object, name: string, v: gd.Variant) {
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
}

// The game set or cleared view_root: drop every view (they lived under the old root).
views_root_changed :: proc() {
	for _, e in V.set.entries do free_view(e.view)
	clear(&V.set.entries)
	for &b in V.bulks do bulk_drop(&b)
	clear(&V.bulks)
	V.scan_frame = 0
}

views_sync :: proc(root: gd.Node3D, f: ^Frame, fresh: bool, alpha: f32, dt: f32) {
	V.frame += 1
	if root.ptr == nil {
		if len(V.set.entries) > 0 || len(V.bulks) > 0 do views_root_changed()
		return
	}
	if V.clock == {} do V.clock = time.tick_now()
	now_s := time.duration_seconds(time.tick_since(V.clock))
	if fresh {
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
			if it.has_prev do view.track_push(&v.track, f.tick - 1, {it.prev_pos, quat_or_identity(it.prev_rot)})
			view.track_push(&v.track, f.tick, {it.pos, quat_or_identity(it.rot)})
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
		p := view.track_sample(&v.track, f.tick, alpha, dt)
		yaw := view.yaw_of(p.rot)
		pos := gd.Vector3{p.pos.x, p.pos.y, p.pos.z}
		gd.Node3D_set_position(v.node, pos)
		gd.Node3D_set_quaternion(v.node, {p.rot.x, p.rot.y, p.rot.z, p.rot.w})
		if v.has_update {
			r := gd.call_script(v.node, gd.sn("_sim_update"), pos, f64(yaw), f64(alpha))
			gd.variant_destroy(&r)
		}
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
		gd.dict_set(&d, "position", gd.Vector3{e.pos.x, e.pos.y, e.pos.z})
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
bulk_scan :: proc(root: gd.Node3D) {
	tree := gd.Node_get_tree(root)
	nodes := gd.SceneTree_get_nodes_in_group(tree, BULK_GROUP)
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
		mmi := gd.object_cast(gd.MultiMeshInstance3D, obj, "MultiMeshInstance3D")
		if mmi.ptr == nil do continue
		id := gdi.object_get_instance_id(mmi.ptr)
		for b in V.bulks do if b.id == id do continue outer
		kv := gd.Object_get(mmi, "kind")
		defer gd.variant_destroy(&kv)
		kind_name, _ := gd.from_variant(string, &kv)
		kind := -1
		for k, j in api.bulk_kinds do if k == kind_name do kind = j
		if kind < 0 {
			gd.print_warning(fmt.tprintf("unified: bulk view with unknown kind %q", kind_name))
		}
		mm := gd.MultiMeshInstance3D_get_multimesh(mmi)
		if mm.ptr == nil {
			gd.print_warning(fmt.tprintf("unified: bulk view %q has no MultiMesh", kind_name))
			continue
		}
		stride := 12
		if gd.MultiMesh_is_using_colors(mm) do stride += 4
		if gd.MultiMesh_is_using_custom_data(mm) do stride += 4
		append(&V.bulks, Bulk_View{node = mmi, id = id, kind = kind, mm = mm, stride = stride})
	}
}

@(private)
bulk_sync :: proc(root: gd.Node3D, f: ^Frame, alpha: f32) {
	if V.frame >= V.scan_frame {
		bulk_scan(root)
		V.scan_frame = V.frame + 30
	}
	for &b in V.bulks {
		if b.kind < 0 || !alive(b.id) do continue
		n := 0
		for &it in f.bulk[:f.n_bulk] do if int(it.kind) == b.kind do n += 1
		if n > b.cap {
			newcap := max(n, 64, b.cap * 2)
			if b.cap == 0 do b.buf = gd.PackedFloat32Array_new0()
			gd.PackedFloat32Array_resize(&b.buf, newcap * b.stride)
			gd.MultiMesh_set_instance_count(b.mm, newcap)
			b.cap = newcap
		}
		if b.cap == 0 do continue
		buf := ([^]f32)(gdi.packed_float32_array_operator_index(&b.buf, 0))
		has_col := gd.MultiMesh_is_using_colors(b.mm)
		has_custom := gd.MultiMesh_is_using_custom_data(b.mm)
		i := 0
		for &it in f.bulk[:f.n_bulk] {
			if int(it.kind) != b.kind do continue
			p := it.pos
			if it.has_prev do p = view.lerp3(it.prev_pos, it.pos, alpha)
			sc := it.scale == 0 ? 1 : it.scale
			cs, sn := math.cos(it.yaw) * sc, math.sin(it.yaw) * sc
			o := buf[i * b.stride:]
			o[0], o[1], o[2], o[3] = cs, 0, sn, p.x
			o[4], o[5], o[6], o[7] = 0, sc, 0, p.y
			o[8], o[9], o[10], o[11] = -sn, 0, cs, p.z
			k := 12
			if has_col {
				o[k], o[k + 1], o[k + 2], o[k + 3] = 1, 1, 1, 1
				k += 4
			}
			if has_custom do o[k], o[k + 1], o[k + 2], o[k + 3] = it.custom[0], it.custom[1], it.custom[2], it.custom[3]
			i += 1
		}
		gd.MultiMesh_set_buffer(b.mm, b.buf)
		gd.MultiMesh_set_visible_instance_count(b.mm, n)
	}
}
