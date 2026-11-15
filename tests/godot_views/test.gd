# unified:godot view tests: run headless by `uni test --suite godot-bindings`. A single player session of the toy
# game whose Glue (ext/ext.odin) shows fixed items; checks that scene views with a UnifiedView marker spawn from
# the view index (2D, 3D, and a Control HUD that gets data only), get their pose, _sim_update and typed data as
# properties; that MultiMesh views get their buffers; that events reach the views and the sim_event signal as
# objects of their classes in each state; that commands made from their classes reach the sim once (and wrong
# values are refused with an error line the suite expects); and that the input sample latches a press. Prints one
# line per check and "VIEWS TESTS: <n> failed"; exits with the failure count.
extends SceneTree

const POS_2D := Vector2(120, 80)
const ANGLE_2D := 0.5
const POS_3D := Vector3(1, 2, 3)
const YAW_3D := 0.75

var failed := 0


func check(name: String, ok: bool, detail: Variant = "") -> void:
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


func multimesh_view(parent: Node, two_d: bool, colors: bool, custom: bool, kind: String, smooth := false) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D if two_d else MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.use_custom_data = custom
	mm.mesh = QuadMesh.new()
	var instance: Node
	if two_d:
		var instance2d := MultiMeshInstance2D.new()
		instance2d.multimesh = mm
		instance = instance2d
	else:
		var instance3d := MultiMeshInstance3D.new()
		instance3d.multimesh = mm
		instance = instance3d
	var marker := UnifiedMultiView.new()
	marker.kind = kind
	marker.smooth = smooth
	instance.add_child(marker)
	parent.add_child(instance)
	return mm


# An action pressed or released through Godot's input queue, as a key would.
func press(action: StringName, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)


func child_of_kind(parent: Node, kind: String) -> Node:
	for child in parent.get_children():
		var marker := child.get_node_or_null(^"UnifiedView") as UnifiedView
		if marker != null and marker.kind == kind:
			return child
	return null


func _initialize() -> void:
	var world := Node2D.new()
	root.add_child(world)
	var typed_multi := multimesh_view(world, true, true, true, "multi2d")
	var plain_multi := multimesh_view(world, true, false, false, "multi2d")
	var multi3d := multimesh_view(world, false, true, false, "multi3d", true)
	var views := Node2D.new()
	world.add_child(views)
	var session := UnifiedSession.new()
	root.add_child(session)
	var events: Array[Array] = []  # [event, state]
	session.sim_event.connect(func(event: UnifiedEvent, state: int) -> void: events.append([event, state]))
	session.view_root = views
	check("view_root takes a Node2D", session.view_root == views)
	check("no session: no local player", session.get_local_player() == -1)
	var early := CommandBump.new()
	early.amount = 1
	check("send_command without a session: false", not session.send_command(early))
	check("start_single", session.start_single())

	var typed: Node = null
	for i in 100:  # up to ~2 s
		await create_timer(0.02).timeout
		typed = child_of_kind(views, "typed2d")
		if i == 5:
			press(&"ui_accept", true)  # one press, shorter than a tick: latched until a tick takes it
		elif i == 6:
			press(&"ui_accept", false)
		if typed != null and typed.get("updates") > 1 and typed.get("ticks_sets") > 2 \
				and typed_multi.visible_instance_count == 2 and events.any(func(e: Array) -> bool:
					return e[0] is EventExpired and e[1] == UnifiedSession.EVENT_CONFIRMED):
			break
	check("typed 2D view spawned from the index", typed != null, typed)
	if typed == null:
		finish(session)
		return
	var marker := typed.get("marker") as UnifiedView
	check("2D position = pos.xy", (typed as Node2D).position.is_equal_approx(POS_2D), (typed as Node2D).position)
	check("2D rotation = angle about Z", near((typed as Node2D).rotation, ANGLE_2D), (typed as Node2D).rotation)
	check("_sim_update(Vector2, rotation, alpha)", typed.get("last_position").is_equal_approx(POS_2D) \
		and near(typed.get("last_rotation"), ANGLE_2D), [typed.get("last_position"), typed.get("last_rotation")])
	check("the marker: kind from the scene, player and entity from the host", marker.player == 0 \
		and marker.kind == "typed2d" and marker.entity == 0, [marker.player, marker.kind, marker.entity])
	var plain := child_of_kind(views, "plain2d")
	check("plain Node2D view", plain != null and (plain.get("marker") as UnifiedView).entity == 7 \
		and plain.get("updates") > 0 and (plain as Node2D).position.is_equal_approx(POS_2D + Vector2(10, 0)), plain)
	var p3 := child_of_kind(views, "plain3d") as Node3D
	check("3D view under a 2D root", p3 != null and p3.position.is_equal_approx(POS_3D) \
		and near(p3.rotation.y, YAW_3D) and near(p3.get("last_yaw"), YAW_3D), [p3.position, p3.rotation] if p3 else null)
	var hud := child_of_kind(views, "hud") as Control
	check("Control view: data only, no pose", hud != null and hud.position == Vector2.ZERO and hud.get("x") > 0, hud)
	check_events(events, typed)
	check("scene data as properties (an enum by name)", typed.get("shown") and typed.get("mode") == &"open" and typed.get("hp") == -3 \
		and near(typed.get("charge"), 0.5) and typed.get("dir").is_equal_approx(Vector2(0.6, -0.8)) \
		and typed.get("tint").is_equal_approx(Color(1, 0.5, 0.25, 1)),
		[typed.get("shown"), typed.get("mode"), typed.get("hp"), typed.get("charge"), typed.get("dir"), typed.get("tint")])
	check("scene data set only when it changes", typed.get("hp_sets") == 1 and typed.get("ticks_sets") > 2,
		[typed.get("hp_sets"), typed.get("ticks_sets")])
	check("one latched press spawned one thing", hud.get("spawned") == 1, hud.get("spawned"))
	check("the local player and its name", session.get_local_player() == 0 and session.get_player_name(0) == "player",
		[session.get_local_player(), session.get_player_name(0)])

	# 2D, colors + custom: stride 16 = transform (8) + color (4) + custom (4)
	check("2D MultiMesh instances", typed_multi.visible_instance_count == 2, typed_multi.visible_instance_count)
	var buf := typed_multi.buffer
	var c := cos(0.25)
	var s := sin(0.25)
	check("2D buffer (rotation on the shorter arc, scale per axis, position, color, custom)",
		near_all(buf.slice(0, 16), [c * 2, -s * 3, 0, 30, s * 2, c * 3, 0, 40, 1, 0.5, 0.25, 1, 1, 2, 3, 4]),
		buf.slice(0, 16))
	check("2D defaults (scale 1, white)",
		near_all(buf.slice(16, 32), [1, 0, 0, -5, 0, 1, 0, 6, 1, 1, 1, 1, 0, 0, 0, 0]), buf.slice(16, 32))
	# decoded with the buffer layout Godot documents (MultiMesh.buffer): rows of the transform, then the origin
	var t := Transform2D(Vector2(buf[0], buf[4]), Vector2(buf[1], buf[5]), Vector2(buf[3], buf[7]))
	check("2D transform as Godot reads it", t.origin.is_equal_approx(Vector2(30, 40)) \
		and near(t.get_rotation(), 0.25) and t.get_scale().is_equal_approx(Vector2(2, 3)), t)
	check("a second view of the same kind (stride 8)", plain_multi.visible_instance_count == 2 \
		and near_all(plain_multi.buffer.slice(0, 8), [c * 2, -s * 3, 0, 30, s * 2, c * 3, 0, 40]),
		plain_multi.buffer.slice(0, 8))
	var b3 := multi3d.buffer
	var t3 := Transform3D(Vector3(b3[0], b3[4], b3[8]), Vector3(b3[1], b3[5], b3[9]), Vector3(b3[2], b3[6], b3[10]),
		Vector3(b3[3], b3[7], b3[11]))
	check("3D smooth MultiMesh (yaw, scale per axis)", multi3d.visible_instance_count == 1 \
		and t3.origin.is_equal_approx(POS_3D) and near(t3.basis.get_euler().y, YAW_3D) \
		and t3.basis.get_scale().is_equal_approx(Vector3(1, 2, 1)) and near_all(b3.slice(12, 16), [0, 1, 0, 1]),
		[multi3d.visible_instance_count, t3])
	session.set_input_value(&"drift", 3.0)
	var y0: float = hud.get("y")
	for i in 20:
		await create_timer(0.02).timeout
	check("set_input_value reaches sample_input", hud.get("y") > y0, [y0, hud.get("y")])
	await check_commands(session, hud)
	finish(session)


# The events: every one on the sim_event signal as an object of its class, EMITTED once and then CONFIRMED or
# CANCELLED once, its fields typed properties; the subject's view gets them too (the player's view: the toy's
# things have no scene view, so `Spawned` falls back to its player).
func check_events(events: Array[Array], typed: Node) -> void:
	check("event states are class constants", UnifiedSession.EVENT_EMITTED == 0 \
		and UnifiedSession.EVENT_CONFIRMED == 1 and UnifiedSession.EVENT_CANCELLED == 2,
		[UnifiedSession.EVENT_EMITTED, UnifiedSession.EVENT_CONFIRMED, UnifiedSession.EVENT_CANCELLED])
	var joined := events.filter(func(e: Array) -> bool: return e[0] is EventJoined)
	check("sim_event: EventJoined, player 0, tick 1", joined.size() > 0 and (joined[0][0] as EventJoined).player == 0 \
		and (joined[0][0] as EventJoined).tick == 1, joined)
	check("Joined: emitted, then confirmed", joined.map(func(e: Array) -> int: return e[1]) \
		== [UnifiedSession.EVENT_EMITTED, UnifiedSession.EVENT_CONFIRMED], joined)
	var spawned := events.filter(func(e: Array) -> bool: return e[0] is EventSpawned)
	var first := spawned[0][0] as EventSpawned if spawned.size() > 0 else null
	check("Spawned: a handle as its key, the position a Vector2 in view units, the enum by name",
		first != null and first.thing > 0 and first.position.x > 1 and first.shape in [&"dot", &"ring", &"star"] \
		and first.player == 0, [first.thing, first.position, first.shape, first.player] if first else null)
	check("Spawned: emitted, then confirmed", spawned.map(func(e: Array) -> int: return e[1]) \
		== [UnifiedSession.EVENT_EMITTED, UnifiedSession.EVENT_CONFIRMED], spawned)
	var expired := events.filter(func(e: Array) -> bool: return e[0] is EventExpired)
	check("Expired: the same thing's key, confirmed last", expired.size() > 0 and first != null \
		and expired[-1][1] == UnifiedSession.EVENT_CONFIRMED and (expired[-1][0] as EventExpired).thing == first.thing,
		expired)
	var on_view: Array = (typed.get("events") as Array).filter(func(e: Array) -> bool:
		return e[0] is EventJoined or e[0] is EventSpawned)
	check("the player's view gets its events in both states", on_view.size() >= 4, typed.get("events"))


func check_commands(session: UnifiedSession, hud: Control) -> void:
	var bump := CommandBump.new()
	bump.amount = 5
	check("send_command Bump", session.send_command(bump))
	var bump2 := CommandBump.new()
	bump2.amount = -2
	check("send_command another Bump", session.send_command(bump2))
	var mark := CommandMark.new()
	mark.at = Vector2(1.5, -2)
	mark.normal = Vector3(0, 1, 0)
	mark.weight = 0.25
	mark.count = -300
	mark.shape = &"star"
	mark.shapes = [&"Dot", 2]
	mark.loud = true
	check("send_command Mark", session.send_command(mark))
	# refused: an error line names the problem, and send_command is false for a command holding a bad value
	var bad := CommandMark.new()
	bad.count = 40000
	check("out of range: refused", not session.send_command(bad))
	var bad_shape := CommandMark.new()
	bad_shape.shape = &"hexagon"
	check("not an enum member: refused", not session.send_command(bad_shape))
	check("an event is not a command", not session.send_command(EventJoined.new()))
	for i in 100:
		await create_timer(0.02).timeout
		if hud.get("bumps") >= 2 and hud.get("marks") >= 1:
			break
	check("the sim got each command once, in order", hud.get("bumps") == 2 and hud.get("bump_sum") == 3 \
		and hud.get("marks") == 1, [hud.get("bumps"), hud.get("bump_sum"), hud.get("marks")])
	check("Vector2 and Vector3 fields", hud.get("mark_at") == Vector2(1.5, -2) \
		and hud.get("mark_normal") == Vector3(0, 1, 0), [hud.get("mark_at"), hud.get("mark_normal")])
	check("float, int and bool fields", near(hud.get("mark_weight"), 0.25) and hud.get("mark_count") == -300 \
		and hud.get("mark_loud") == true, [hud.get("mark_weight"), hud.get("mark_count"), hud.get("mark_loud")])
	# shape "star"; shapes [Dot, 2 (Star)] = bits 0 and 2
	check("enum by name, bit_set by names and values", hud.get("mark_shape") == &"star" and hud.get("mark_shapes") == 5,
		[hud.get("mark_shape"), hud.get("mark_shapes")])


func finish(session: UnifiedSession) -> void:
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
