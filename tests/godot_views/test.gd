# godot_host view tests: run headless by `python tools/dev.py godot-test`. A single player session of the toy
# game whose Glue (ext/ext.odin) shows fixed items; checks that 2D and 3D scene views spawn, get their pose and
# _sim_update, and that 2D and 3D bulk views get their MultiMesh buffers. Prints one line per check and
# "VIEWS TESTS: <n> failed"; exits with the failure count.
extends SceneTree

const POS_2D := Vector2(120, 80)
const ANGLE_2D := 0.5
const POS_3D := Vector3(1, 2, 3)
const YAW_3D := 0.75

var failed := 0

func check(name: String, ok: bool, detail = "") -> void:
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, str(detail)])
	if not ok:
		failed += 1

func near(a: float, b: float) -> bool:
	return absf(a - b) < 1e-4

func near_all(got: PackedFloat32Array, want: Array) -> bool:
	if got.size() != want.size():
		return false
	for i in want.size():
		if not near(got[i], want[i]):
			return false
	return true

func multimesh(two_d: bool, colors: bool, custom: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D if two_d else MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.use_custom_data = custom
	mm.mesh = QuadMesh.new()
	return mm

func child_of_kind(parent: Node, kind: String) -> Node:
	for c in parent.get_children():
		if str(c.get("kind")) == kind:
			return c
	return null

func _initialize() -> void:
	var world := Node2D.new()
	root.add_child(world)
	var typed_bulk = ClassDB.instantiate("SimBulkView2D")
	typed_bulk.kind = "bulk2d"
	typed_bulk.multimesh = multimesh(true, true, true)
	world.add_child(typed_bulk)
	var plain_bulk: MultiMeshInstance2D = load("res://plain_bulk2d.gd").new()
	plain_bulk.multimesh = multimesh(true, false, false)
	plain_bulk.add_to_group("sim_bulk")
	world.add_child(plain_bulk)
	var bulk3d = ClassDB.instantiate("SimBulkView")
	bulk3d.kind = "bulk3d"
	bulk3d.multimesh = multimesh(false, true, false)
	world.add_child(bulk3d)
	var views := Node2D.new()
	world.add_child(views)
	var session = ClassDB.instantiate("UnifiedSession")
	root.add_child(session)
	session.view_root = views
	check("view_root takes a Node2D", session.view_root == views)
	check("start_single", session.start_single())

	var typed: Node = null
	for i in 100:  # up to ~2 s
		await create_timer(0.02).timeout
		typed = child_of_kind(views, "typed2d")
		if typed != null and typed.updates > 1 and typed_bulk.multimesh.visible_instance_count == 2:
			break
	check("typed 2D view spawned", typed != null and typed is SimView2D, typed)
	if typed == null:
		finish(session)
		return
	check("2D position = pos.xy", typed.position.is_equal_approx(POS_2D), typed.position)
	check("2D rotation = angle about Z", near(typed.rotation, ANGLE_2D), typed.rotation)
	check("_sim_update(Vector2, rotation, alpha)", typed.last_position is Vector2 \
		and typed.last_position.is_equal_approx(POS_2D) and near(typed.last_rotation, ANGLE_2D),
		[typed.last_position, typed.last_rotation])
	check("typed 2D view properties", typed.slot == 0 and typed.kind == &"typed2d", [typed.slot, typed.kind])
	var plain := child_of_kind(views, "plain2d")
	check("plain Node2D view", plain != null and plain.entity == 7 and plain.updates > 0 \
		and plain.position.is_equal_approx(POS_2D + Vector2(10, 0)), plain)
	var p3 := child_of_kind(views, "plain3d")
	check("3D view under a 2D root", p3 is Node3D and p3.position.is_equal_approx(POS_3D) \
		and near(p3.rotation.y, YAW_3D) and p3.last_position is Vector3 and near(p3.last_yaw, YAW_3D),
		[p3.position, p3.rotation] if p3 else null)
	var joined: Array = typed.events.filter(func(e): return e[0] == &"joined")
	check("_sim_event on the 2D view, position a Vector2", joined.size() > 0 \
		and joined[0][1].get("position") is Vector2, typed.events)

	# 2D bulk, colors + custom: stride 16 = transform (8) + color (4) + custom (4)
	var mm: MultiMesh = typed_bulk.multimesh
	check("2D bulk instances", mm.visible_instance_count == 2, mm.visible_instance_count)
	var buf := mm.buffer
	var c := cos(0.25) * 2
	var s := sin(0.25) * 2
	check("2D bulk buffer (rotation, scale, position, color, custom)",
		near_all(buf.slice(0, 16), [c, -s, 0, 30, s, c, 0, 40, 1, 0.5, 0.25, 1, 1, 2, 3, 4]), buf.slice(0, 16))
	check("2D bulk defaults (scale 1, white)",
		near_all(buf.slice(16, 32), [1, 0, 0, -5, 0, 1, 0, 6, 1, 1, 1, 1, 0, 0, 0, 0]), buf.slice(16, 32))
	# decoded with the buffer layout Godot documents (MultiMesh.buffer): rows of the transform, then the origin
	var t := Transform2D(Vector2(buf[0], buf[4]), Vector2(buf[1], buf[5]), Vector2(buf[3], buf[7]))
	check("2D bulk transform as Godot reads it", t.origin.is_equal_approx(Vector2(30, 40)) \
		and near(t.get_rotation(), 0.25) and t.get_scale().is_equal_approx(Vector2(2, 2)), t)
	var pm: MultiMesh = plain_bulk.multimesh
	check("plain MultiMeshInstance2D bulk (stride 8)", pm.visible_instance_count == 2 \
		and near_all(pm.buffer.slice(0, 8), [c, -s, 0, 30, s, c, 0, 40]), pm.buffer.slice(0, 8))
	var m3: MultiMesh = bulk3d.multimesh
	var b3 := m3.buffer
	var t3 := Transform3D(Vector3(b3[0], b3[4], b3[8]), Vector3(b3[1], b3[5], b3[9]), Vector3(b3[2], b3[6], b3[10]),
		Vector3(b3[3], b3[7], b3[11]))
	check("3D bulk unchanged", m3.visible_instance_count == 1 and t3.origin.is_equal_approx(POS_3D) \
		and near(t3.basis.get_euler().y, YAW_3D) and near_all(b3.slice(12, 16), [0, 1, 0, 1]),
		[m3.visible_instance_count, t3])
	finish(session)

func finish(session: Node) -> void:
	session.leave()
	for i in 50:
		if not session.is_running():
			break
		await create_timer(0.02).timeout
	root.get_child(0).queue_free()
	session.queue_free()
	await process_frame
	print("VIEWS TESTS: %d failed" % failed)
	quit(failed)
