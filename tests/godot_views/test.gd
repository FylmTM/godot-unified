# unified:godot view tests: run headless by `uni test --suite godot-bindings`. A single player session of the toy
# game whose Glue (ext/ext.odin) shows fixed items; checks that scene views with a UnifiedView marker spawn from
# the view index (2D and 3D, identified by kind and key), get their pose, _sim_update and typed data as properties,
# and their lifecycle callbacks; that MultiMesh views get their buffers; that session data reaches Unified.data.toy and
# the constants Unified.constants; that enums are ints with Enum* classes; that events reach the views and the
# sim_event signal as objects of their classes in each state; that commands made from their classes reach the sim
# once (and wrong values are refused with an error line the suite expects); and that the input sample latches a
# press. Prints one line per check and "VIEWS TESTS: <n> failed"; exits with the failure count.
extends SceneTree

const POS_2D := Vector2(120, 80)
const ANGLE_2D := 0.5
const POS_3D := Vector3(1, 2, 3)
const YAW_3D := 0.75
const TUMBLE_3D := 0.3

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
	check_constants()
	var toy: DataToy = Unified.data.toy
	var toy_changes := [0]
	toy.changed.connect(func() -> void: toy_changes[0] += 1)
	var roster_changes := [0]
	session.roster_changed.connect(func() -> void: roster_changes[0] += 1)
	check("view_root before it is set: the session's parent", session.view_root == root)
	session.view_root = views
	check("view_root takes a Node2D", session.view_root == views)
	check("no session: no local player", session.get_local_player() == 0 and session.get_players().is_empty())
	var early := CommandBump.new()
	early.amount = 1
	check("send_command without a session: false", not session.send_command(early))
	check("start_single", session.start_single())

	var typed: Node = null
	var blink: Node2D = null
	var blink_despawned := false
	var blink_kept := false
	for i in 150:  # up to ~3 s
		await create_timer(0.02).timeout
		typed = child_of_kind(views, "typed2d")
		if blink == null:
			for child in views.get_children():
				var view_marker := child.get_node_or_null(^"UnifiedView") as UnifiedView
				if view_marker != null and view_marker.kind == "plain2d" and view_marker.entity == 5:
					blink = child as Node2D
		elif is_instance_valid(blink) and blink.get("despawns") == 1:
			blink_despawned = true
			blink_kept = blink_kept or blink.position == Vector2(999, 999)  # the host no longer sets its pose
		if i == 5:
			press(&"ui_accept", true)  # one press, shorter than a tick: latched until a tick takes it
		elif i == 6:
			press(&"ui_accept", false)
		if typed != null and typed.get("updates") > 1 and typed.get("ticks_sets") > 2 \
				and typed_multi.visible_instance_count == 2 and blink_despawned and not is_instance_valid(blink) \
				and events.any(func(e: Array) -> bool:
					return e[0] is EventExpired and e[1] == UnifiedSession.EVENT_CONFIRMED):
			break
	check("typed 2D view spawned from the index", typed != null, typed)
	if typed == null:
		await finish(session)
		print("VIEWS TESTS: %d failed" % failed)
		quit(failed)
		return
	check("Unified.session: the running session", Unified.session == session)
	var marker := typed.get("marker") as UnifiedView
	check("2D position = pos.xy", (typed as Node2D).position.is_equal_approx(POS_2D), (typed as Node2D).position)
	check("2D rotation = angle about Z", near((typed as Node2D).rotation, ANGLE_2D), (typed as Node2D).rotation)
	check("_sim_update(Vector2, rotation, alpha)", typed.get("last_position").is_equal_approx(POS_2D) \
		and near(typed.get("last_rotation"), ANGLE_2D), [typed.get("last_position"), typed.get("last_rotation")])
	var me := session.get_local_player()
	check("the marker: kind from the scene, player (its key) and entity (unset: the key) from the host", me != 0 \
		and marker.player == me and marker.kind == "typed2d" and marker.entity == 1,
		[me, marker.player, marker.kind, marker.entity])
	var plain := child_of_kind(views, "plain2d")
	check("plain Node2D view", plain != null and (plain.get("marker") as UnifiedView).entity == 7 \
		and plain.get("updates") > 0 and (plain as Node2D).position.is_equal_approx(POS_2D + Vector2(10, 0)), plain)
	var p3 := child_of_kind(views, "plain3d") as Node3D
	check("3D view under a 2D root", p3 != null and p3.position.is_equal_approx(POS_3D) \
		and near(p3.rotation.y, YAW_3D) and near(p3.get("last_yaw"), YAW_3D), [p3.position, p3.rotation] if p3 else null)
	check("the same key in another kind is another view, its entity the key", plain != null and p3 != null \
		and (p3.get("marker") as UnifiedView).entity == 2, (p3.get("marker") as UnifiedView).entity if p3 else null)
	check("a view that leaves gets _sim_despawned once and is no longer posed while it lingers, then is freed",
		blink_despawned and blink_kept and not is_instance_valid(blink), [blink_despawned, blink_kept])
	check("session data on Unified: typed, changed when it changes", toy.x > 0 and toy_changes[0] > 2,
		[toy.x, toy_changes[0]])
	check_events(events, typed, me)
	check("scene data as properties (an enum as its int)", typed.get("shown") and typed.get("mode") == 1 and typed.get("hp") == -3 \
		and near(typed.get("charge"), 0.5) and typed.get("dir").is_equal_approx(Vector2(0.6, -0.8)) \
		and typed.get("tint").is_equal_approx(Color(1, 0.5, 0.25, 1)),
		[typed.get("shown"), typed.get("mode"), typed.get("hp"), typed.get("charge"), typed.get("dir"), typed.get("tint")])
	check("scene data set only when it changes", typed.get("hp_sets") == 1 and typed.get("ticks_sets") > 2,
		[typed.get("hp_sets"), typed.get("ticks_sets")])
	check("one latched press spawned one thing", toy.spawned == 1, toy.spawned)
	check_players(session, me, roster_changes[0])

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
	var want_rot := Quaternion(Vector3.UP, YAW_3D) * Quaternion(Vector3.RIGHT, TUMBLE_3D)
	var got_rot := t3.basis.orthonormalized().get_rotation_quaternion()
	check("3D smooth MultiMesh (a full rotation, scale per axis)", multi3d.visible_instance_count == 1 \
		and t3.origin.is_equal_approx(POS_3D) and (got_rot.is_equal_approx(want_rot) or got_rot.is_equal_approx(-want_rot)) \
		and t3.basis.get_scale().is_equal_approx(Vector3(1, 2, 1)) and near_all(b3.slice(12, 16), [0, 1, 0, 1]),
		[multi3d.visible_instance_count, t3, want_rot])
	session.set_input_value(&"drift", 3.0)
	var y0 := toy.y
	for i in 20:
		await create_timer(0.02).timeout
	check("set_input_value reaches sample_input", toy.y > y0, [y0, toy.y])
	await check_commands(session, toy)
	await finish(session)
	check("session data back to zero when the session ends", toy.bumps == 0 and toy.x == 0.0, [toy.bumps, toy.x])
	print("VIEWS TESTS: %d failed" % failed)
	quit(failed)


# The constants (Unified.constants: Data_Constants in ext/ext.odin) and an enum class, before any session.
func check_constants() -> void:
	var constants: UnifiedConstants = Unified.constants
	check("constants: typed, strings and nested values", near(constants.speed, 4.5) and constants.name == "toy" \
		and constants.favorite == EnumShape.RING and constants.sizes == [1, 2, 3] \
		and constants.limits == {"low": -1, "high": 9} and constants.by_shape == [0.5, 1.0, 2.0],
		[constants.speed, constants.name, constants.favorite, constants.sizes, constants.limits])
	var sizes: Array[int] = constants.sizes  # a typed Array: assigning it to Array[int] would fail otherwise
	var by_shape: Array[float] = constants.by_shape
	check("constants: arrays typed by their elements", sizes.get_typed_builtin() == TYPE_INT 		and by_shape.get_typed_builtin() == TYPE_FLOAT, [sizes.get_typed_builtin(), by_shape.get_typed_builtin()])
	check("read-only properties have no default for the editor's help",
		ClassDB.class_get_property_default_value(&"UnifiedConstants", &"sizes") == null,
		ClassDB.class_get_property_default_value(&"UnifiedConstants", &"sizes"))
	check("Unified.tick_hz", Unified.tick_hz == 64, Unified.tick_hz)
	check("an enum class: members as constants, name()", EnumShape.DOT == 0 and EnumShape.STAR == 2 \
		and EnumShape.name(EnumShape.STAR) == "star", [EnumShape.DOT, EnumShape.STAR, EnumShape.name(2)])


# The session's players, by key: the local one in slot 0, present and remembered, named from the roster; no platform
# account in single player; an unknown key answers nothing.
func check_players(session: UnifiedSession, me: int, roster_changes: int) -> void:
	check("get_players / get_known_players: the local player", session.get_players() == [me] \
		and session.get_known_players() == [me], [session.get_players(), session.get_known_players()])
	check("get_player_slot / is_player_present", session.get_player_slot(me) == 0 and session.is_player_present(me) \
		and session.get_player_slot(me + 1) == -1 and not session.is_player_present(0),
		[session.get_player_slot(me), session.get_player_slot(me + 1)])
	var nobody := me + 0x10000  # another member id: nobody the session knows
	check("the local player's name from the roster", session.get_player_name(me) == "player" \
		and session.get_player_name(nobody) == "", [session.get_player_name(me), session.get_player_name(nobody)])
	check("no platform account in single player", session.get_player_platform(me) == "" \
		and session.get_player_platform_id(me) == "", [session.get_player_platform(me), session.get_player_platform_id(me)])
	check("roster_changed when the roster came", roster_changes > 0, roster_changes)


# The events: every one on the sim_event signal as an object of its class, EMITTED once and then CONFIRMED or
# CANCELLED once, its fields typed properties; the subject's view gets them too (the player's view: the toy's
# things have no scene view, so `Spawned` falls back to its player).
func check_events(events: Array[Array], typed: Node, me: int) -> void:
	check("event states are class constants", UnifiedSession.EVENT_EMITTED == 0 \
		and UnifiedSession.EVENT_CONFIRMED == 1 and UnifiedSession.EVENT_CANCELLED == 2,
		[UnifiedSession.EVENT_EMITTED, UnifiedSession.EVENT_CONFIRMED, UnifiedSession.EVENT_CANCELLED])
	var joined := events.filter(func(e: Array) -> bool: return e[0] is EventPlayerJoined)
	var join := joined[0][0] as EventPlayerJoined if joined.size() > 0 else null
	check("sim_event: EventPlayerJoined, the local player in slot 0 at tick 1, new", join != null \
		and join.player == me and join.slot == 0 and not join.returning and join.tick == 1,
		[join.player, join.slot, join.returning, join.tick] if join else joined)
	check("PlayerJoined: emitted, then confirmed", joined.map(func(e: Array) -> int: return e[1]) \
		== [UnifiedSession.EVENT_EMITTED, UnifiedSession.EVENT_CONFIRMED], joined)
	var spawned := events.filter(func(e: Array) -> bool: return e[0] is EventSpawned)
	var first := spawned[0][0] as EventSpawned if spawned.size() > 0 else null
	check("Spawned: a handle as its key, the position a Vector2 in view units, the enum an int",
		first != null and first.thing > 0 and first.position.x > 1 and first.shape in [EnumShape.DOT, EnumShape.RING, EnumShape.STAR] \
		and first.player == me, [first.thing, first.position, first.shape, first.player] if first else null)
	check("Spawned: emitted, then confirmed", spawned.map(func(e: Array) -> int: return e[1]) \
		== [UnifiedSession.EVENT_EMITTED, UnifiedSession.EVENT_CONFIRMED], spawned)
	var expired := events.filter(func(e: Array) -> bool: return e[0] is EventExpired)
	check("Expired: the same thing's key, confirmed last", expired.size() > 0 and first != null \
		and expired[-1][1] == UnifiedSession.EVENT_CONFIRMED and (expired[-1][0] as EventExpired).thing == first.thing,
		expired)
	var on_view: Array = (typed.get("events") as Array).filter(func(e: Array) -> bool:
		return e[0] is EventPlayerJoined or e[0] is EventSpawned)
	check("the player's view gets its events in both states", on_view.size() >= 4, typed.get("events"))


func check_commands(session: UnifiedSession, toy: DataToy) -> void:
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
	mark.shape = EnumShape.STAR
	mark.shapes = [EnumShape.DOT, 2]
	mark.loud = true
	mark.target = (7 << 32) | 3  # a handle's key: generation 7, index 3
	mark.place = Vector2(30, 40)  # view units (pixels): the sim gets them in its units
	mark.area = {"corner": Vector2(1, 2), "layer": 3}  # a nested struct; `_pad` is left out
	check("a position reads back as it was set", mark.place == Vector2(30, 40), mark.place)
	check("send_command Mark", session.send_command(mark))
	# refused: an error line names the problem, and send_command is false for a command holding a bad value
	var bad := CommandMark.new()
	bad.count = 40000
	check("out of range: refused", not session.send_command(bad))
	var bad_shape := CommandMark.new()
	bad_shape.shape = 7
	check("not an enum member: refused", not session.send_command(bad_shape))
	var bad_handle := CommandMark.new()
	bad_handle.target = 3  # generation 0: no handle's key
	check("not a handle's key: refused", not session.send_command(bad_handle))
	var bad_area := CommandMark.new()
	bad_area.area = {"corner": Vector2(1, 2), "depth": 1}
	check("a key that names no field: refused", not session.send_command(bad_area))
	check("an event is not a command", not session.send_command(EventPlayerJoined.new()))
	for i in 100:
		await create_timer(0.02).timeout
		if toy.bumps >= 2 and toy.marks >= 1:
			break
	check("the sim got each command once, in order", toy.bumps == 2 and toy.bump_sum == 3 and toy.marks == 1,
		[toy.bumps, toy.bump_sum, toy.marks])
	check("Vector2 and Vector3 fields", toy.mark_at == Vector2(1.5, -2) and toy.mark_normal == Vector3(0, 1, 0),
		[toy.mark_at, toy.mark_normal])
	check("float, int and bool fields", near(toy.mark_weight, 0.25) and toy.mark_count == -300 and toy.mark_loud,
		[toy.mark_weight, toy.mark_count, toy.mark_loud])
	var shapes: Array[int] = toy.mark_shapes
	check("an enum as its int, a bit_set as an Array[int]", toy.mark_shape == EnumShape.STAR \
		and shapes == [EnumShape.DOT, EnumShape.STAR], [toy.mark_shape, toy.mark_shapes])
	check("a handle as its key", toy.mark_target == (7 << 32) | 3, toy.mark_target)
	check("a position in sim units", toy.mark_place == Vector3(3, 4, 0), toy.mark_place)
	check("a nested struct from a Dictionary", toy.mark_area == {"corner": Vector2(1, 2), "layer": 3},
		toy.mark_area)
	check("Godot's own types as they are", toy.tint == Vector4(1, 2, 3, 4) and toy.turn == Quaternion.IDENTITY,
		[toy.tint, toy.turn])


func finish(session: UnifiedSession) -> void:
	session.leave()
	for i in 50:
		if not session.is_running():
			break
		await create_timer(0.02).timeout
	root.get_child(0).queue_free()
	session.queue_free()
	await process_frame
