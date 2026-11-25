# unified:godot view tests: run headless by `uni test --suite godot-bindings`. A single player session of the toy
# game whose Glue (ext/ext.odin) shows fixed items; checks that scene views with a UnifiedView marker spawn from
# the view index (2D and 3D, identified by kind and key), get their pose, their pose before their own _process and their data (one object of their kind's class),
# and their lifecycle callbacks; that MultiMesh views get their buffers; that session data reaches Unified.data.toy and
# the constants Unified.constants; that enums are ints with Enum* classes; that events reach the views and the
# sim_event signal as objects of their classes in each state; that commands made from their classes reach the sim
# once (and wrong values are refused with an error line the suite expects); and that the input sample latches a
# press. Prints one line per check and "VIEWS TESTS: <n> failed"; exits with the failure count.
extends SceneTree

const Card := preload("res://views/card.gd")
const PoolView := preload("res://views/pool2d.gd")
const PoolLateView := preload("res://views/pool_late2d.gd")
const POS_2D := Vector2(120, 80)
const ANGLE_2D := 0.5
const POS_3D := Vector3(1, 2, 3)
const YAW_3D := 0.75
const TUMBLE_3D := 0.3
# ext/ext.odin's remote walk, in view units (x VIEW_SCALE)
const REMOTE_SPEED := 0.1
const REMOTE_JUMP := 20.0
const REMOTE_PERIOD := 64
const REMOTE_EVENT_EVERY := 16  # the remote player's events: a tick each REMOTE_EVENT_EVERY, at REMOTE_EVENT_AT
const REMOTE_EVENT_AT := 10
const REMOTE_STALL_TICKS := 14  # a long frame: playback jumps (VERIFIED_WINDOW_TICKS) or strides past an event's tick
const REMOTE_PLAYER_KEY := (77 << 16) | 3  # sim.player_key(REMOTE_PLAYER)
const REMOTE_BLINK_KEY := (78 << 16) | 2  # sim.player_key(REMOTE_BLINK)
const REMOTE_BLINK_FROM := 60
const REMOTE_BLINK_TO := 100
# ext/ext.odin's pooled views (pool_views)
const POOL_KEY := 1000
const POOL_BLIP_KEY := 2000
const POOL_EVENT_PLAYER_KEY := (79 << 16) | 1  # sim.player_key(POOL_EVENT_PLAYER)

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


func multimesh_view(parent: Node, two_d: bool, colors: bool, custom: bool, kind: String) -> MultiMesh:
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
	var multi3d := multimesh_view(world, false, true, false, "smooth3d")  # smooth: GLUE.multi_policy
	const GAME_BOUNDS := AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	plain_multi.custom_aabb = GAME_BOUNDS  # the game's own bounds: the host keeps them
	var views := Node2D.new()
	world.add_child(views)
	var hand := HBoxContainer.new()  # the cards' parent (card.tscn's parent_path), laying them out in a row
	hand.name = "Hand"
	views.add_child(hand)
	var session := UnifiedSession.new()
	session.local_name = "player"
	root.add_child(session)
	var events: Array[Array] = []  # [event, state]
	session.sim_event.connect(func(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
		events.append([event, state]))
	check_constants()
	check_setup_json()
	var toy: DataToy = Unified.data.toy
	var toy_changes := [0]
	toy.changed.connect(func() -> void: toy_changes[0] += 1)
	var roster_changes := [0]
	session.roster_changed.connect(func() -> void: roster_changes[0] += 1)
	check("view_root before it is set: the session's parent", session.view_root == root)
	session.view_root = views
	check("view_root takes a Node2D", session.view_root == views)
	var level_root := Node2D.new()
	world.add_child(level_root)
	session.level_root = level_root
	var level_signals: Array[String] = []
	session.level_changing.connect(func(to: int) -> void: level_signals.append("changing %d" % to))
	session.level_changed.connect(func(level: int) -> void: level_signals.append("changed %d" % level))
	check("no session: no level", session.level == -1 and session.level_scene == null, session.level)
	check("no session: no local player", session.local_player == 0 and session.players.is_empty() \
		and session.status == UnifiedSession.STATUS_IDLE and not session.running, [session.local_player, session.status])
	var early := CommandBump.new()
	early.amount = 1
	check("send_command without a session: false", not session.send_command(early))
	check("start_single", session.start_single())

	var typed: Node = null
	var decoy_events: Array = []  # a decoy view's (another table's handle with a thing's key): it gets no event
	var decoys_seen := false
	var blink: Node2D = null
	var blink_despawned := false
	var blink_kept := false
	var card: Control = null  # the thing's data-only view, followed until it is freed
	var remote_blink: Node3D = null  # ext/ext.odin's REMOTE_BLINK's remote3d view, followed until it despawns
	var remote_blink_seen := {}
	var card_seen := {}  # what it showed while alive
	for i in 150:  # up to ~3 s
		await create_timer(0.02).timeout
		typed = child_of_kind(views, "typed2d")
		var decoy := child_of_kind(views, "decoy2d")
		if decoy != null and not decoys_seen:
			decoys_seen = true
			decoy_events = decoy.get("events")
		if blink == null:
			for child in views.get_children():
				var view_marker := child.get_node_or_null(^"UnifiedView") as UnifiedView
				if view_marker != null and view_marker.kind == "plain2d" and view_marker.key == 5:
					blink = child as Node2D
		elif is_instance_valid(blink) and blink.get("despawns") == 1:
			blink_despawned = true
			blink_kept = blink_kept or blink.position == Vector2(999, 999)  # the host no longer sets its pose
		if remote_blink == null:
			for child in views.get_children():
				var view_marker := child.get_node_or_null(^"UnifiedView") as UnifiedView
				if view_marker != null and view_marker.kind == "remote3d" and view_marker.key == REMOTE_BLINK_KEY:
					remote_blink = child as Node3D
		if remote_blink != null and is_instance_valid(remote_blink):
			for field: String in ["shown_early", "poses", "despawns", "despawn_tick", "despawn_session_tick"]:
				remote_blink_seen[field] = remote_blink.get(field)
		if card == null:
			card = child_of_kind(hand, "card") as Control
			if card != null:
				card_seen = {events = card.get("events"), positions = []}
		if card != null and is_instance_valid(card):
			card_seen.first_life = card.get("life_at_first_process")
			card_seen.life_sets = card.get("life_sets")
			card_seen.despawns = card.get("despawns")
			card_seen.parent = card.get_parent()
			(card_seen.positions as Array).append(card.position)
		if i == 5:
			press(&"ui_accept", true)  # one press, shorter than a tick: latched until a tick takes it
		elif i == 6:
			press(&"ui_accept", false)
		if typed != null and typed.get("updates") > 1 and typed.get("ticks_sets") > 2 \
				and typed_multi.visible_instance_count == 2 and blink_despawned and not is_instance_valid(blink) \
				and card != null and not is_instance_valid(card) and remote_blink_seen.get("despawns", 0) > 0 \
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
	check("a view's _process sees the pose of the frame", typed.get("last_position").is_equal_approx(POS_2D) \
		and near(typed.get("last_rotation"), ANGLE_2D), [typed.get("last_position"), typed.get("last_rotation")])
	var me := session.local_player
	check("status and tick properties", session.status == UnifiedSession.STATUS_CONNECTED and session.running \
		and session.tick > 0, [session.status, session.tick])
	check("the link in single player: the floor's delay, the game's ceiling, never slow, the host heard from",
		session.input_delay_ticks == 1 and session.round_trip_ceiling_ms > 200.0 and not session.link_slow \
		and session.round_trip_ms < 5.0 and session.host_silent_ms < 1000.0,
		[session.input_delay_ticks, session.round_trip_ceiling_ms, session.link_slow, session.round_trip_ms,
		session.host_silent_ms])
	check("the marker: kind from the scene, player and key from the host (the player's)", me != 0 \
		and marker.player == me and marker.kind == "typed2d" and marker.key == me,
		[me, marker.player, marker.kind, marker.key])
	var plain := child_of_kind(views, "plain2d")
	check("plain Node2D view", plain != null and (plain.get("marker") as UnifiedView).key == 2 \
		and plain.get("updates") > 0 and (plain as Node2D).position.is_equal_approx(POS_2D + Vector2(10, 0)), plain)
	var p3 := child_of_kind(views, "plain3d") as Node3D
	check("3D view under a 2D root", p3 != null and p3.position.is_equal_approx(POS_3D) \
		and near(p3.rotation.y, YAW_3D) and near(p3.get("last_yaw"), YAW_3D), [p3.position, p3.rotation] if p3 else null)
	var scripted := child_of_kind(views, "scripted3d") as Node3D
	check("a script-posed kind: its script gets _sim_pose (view units) and keeps the transform it set",
		scripted != null and scripted.get("poses") > 0 and scripted.get("sim_position").is_equal_approx(POS_3D) \
		and (scripted.get("sim_rotation") as Quaternion).is_equal_approx(Quaternion(Vector3.UP, YAW_3D)) \
		and scripted.position.is_equal_approx(scripted.get("OWN_POSITION")),
		[scripted.get("poses"), scripted.get("sim_position"), scripted.position] if scripted else null)
	if scripted != null:
		var poses: int = scripted.get("poses")
		for i in 5:
			await create_timer(0.02).timeout
		check("an unchanged pose is not handed over again", scripted.get("poses") == poses,
			[poses, scripted.get("poses")])
	check("the same key in another kind is another view", plain != null and p3 != null \
		and (p3.get("marker") as UnifiedView).key == 2, (p3.get("marker") as UnifiedView).key if p3 else null)
	check("a view that leaves gets _sim_despawned once and is no longer posed while it lingers, then is freed",
		blink_despawned and blink_kept and not is_instance_valid(blink), [blink_despawned, blink_kept])
	check("session data on Unified: typed, changed when it changes", toy.x > 0 and toy_changes[0] > 2,
		[toy.x, toy_changes[0]])
	check("Unified.view_scale: the Glue's", near(Unified.view_scale, 10.0), Unified.view_scale)
	check("a sim.Position in session data: view units (x 10), a Vector2",
		toy.at.is_equal_approx(Vector2(toy.x, toy.y) * 10.0), [toy.at, toy.x, toy.y])
	check_events(events, typed, me)
	check_card(card, card_seen, hand)
	check("by subject type: a view of another table's handle with the thing's key gets none of its events",
		decoys_seen and decoy_events.is_empty(), decoy_events)
	check("an enum only a view kind uses has its class", EnumMode.OPEN == 1, EnumMode.OPEN)
	var data: ViewTyped2d = typed.get("data")
	check("a view's data: an object of its kind's class", data != null and data is ViewTyped2d, data)
	if data == null:
		return
	check("a view kind's nested struct: an object of its class", data.area is DataMarkArea and data.area.layer == 3,
		data.area)
	check("a view data's nested struct: the same object on every read", data.area == data.area, data.area)
	check("a view's data fields (an enum as its int)", data.shown and data.mode == EnumMode.OPEN and data.hp == -3 \
		and near(data.charge, 0.5) and data.dir.is_equal_approx(Vector2(0.6, -0.8)) \
		and data.tint.is_equal_approx(Color(1, 0.5, 0.25, 1)),
		[data.shown, data.mode, data.hp, data.charge, data.dir, data.tint])
	check("a view's data is set before its _ready", typed.get("data_at_ready") is ViewTyped2d \
		and (typed.get("data_at_ready") as ViewTyped2d).hp == -3, typed.get("data_at_ready"))
	check("a view's data is set anew only when its bytes change, a new object each time",
		typed.get("hp_sets") == 1 and typed.get("ticks_sets") > 2 and typed.get("data_sets") == typed.get("ticks_sets") \
		and typed.get("data_at_ready") != data, [typed.get("hp_sets"), typed.get("ticks_sets"), typed.get("data_sets")])
	check("one latched press spawned one thing", toy.spawned == 1, toy.spawned)
	check_players(session, me, roster_changes[0])
	check_view_lookup(session, typed, plain, me)
	await check_hand(session, hand, me)
	check_remote_blink(remote_blink_seen)
	await check_remote_views(session, views, me)
	await check_pool(events, me)

	# 2D, colors + custom: stride 16 = transform (8) + color (4) + custom (4)
	check("2D MultiMesh instances", typed_multi.visible_instance_count == 2, typed_multi.visible_instance_count)
	var buf := typed_multi.buffer
	var c := cos(0.25)
	var s := sin(0.25)
	# custom channel 3 is an age (multi_policy ages): the game time 4 it holds, as seconds since, at the shown time
	var age := (session.shown_time - 4.0) / Unified.tick_hz
	check("2D buffer (rotation on the shorter arc, scale per axis, position, color, custom)",
		near_all(buf.slice(0, 15), [c * 2, -s * 3, 0, 30, s * 2, c * 3, 0, 40, 1, 0.5, 0.25, 1, 1, 2, 3]),
		buf.slice(0, 16))
	check("an age channel is the seconds since its game time, at the shown time", age > 0.0 		and absf(buf[15] - age) <= 1.0 / Unified.tick_hz, [buf[15], age])
	check("2D defaults (scale 1, white)",
		near_all(buf.slice(16, 31), [1, 0, 0, -5, 0, 1, 0, 7.5, 1, 1, 1, 1, 0, 0, 0]), buf.slice(16, 32))
	# the kind's age channel on an instance that set none: game time 0, so the seconds since the session's start
	var since_start := session.shown_time / Unified.tick_hz
	check("an unset age channel is the seconds since game time 0", absf(buf[31] - since_start) <= 1.0 / Unified.tick_hz,
		[buf[31], since_start])
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
	# bounds: the host sets custom_aabb (Godot needn't recompute it from the buffer), holding every instance's mesh
	check("3D bounds hold the instance", multi3d.custom_aabb.encloses(t3 * multi3d.mesh.get_aabb()),
		[multi3d.custom_aabb, t3 * multi3d.mesh.get_aabb()])
	var bounds2d := typed_multi.custom_aabb
	check("2D bounds hold every instance", bounds2d.has_surface() and bounds2d.grow(0.001).has_point(Vector3(30, 40, 0)) 		and bounds2d.grow(0.001).has_point(Vector3(-5, 7.5, 0)) and bounds2d.size.x > 35 + 2 * sqrt(0.5) * 3 - 0.01, bounds2d)
	check("a game's own custom_aabb is kept", plain_multi.custom_aabb == GAME_BOUNDS, plain_multi.custom_aabb)
	await check_debug_draws(session)
	await check_game_input(session, toy)
	var input: UnifiedInput = Unified.input
	var wanted := [0]
	session.input_wanted.connect(func() -> void: wanted[0] += 1)
	input.drift = 3.0
	check("Unified.input reads back as set", near(input.drift, 3.0), input.drift)
	check("a sim.Entity as its index (-1: none)", toy.lamp == 4 and toy.no_lamp == -1, [toy.lamp, toy.no_lamp])
	check("a sim.Bits: an Array of its indices", toy.open == [1, 7], toy.open)
	check("a sim.Queue: an Array of its items, oldest first", toy.queue == [2, 3, 4], toy.queue)
	check("a sim.List of handles: an Array of their keys, typed", toy.recent.get_typed_builtin() == TYPE_INT \
		and toy.recent.all(func(key: int) -> bool: return key > 0), toy.recent)
	check("a sim.List field starts empty", input.picks.is_empty(), input.picks)
	input.picks = [3, 1]
	check("a sim.List set as an Array reads back", input.picks == [3, 1], input.picks)
	input.picks = [1, 2, 3, 4]  # past its capacity: refused with an error line, the value kept
	check("a sim.List past its capacity is refused", input.picks == [3, 1], input.picks)
	input.picks = [300]  # an item its type can't hold: refused, the value kept
	input.set(&"picks", ["a"])  # not an int (untyped: the parser would refuse it)
	check("a sim.List item that doesn't fit is refused", input.picks == [3, 1], input.picks)
	input.flags = [2, 9]
	check("a sim.Bits set as its indices reads back", input.flags == [2, 9], input.flags)
	input.flags = [10]  # past its size: refused
	check("a sim.Bits index past its size is refused", input.flags == [2, 9], input.flags)
	input.order = [5, 6]
	check("a sim.Queue set as an Array reads back, oldest first", input.order == [5, 6], input.order)
	input.grid = [1, -2, 3]
	check("a fixed array set as an Array reads back", input.grid == [1, -2, 3], input.grid)
	input.grid = [1, 2]  # not its length: refused with an error line, the value kept
	check("a fixed array of another length is refused", input.grid == [1, -2, 3], input.grid)
	input.by_shape = [4, 5, 6]
	check("an enumerated array set as an Array reads back, by its enum's order", input.by_shape == [4, 5, 6], input.by_shape)
	var areas: Array[DataMarkArea] = toy.areas  # typed by its class: assigning it would fail otherwise
	check("a sim.List of nested structs: an Array of their class", areas.size() == 2 and areas[1].layer == 6 \
		and areas[1].corner == Vector2(4, 5), areas)
	check("an Entity field starts as none", input.pick == -1, input.pick)
	input.pick = 2
	var picked := input.pick
	input.pick = -2  # no thing's index: refused with an error line, the value kept
	check("an Entity set as its index reads back; below -1 refused", picked == 2 and input.pick == 2, [picked, input.pick])
	input.pick = -1
	check("an Entity set to -1 is none", input.pick == -1, input.pick)
	var y0 := toy.y
	for i in 20:
		await create_timer(0.02).timeout
	check("Unified.input reaches sample_input", toy.y > y0, [y0, toy.y])
	check("input_wanted: every frame before the sample", wanted[0] >= 15, wanted[0])
	await check_levels(session, level_root, level_signals)
	await check_commands(session, toy)
	await check_nested_values(session, toy)
	await check_dropped_load(session)
	await finish(session)
	check("session data back to zero when the session ends", toy.bumps == 0 and toy.x == 0.0, [toy.bumps, toy.x])
	await check_unnamed()
	print("VIEWS TESTS: %d failed" % failed)
	quit(failed)


# The remote walk (ext/ext.odin's remote_walk): one walk shown by a remote player, the local player, a predicted3d view of
# the remote player, and a thing whose player alternates each half period. The remote player's view is posed from the
# verified timeline, a few ticks behind the local player's, which is posed from the prediction; it snaps across each
# jump (a warp: no glide through the gap between the walk's two stretches); its data is its sample's; its events
# arrive CONFIRMED only, when its pose reaches their tick. The predicted3d kind keeps the remote player on the
# prediction; the thing's view follows the remote timeline while it shows the remote player, the prediction while it
# shows the local one.
func check_remote_views(session: UnifiedSession, views: Node, me: int) -> void:
	var remote: Node3D = null
	var local: Node3D = null
	var predicted: Node3D = null
	var thing: Node3D = null
	var compared_frames := 0  # frames the four views were compared in (away from a jump)
	var predicted_off: Array[float] = []  # predicted3d x away from the local player's view's (the same walk)
	var off_walk: Array[float] = []  # remote x outside the walk's two stretches: a glide across a jump
	var thing_remote := [0, 0]  # frames the thing matched the remote view / were compared, showing the remote player
	var thing_local := [0, 0]  # and the local view, showing the local player
	var start := session.tick
	for i in 200:  # up to ~4 s, until a period has passed
		await create_timer(0.02).timeout
		if session.tick > start + REMOTE_PERIOD + 8:
			break
		for child in views.get_children():
			var view_marker := child.get_node_or_null(^"UnifiedView") as UnifiedView
			if view_marker == null:
				continue
			if view_marker.kind == "rider3d":
				thing = child as Node3D
			elif view_marker.kind == "predicted3d":
				predicted = child as Node3D
			elif view_marker.kind == "remote3d" and view_marker.key == me:
				local = child as Node3D
			elif view_marker.kind == "remote3d" and view_marker.key != REMOTE_BLINK_KEY:
				remote = child as Node3D
		if remote == null or local == null or thing == null or predicted == null:
			continue
		var x := remote.position.x
		if not (x > -0.01 and x < 3.11) and not (x > 23.19 and x < 26.31):
			off_walk.append(x)
		var phase := session.tick % (REMOTE_PERIOD / 2)
		if phase < 14 or phase > 30:
			continue  # near a jump the views may stand on either side of it
		compared_frames += 1
		if absf(predicted.position.x - local.position.x) > 0.01:
			predicted_off.append(predicted.position.x - local.position.x)
		if session.tick % REMOTE_PERIOD < REMOTE_PERIOD / 2:
			thing_remote[1] += 1
			thing_remote[0] += int(absf(thing.position.x - x) < 0.01)
		else:
			thing_local[1] += 1
			thing_local[0] += int(absf(thing.position.x - local.position.x) < 0.01)
	# A long frame (the main thread stalls while the session steps on, as under load) just before an event's tick is
	# verified: the next frame's playback strides past that tick and the same frame drains its confirmation, which must
	# come in that frame too, not held for the next.
	var stalled_event := -1
	for i in 200:
		if remote == null:
			break
		var until := posmod(REMOTE_EVENT_AT - session.verified_tick, REMOTE_EVENT_EVERY)
		if until >= 1 and until <= 3:
			stalled_event = session.verified_tick + until
			OS.delay_msec(int(1000.0 * REMOTE_STALL_TICKS / Unified.tick_hz))
			break
		await process_frame
	for i in 10:
		await process_frame
	check("the remote walk: a remote player's, the local player's, a predicted3d and a thing's views", remote != null \
		and local != null and predicted != null and thing != null, [remote, local, predicted, thing])
	if remote == null or local == null:
		return
	check("a Remote.Predicted kind showing the remote player stays on the prediction: no lag",
		compared_frames > 0 and predicted_off.is_empty(), predicted_off)
	check("it snaps across a warp: never posed between the walk's two stretches", off_walk.is_empty(), off_walk)
	check("a thing's view showing the remote player is on the verified timeline, the local player on the prediction",
		thing_remote[1] > 5 and thing_local[1] > 5 and thing_remote[0] == thing_remote[1] \
		and thing_local[0] == thing_local[1], [thing_remote, thing_local])
	check("hidden until its first sample: never shown without data", not remote.get("shown_early"),
		remote.get("shown_early"))
	# Each frame: the pose's tick (its data's tick plus how far the pose is past that tick's place on the walk) is never past the shown frame's verified tick, and never before its data's (the data is the sample at
	# or before the pose: a prediction's would be ahead of it).
	var pose_off: Array = []
	var compared := 0
	var delayed := 0  # frames whose pose stood 2 ticks or more behind the frame's verified tick
	for pose: Array in remote.get("poses"):
		var pose_tick := remote_pose_tick(pose)
		compared += 1
		if pose_tick < (pose[1] as int) - 0.01 or pose_tick > (pose[2] as int) + 0.01:
			pose_off.append([pose_tick, pose[1], pose[2]])
		delayed += int(pose_tick <= (pose[2] as int) - 2 + 0.01)
	check("on the verified timeline: its pose is final (at most the verified tick), its data its sample's",
		compared > 20 and pose_off.is_empty(), [compared, pose_off.slice(0, 5)])
	# Behind, by the session's own counters rather than frame timing: its playback aims VERIFIED_DELAY_TICKS behind the
	# newest verified tick and never passes it, so most frames find it 2 ticks or more behind (load only makes the lag
	# larger; the local player's view, on the prediction, is at the shown tick).
	check("a remote player's view of a Remote.Verified kind plays back behind the newest verified tick",
		compared > 20 and delayed * 2 >= compared, [delayed, compared])
	# Each event arrives in the first frame whose pose reached its tick: after the frame before's pose tick, at most
	# this frame's.
	var remote_events: Array = remote.get("events")
	var mistimed := remote_events.filter(func(e: Array) -> bool:
		var tick: int = (e[0] as UnifiedEvent).tick
		var now := remote_pose_tick(e[2] as Array)
		var before := remote_pose_tick(e[3] as Array) if not (e[3] as Array).is_empty() else -1.0
		return tick > now + 0.01 or (before >= 0 and tick <= before - 0.01))
	check("its events arrive CONFIRMED only, when its pose reaches their tick (never before, never a frame late)",
		remote_events.size() >= 2 and remote_events.all(func(e: Array) -> bool:
			return e[1] == UnifiedSession.EVENT_CONFIRMED) and mistimed.is_empty(),
		[remote_events.size(), mistimed.map(func(e: Array) -> Array: return [e[0].tick, e[2], e[3]])])
	check("the event of a tick a long frame's playback strode past arrived (in that frame: above)", stalled_event > 0 \
		and remote_events.any(func(e: Array) -> bool: return (e[0] as UnifiedEvent).tick == stalled_event),
		stalled_event)
	var stray := (local.get("events") as Array).filter(func(e: Array) -> bool: return e[0].get("player") != me)
	check("its events are the remote player's, none reach the local player's view of the kind", stray.is_empty() \
		and remote_events.all(func(e: Array) -> bool: return e[0].get("player") == REMOTE_PLAYER_KEY), stray)


# A remote player's view whose key leaves (ext/ext.odin's REMOTE_BLINK, ticks REMOTE_BLINK_FROM ..< REMOTE_BLINK_TO):
# hidden until its first sample, it keeps playing after the prediction dropped it and despawns once its pose reached
# its last tick.
func check_remote_blink(seen: Dictionary) -> void:
	check("a remote player's view that leaves: seen, then despawned", seen.get("despawns", 0) == 1, seen.keys())
	if seen.get("despawns", 0) != 1:
		return
	var poses: Array = seen.poses
	check("hidden until its first sample", not seen.shown_early and poses.size() > 0
		and poses[0][1] >= REMOTE_BLINK_FROM, poses.slice(0, 2))
	var last: Array = poses[-1] if poses.size() > 0 else [0.0, 0, 0]
	# where its last shown pose was on its walk, in ticks (its lane: REMOTE_SPEED a tick from REMOTE_BLINK_FROM)
	var last_tick: float = (last[0] as float) / REMOTE_SPEED + REMOTE_BLINK_FROM
	check("it despawns once playback reached the tick it left at (its pose at its last ticks), not when the prediction dropped it",
		last_tick >= REMOTE_BLINK_TO - 3 and last_tick <= REMOTE_BLINK_TO - 1 + 0.01 \
		and seen.despawn_session_tick > REMOTE_BLINK_TO, [last_tick, seen.despawn_session_tick, last])


# The pooled kinds (ext/ext.odin's pool_views; views/pool2d.gd and pool_late2d.gd log every callback of every
# instance): a view whose linger ended goes into its kind's pool (its data set to null) and the kind's next spawn takes
# that node back, its key, player, data and pose the new item's before _sim_reused, _ready not again; events reach it
# under its new key only; a key gone for less than its linger is revived, never pooled; the pool grows to the most
# views of the kind out at once; a pooled kind that appears on verified is reused; a kind without
# the marker's pool is freed (the plain2d blink above). (A single player session shows only verified ticks, so no
# spawn is ever cancelled here: a cancelled view goes into the pool by the same path as one whose linger ended.)
func check_pool(events: Array[Array], me: int) -> void:
	var log := PoolView.log
	var late_log := PoolLateView.log
	var deadline := Time.get_ticks_msec() + 8000  # the schedule's period is half a second
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
		if _whats(log, "reused") >= 4 and _whats(log, "revived") >= 2 and _whats(late_log, "reused") >= 2:
			break
	var reused := log.filter(func(e: Dictionary) -> bool: return e.what == "reused")
	var readied := log.filter(func(e: Dictionary) -> bool: return e.what == "ready")
	var made_ids := readied.map(func(e: Dictionary) -> int: return e.id)
	check("a pooled kind takes a gone view's node back for a later key, _ready only for new nodes",
		reused.size() >= 4 and reused.all(func(e: Dictionary) -> bool: return made_ids.has(e.id) \
			and _before(log, e).key != e.key),
		[readied.size(), reused.size()])
	var wrong := reused.filter(func(e: Dictionary) -> bool:
		var key: int = e.key
		var period := key - POOL_KEY
		var player := me if key < POOL_BLIP_KEY and period % 2 == 1 else 0
		return e.serial != key or not (e.position as Vector2).is_equal_approx(Vector2(key * 10, 10)) \
			or e.player != player or not e.inside or not e.visible or not e.old_null)
	check("a reused view: its key, player, data (after null) and pose the new item's at _sim_reused, in the tree, shown",
		reused.size() > 0 and wrong.is_empty(), wrong.slice(0, 3))
	var stale := log.filter(func(e: Dictionary) -> bool:
		return e.serial >= 0 and e.nested != [e.serial, e.serial, e.serial])
	check("a reused view's nested values (its data objects' cached ones, read before it was pooled) are the new key's",
		reused.size() > 0 and reused.all(func(e: Dictionary) -> bool: return (e.nested as Array).size() == 3) \
		and stale.is_empty(), stale.slice(0, 3))
	check("into the pool: after its linger (not before), its data set to null, then reused",
		reused.all(func(e: Dictionary) -> bool: return _before(log, e).what == "nulled") \
		and log.all(func(e: Dictionary) -> bool:
			if e.what != "nulled" or _before(log, e).what != "despawned":
				return true
			return e.msec - _before(log, e).msec >= 110), _whats(log, "nulled"))
	var heard := log.filter(func(e: Dictionary) -> bool: return e.what == "event" and e.from == POOL_EVENT_PLAYER_KEY)
	var keys_heard := {}  # instance -> the keys it heard events of
	for e: Dictionary in heard:
		var keys: Dictionary = keys_heard.get_or_add(e.id, {})
		keys[e.key] = true
	var sent_old := events.filter(func(e: Array) -> bool:
		return e[0] is EventSpawned and e[0].player == POOL_EVENT_PLAYER_KEY \
			and reused.any(func(r: Dictionary) -> bool:
				return roundi((e[0] as EventSpawned).position.x / 10.0) == (r.key as int) - 1))
	check("events reach a reused view under its new key, never its old one (sent to it too)",
		heard.size() > 0 and heard.all(func(e: Dictionary) -> bool: return e.target == e.key) \
		and keys_heard.values().any(func(keys: Dictionary) -> bool: return keys.size() >= 2) and sent_old.size() > 0,
		[heard.size(), heard.filter(func(e: Dictionary) -> bool: return e.target != e.key).slice(0, 3), sent_old.size()])
	var revived := log.filter(func(e: Dictionary) -> bool: return e.what == "revived")
	check("a key gone for less than its linger is revived, not pooled: the same view, its key kept",
		revived.size() >= 2 and revived.all(func(e: Dictionary) -> bool:
			var before := _before(log, e)
			return before.what == "despawned" and before.key == e.key), revived.size())
	var out := 0  # views of the kind out of the pool (alive or lingering), as the log goes
	var most := 0
	for e: Dictionary in log:
		out += 1 if e.what in ["ready", "reused"] else -1 if e.what == "nulled" else 0
		most = maxi(most, out)
	check("the pool keeps no more nodes than the kind ever had out at once (a one-tick key beside the period's)",
		most >= 2 and readied.size() <= most, [readied.size(), most])
	var late_reused := late_log.filter(func(e: Dictionary) -> bool: return e.what == "reused")
	check("a pooled kind that appears on verified: reused, its data the new key's",
		late_reused.size() >= 2 and late_reused.all(func(e: Dictionary) -> bool: return e.serial == e.key),
		late_reused.size())
	var marker := UnifiedView.new()
	check("a kind's views are not pooled unless its marker says so", not marker.pool)
	marker.free()


func _whats(log: Array[Dictionary], what: String) -> int:
	return log.filter(func(e: Dictionary) -> bool: return e.what == what).size()


# The entry of the same instance before `entry` in `log`, events left out ({} : none).
func _before(log: Array[Dictionary], entry: Dictionary) -> Dictionary:
	var found := {}
	for e in log:
		if is_same(e, entry):
			return found
		if e.id == entry.id and e.what != "event":
			found = e
	return found


# A remote3d pose ([x, data tick, ...]) as a tick on the walk: its data's tick plus how far it is past that tick's
# place (playback never glides across a jump, so the pose is on its data's stretch).
func remote_pose_tick(pose: Array) -> float:
	var data_tick: int = pose[1]
	return data_tick + ((pose[0] as float) - remote_x(data_tick)) / REMOTE_SPEED


func remote_x(tick: int) -> float:
	var phase := tick % REMOTE_PERIOD
	return REMOTE_SPEED * phase + (REMOTE_JUMP if phase >= REMOTE_PERIOD / 2 else 0.0)


# The sim's debug draws (ext/ext.odin's drawn_tick: a line and a text a tick): none until a group is shown, then the
# shown tick's two, none again once hidden.
func check_debug_draws(session: UnifiedSession) -> void:
	check("no debug draws until a group is shown", session.debug_draw_count == 0, session.debug_draw_count)
	session.debug_draw = "other"
	for i in 10:
		await create_timer(0.02).timeout
	check("debug_draw shows a group: the shown tick's draws", session.debug_draw == "other" \
		and session.debug_draw_count == 2, session.debug_draw_count)
	session.debug_draw = ""
	for i in 10:
		await create_timer(0.02).timeout
	check("hidden again: none", session.debug_draw_count == 0, session.debug_draw_count)


# The level host (src/godot/README.md, Levels): EnumLevel, the toy's first level is under level_root, and a travel command swaps
# in the other one once it is verified: the old instance freed, the signals in order, the markers the new level's.
func check_levels(session: UnifiedSession, level_root: Node2D, level_signals: Array[String]) -> void:
	# the State's level enum is EnumLevel whatever the game named it; names() lists its members in value order
	check("EnumLevel.names()", EnumLevel.names() == ["meadow", "cave"], EnumLevel.names())
	for i in 50:
		if session.level == EnumLevel.MEADOW:
			break
		await create_timer(0.02).timeout
	var meadow := session.level_scene
	check("the first level's scene is under level_root", session.level == EnumLevel.MEADOW and meadow != null 		and meadow.name == "Meadow" and meadow.get_parent() == level_root, [session.level, meadow])
	check("level_changing, then level_changed", level_signals == ["changing 0", "changed 0"], level_signals)
	var well := session.level_marker(0)
	check("level_marker: the shown level's", well != null and well.name == "Well" and session.level_marker(1) == null,
		well)
	var at_swap := {ids = [], logged = 0}  # when the new level came in: every pooled kind's node until then
	session.level_changed.connect(func(_level: int) -> void:
		at_swap.ids = PoolView.log.map(func(e: Dictionary) -> int: return e.id) \
			+ PoolLateView.log.map(func(e: Dictionary) -> int: return e.id)
		at_swap.logged = PoolView.log.size(), CONNECT_ONE_SHOT)
	var travel := CommandTravel.new()
	travel.to = EnumLevel.CAVE
	check("send_command Travel", session.send_command(travel))
	for i in 100:
		if session.level == EnumLevel.CAVE:
			break
		await create_timer(0.02).timeout
	await process_frame
	var cave := session.level_scene
	check("the verified level's scene replaces the old one", session.level == EnumLevel.CAVE and cave != null 		and cave.name == "Cave" and cave.get_parent() == level_root and not is_instance_valid(meadow) 		and level_root.get_child_count() == 1, [session.level, cave, level_root.get_child_count()])
	check("the signals of the change", level_signals == ["changing 0", "changed 0", "changing 1", "changed 1"],
		level_signals)
	var gem := session.level_marker(1)
	check("level_marker: the new level's", gem != null and gem.name == "Gem", gem)
	var pooled: Array = at_swap.ids
	var made_after: int = at_swap.logged
	check("a level change frees the pooled kinds' nodes, in their pools or not", pooled.size() > 0 \
		and not pooled.any(func(id: int) -> bool: return is_instance_id_valid(id)),
		pooled.filter(func(id: int) -> bool: return is_instance_id_valid(id)))
	for i in 50:  # the next key spawns within a period (half a second)
		await create_timer(0.02).timeout
		if PoolView.log.slice(made_after).any(func(e: Dictionary) -> bool: return e.what == "ready"):
			break
	check("... and the kind's next view is a new one", PoolView.log.slice(made_after).any(func(e: Dictionary) -> bool:
		return e.what == "ready" and not pooled.has(e.id)), PoolView.log.slice(made_after).map(func(e: Dictionary) -> String:
			return e.what))


# A level change whose scene is still loading when the level_root goes (a play scene that left): the level changes
# without a scene, and the load nobody shows is taken anyway: a load left to Godot is an ObjectDB instance leaked at
# exit, which fails the suite.
func check_dropped_load(session: UnifiedSession) -> void:
	var drop_root := func(_to: int) -> void: (func() -> void: session.level_root = null).call_deferred()
	session.level_changing.connect(drop_root, CONNECT_ONE_SHOT)  # after this step, which requested the load
	var travel := CommandTravel.new()
	travel.to = EnumLevel.MEADOW
	check("send_command Travel back", session.send_command(travel))
	for i in 100:
		if session.level == EnumLevel.MEADOW:
			break
		await create_timer(0.02).timeout
	check("without a level_root the level changes all the same", session.level == EnumLevel.MEADOW \
		and session.level_scene == null, [session.level, session.level_scene])


# The constants (Unified.constants: Data_Constants in ext/ext.odin) and an enum class, before any session.
func check_constants() -> void:
	var constants: UnifiedConstants = Unified.constants
	var limits: DataLimits = constants.limits
	check("constants: typed, strings and nested values", near(constants.speed, 4.5) and constants.name == "toy" \
		and constants.favorite == EnumShape.RING and constants.sizes == [1, 2, 3, 4, 5] \
		and limits.low == -1 and limits.high == 9 and constants.by_shape == [0.5, 1.0, 2.0],
		[constants.speed, constants.name, constants.favorite, constants.sizes, limits.low, limits.high])
	var ranges: Array[DataLimits] = constants.ranges  # typed by its class: assigning it would fail otherwise
	check("an array of nested structs: an Array of their class", ranges.size() == 2 and ranges[1].low == 2 \
		and ranges[1].high == 3 and ranges.get_typed_class_name() == &"DataLimits", ranges)
	var sizes: Array[int] = constants.sizes  # a typed Array: assigning it to Array[int] would fail otherwise
	var by_shape: Array[float] = constants.by_shape
	check("constants: arrays typed by their elements", sizes.get_typed_builtin() == TYPE_INT 		and by_shape.get_typed_builtin() == TYPE_FLOAT, [sizes.get_typed_builtin(), by_shape.get_typed_builtin()])
	check("read-only properties have no default for the editor's help",
		ClassDB.class_get_property_default_value(&"UnifiedConstants", &"sizes") == null,
		ClassDB.class_get_property_default_value(&"UnifiedConstants", &"sizes"))
	check("Unified.tick_hz", Unified.tick_hz == 64, Unified.tick_hz)
	check("an enum class: members as constants, name()", EnumShape.DOT == 0 and EnumShape.STAR == 2 \
		and EnumShape.name(EnumShape.STAR) == "star", [EnumShape.DOT, EnumShape.STAR, EnumShape.name(2)])


# A Setup as JSON and back (UnifiedSetup.to_json, from_json): a save file a later build reads.
func check_setup_json() -> void:
	var setup := UnifiedSetup.new()
	setup.life_bonus = 4
	var text := setup.to_json()
	check("to_json names the fields", text == '{"life_bonus":4}', text)
	var back := UnifiedSetup.from_json('{"life_bonus":4,"added_later":[1,{}]}')
	check("from_json reads it back, a key this build lacks skipped", back != null and back.life_bonus == 4)
	var older := UnifiedSetup.from_json('{}')
	check("a field the text lacks keeps the game's default", older != null and older.life_bonus == 0)
	var problem := UnifiedSetup.json_problem('{"life_bonus":300}')
	check("json_problem says why a save does not read", problem.contains("life_bonus") and problem.contains("300"),
		problem)
	check("json_problem of a save that reads is empty", UnifiedSetup.json_problem('{"life_bonus":4}') == "")
	check("from_json of what doesn't read is null, with an error",
		UnifiedSetup.from_json('{"life_bonus":300}') == null)


# The session's players, by key: the local one in slot 0, present and remembered, named from the roster; no platform
# account in single player; an unknown key answers nothing.
func check_players(session: UnifiedSession, me: int, roster_changes: int) -> void:
	check("players / known_players: the local player", session.players == [me] \
		and session.known_players == [me], [session.players, session.known_players])
	var players: Array[int] = session.players  # typed: assigning it to Array[int] would fail otherwise
	check("get_player_slot", players == [me] and session.get_player_slot(me) == 0 \
		and session.get_player_slot(me + 1) == -1 and session.get_player_slot(0) == -1,
		[session.get_player_slot(me), session.get_player_slot(me + 1)])
	var nobody := me + 0x10000  # another member id: nobody the session knows
	check("the local player's name from the roster", session.get_player_name(me) == "player" \
		and session.get_player_name(nobody) == "", [session.get_player_name(me), session.get_player_name(nobody)])
	check("no platform account in single player", session.get_player_platform(me) == "" \
		and session.get_player_platform_id(me) == "", [session.get_player_platform(me), session.get_player_platform_id(me)])
	check("roster_changed when the roster came", roster_changes > 0, roster_changes)
	check("mode: the session started single player", session.mode == UnifiedSession.MODE_SINGLE 		and UnifiedSession.MODE_JOIN_DIRECT == 4, [session.mode, UnifiedSession.MODE_JOIN_DIRECT])


# A player who gave no name (local_name's default) goes by "P" and their slot counted from 1.
func check_unnamed() -> void:
	var session := UnifiedSession.new()
	check("local_name defaults to none", session.local_name == "", session.local_name)
	root.add_child(session)
	session.start_single()
	for i in 150:
		if session.local_player != 0:
			break
		await create_timer(0.02).timeout
	check("no name given: P<slot + 1>", session.get_player_name(session.local_player) == "P1",
		session.get_player_name(session.local_player))
	session.leave()
	for i in 50:
		if not session.running:
			break
		await create_timer(0.02).timeout
	session.queue_free()
	await process_frame


# The events: every one on the sim_event signal as an object of its class, EMITTED once and then CONFIRMED or
# CANCELLED once, its fields typed properties; the subject's view gets them too (the player's view: the toy's
# things have no scene view, so `Spawned` falls back to its player), unless Glue.event_key routes it (Expired to the
# plain2d view keyed 2, Joined to none).
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
	var ids := events.map(func(e: Array) -> int: return (e[0] as UnifiedEvent).id)
	check("every event has an id", not ids.has(0), ids)
	check("PlayerJoined: one id in both states (new objects)", joined.size() == 2 \
		and joined[0][0].id == joined[1][0].id and joined[0][0] != joined[1][0], ids)
	var spawned := events.filter(func(e: Array) -> bool: return e[0] is EventSpawned and e[0].player == me)
	var first := spawned[0][0] as EventSpawned if spawned.size() > 0 else null
	check("Spawned: a handle as its key, the position a Vector2 in view units, the enum an int",
		first != null and first.thing > 0 and first.position.x > 1 and first.shape in [EnumShape.DOT, EnumShape.RING, EnumShape.STAR] \
		and first.player == me, [first.thing, first.position, first.shape, first.player] if first else null)
	check("Spawned: emitted, then confirmed", spawned.map(func(e: Array) -> int: return e[1]) \
		== [UnifiedSession.EVENT_EMITTED, UnifiedSession.EVENT_CONFIRMED], spawned)
	check("Spawned: one id in both states, not Joined's", spawned.size() == 2 and spawned[0][0].id == spawned[1][0].id \
		and joined.size() > 0 and spawned[0][0].id != joined[0][0].id, ids)
	var expired := events.filter(func(e: Array) -> bool: return e[0] is EventExpired)
	check("Expired: the same thing's key, confirmed last", expired.size() > 0 and first != null \
		and expired[-1][1] == UnifiedSession.EVENT_CONFIRMED and (expired[-1][0] as EventExpired).thing == first.thing,
		expired)
	var on_view: Array = (typed.get("events") as Array).filter(func(e: Array) -> bool: return e[0] is EventSpawned)
	check("by subject: the player's view gets Spawned in both states", on_view.size() >= 2, typed.get("events"))
	check("the view sees the signal's ids", on_view.size() > 0 and spawned.size() > 0 \
		and on_view[0][0].id == spawned[0][0].id, on_view)
	check("event_key No_View: Joined reaches no view (the signal only)",
		not (typed.get("events") as Array).any(func(e: Array) -> bool: return e[0] is EventPlayerJoined),
		typed.get("events"))


# A data-only view (ext/ext.odin's card: a Control root): spawned from the index under view_root, its data set before
# its first _process and again when it changes, never posed (its own layout stays), an event_key event reaching it
# while it lingers after its thing went, _sim_despawned once, then freed.
func check_card(card: Control, seen: Dictionary, hand: Node) -> void:
	check("a Control view spawned from the index under its kind's parent (the marker's parent_path)",
		not seen.is_empty() and seen.parent == hand, seen.get("parent"))
	if seen.is_empty():
		return
	check("its data is set before its first _process", seen.first_life > 0, seen.first_life)
	check("its data is set again when it changes", seen.life_sets > 1, seen.life_sets)
	check("the host never poses a data-only view: its container lays it out",
		(seen.positions as Array).all(func(p: Vector2) -> bool: return p == Vector2.ZERO), seen.positions)
	var on_card: Array = seen.events
	check("event_key View: Expired reaches the card it names, in both states",
		on_card.size() >= 2 and on_card.all(func(e: Array) -> bool: return e[0] is EventExpired) \
		and on_card[-1][1] == UnifiedSession.EVENT_CONFIRMED, on_card)
	check("... while it lingers: after _sim_despawned (an exit animation may start there and play the event)",
		on_card.size() > 0 and on_card[0][1] == UnifiedSession.EVENT_EMITTED and on_card[0][2] == 1, on_card)
	check("a data-only view that leaves gets _sim_despawned once, then is freed",
		seen.despawns == 1 and not is_instance_valid(card), seen.despawns)


# A hand: three or more things spawned one tap after another (until two lived at once), each its own card in the
# hand's container while the sim has it, laid out in a row, each with its own data and its own despawn; the hand is
# empty once they all went and lingered.
# Timed by the sim's counters (DataToy.spawned, .recent) and the cards' own records, not by frames. Then the hand's
# container is freed with cards in it: the next frame spawns them again under view_root (the path names no node,
# reported once) and back in a new hand once it is there.
func check_hand(session: UnifiedSession, hand: Container, me: int) -> void:
	var toy: DataToy = Unified.data.toy
	Card.made.clear()  # every card made from here on, recorded by the card itself: none missed between frames
	var most := 0  # cards in the hand at once, in a frame whose things (toy.recent) were two or more
	var together := 0  # frames whose things were two or more
	var row := true  # every time 2 or more were in the hand, the container had them side by side
	var missing: Array = []  # [tick, live things, cards] of a frame with a live thing whose card wasn't in the hand
	var from := toy.spawned
	var holding := false
	var taps_counted := 0  # the things the sim had counted when the newest tap was made
	var tapped_at := -1  # when the newest tap was made (ms; -1: none waits for its thing)
	var deadline := Time.get_ticks_msec() + 15000  # three taps, then until their things lived (at most ~1 s) and went
	while Time.get_ticks_msec() < deadline:  # every frame
		var cards := hand.get_children().filter(func(c: Node) -> bool: return c.get_node_or_null(^"UnifiedView") != null)
		var card_keys := cards.map(func(c: Node) -> int: return (c.get("marker") as UnifiedView).key)
		var live: Array = toy.recent
		if not live.all(func(key: int) -> bool: return card_keys.has(key)):
			missing.append([session.tick, live, card_keys])
		if live.size() >= 2:
			together += 1
			most = maxi(most, cards.size())
		for k in range(1, cards.size()):
			row = row and (cards[k] as Control).position.x > (cards[k - 1] as Control).position.x
		# a tap a frame long, the next once the sim counted its thing (again if it hasn't after a second), while that
		# thing still lives (it lives 4 to 63 ticks): at least three, and on until two lived at once (at most eight)
		var spawned := toy.spawned - from
		if holding:
			press(&"ui_accept", false)
			holding = false
		elif spawned < 3 or (together == 0 and spawned < 8):
			var counted := spawned
			if tapped_at < 0 or Time.get_ticks_msec() - tapped_at > 1000 or counted > taps_counted:
				press(&"ui_accept", true)
				holding = true
				tapped_at = Time.get_ticks_msec()
				taps_counted = counted
		if spawned >= 3 and (together > 0 or spawned >= 8) and cards.is_empty() and Card.made.size() >= spawned \
			and Card.made.all(func(r: Dictionary) -> bool: return r.despawns > 0):
			break
		await process_frame
	var records: Array = Card.made.duplicate()
	var keys := records.map(func(r: Dictionary) -> int: return r.key)
	check("a hand: a card per thing (three or more), every live thing's in the container, side by side, two or more at once",
		records.size() >= 3 and records.size() == toy.spawned - from and missing.is_empty() and row and together > 0 \
		and most >= 2, [records.size(), toy.spawned - from, missing.slice(0, 3), row, together, most])
	check("each card its own key and data", keys.size() >= 3 and keys.all(func(key: int) -> bool: return keys.count(key) == 1) \
		and records.all(func(r: Dictionary) -> bool: return r.holder == me and r.life_sets > 0), records)
	check("each card its own despawn and its own Expired, then the hand is empty",
		records.all(func(r: Dictionary) -> bool: return r.despawns == 1 \
			and (r.events as Array).any(func(e: Array) -> bool: return e[0] is EventExpired)) \
		and hand.get_child_count() == 0, records)
	# a card with a while to live, then its container freed under it
	var long_lived: Control = null
	for attempt in 20:
		press(&"ui_accept", true)
		await create_timer(0.02).timeout
		press(&"ui_accept", false)
		await create_timer(0.02).timeout
		for child in hand.get_children():
			if child.get_node_or_null(^"UnifiedView") != null and (child.get("data") as ViewCard).life > 30:
				long_lived = child as Control
		if long_lived != null:
			break
	check("a card with a while to live", long_lived != null)
	if long_lived == null:
		return
	var key := (long_lived.get("marker") as UnifiedView).key
	var views := hand.get_parent()
	hand.free()
	var again: Node = null
	for i in 20:
		await create_timer(0.02).timeout
		for child in views.get_children():
			var marker := child.get_node_or_null(^"UnifiedView") as UnifiedView
			if marker != null and marker.kind == "card" and marker.key == key:
				again = child
		if again != null:
			break
	check("a card whose parent was freed spawns again, under view_root while its path names no node",
		again != null and (again.get("marker") as UnifiedView).key == key, again)
	var new_hand := HBoxContainer.new()
	new_hand.name = "Hand"
	views.add_child(new_hand)


# Game input off (UnifiedSession.game_input): a press doesn't reach the sim; an action still held when it comes back
# counts only once released; a new press then spawns.
func check_game_input(session: UnifiedSession, toy: DataToy) -> void:
	var spawned := toy.spawned
	session.game_input = false
	check("game_input reads back", not session.game_input)
	press(&"ui_accept", true)
	for i in 10:
		await create_timer(0.02).timeout
	check("game input off: a press doesn't reach the sim", toy.spawned == spawned, toy.spawned)
	session.game_input = true
	for i in 10:
		await create_timer(0.02).timeout
	check("an action held when game input came back is swallowed", toy.spawned == spawned, toy.spawned)
	press(&"ui_accept", false)
	await create_timer(0.05).timeout
	press(&"ui_accept", true)
	await create_timer(0.02).timeout
	press(&"ui_accept", false)
	for i in 20:
		await create_timer(0.02).timeout
		if toy.spawned > spawned:
			break
	check("released, then pressed again: it spawns", toy.spawned == spawned + 1, toy.spawned)


func check_commands(session: UnifiedSession, toy: DataToy) -> void:
	var bump := CommandBump.new()
	bump.amount = 5
	check("send_command Bump", session.send_command(bump))
	var bump2 := CommandBump.new()
	bump2.amount = -2
	check("send_command another Bump", session.send_command(bump2))
	var mark := CommandMark.new()
	var area := DataMarkArea.new()
	area.corner = Vector2(1, 2)
	area.layer = 3
	mark.at = Vector2(1.5, -2)
	mark.normal = Vector3(0, 1, 0)
	mark.weight = 0.25
	mark.count = -300
	mark.shape = EnumShape.STAR
	mark.shapes = [EnumShape.DOT, 2]
	mark.loud = true
	mark.target = (7 << 32) | 3  # a handle's key: generation 7, index 3
	mark.place = Vector2(30, 40)  # view units (pixels): the sim gets them in its units
	mark.area = area  # a nested struct: an object of its class; `_pad` is left out
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
	var limits: Variant = DataLimits.new()  # untyped: the parser would refuse it
	bad_area.area = limits
	check("another struct's object: refused", not session.send_command(bad_area))
	var event: Variant = EventPlayerJoined.new()  # untyped: the parser would refuse it
	check("an event is not a command", not session.send_command(event))
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
	var mark_area: DataMarkArea = toy.mark_area
	check("a nested struct: an object of its class", mark_area.corner == Vector2(1, 2) and mark_area.layer == 3,
		[mark_area.corner, mark_area.layer])
	check("by shape: [4]f32 a Vector4, Quat a Quaternion, [2]i32 a Vector2i", toy.tint == Vector4(1, 2, 3, 4) \
		and toy.turn == Quaternion.IDENTITY and toy.cell == Vector2i(-3, 7), [toy.tint, toy.turn, toy.cell])
	# a List of positions in a command: view units in, sim units in the sim, view units back (in a nested struct too)
	var trail := CommandTrail.new()
	trail.points = [Vector2(10, 20), Vector2(30, 40)]
	check("send_command a List of positions", session.send_command(trail))
	var long_trail := CommandTrail.new()
	long_trail.points = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]  # past its capacity
	check("a List past its capacity: the command is refused", not session.send_command(long_trail))
	for i in 100:
		await create_timer(0.02).timeout
		if toy.trail.size() == 2:
			break
	check("a List of positions arrives in sim units", toy.trail_first == Vector3(1, 2, 0), toy.trail_first)
	check("and reads back in view units", toy.trail == [Vector2(10, 20), Vector2(30, 40)], toy.trail)
	var box: DataTrailBox = toy.trail_box
	check("a nested struct's List of positions in view units", box.points == [Vector2(10, 20), Vector2(30, 40)],
		box.points)
	# a command without fields (zero bytes): the bumps start over, then one more
	check("send_command ClearBumps", session.send_command(CommandClearBumps.new()))
	var bump3 := CommandBump.new()
	bump3.amount = 4
	check("send_command a Bump after it", session.send_command(bump3))
	for i in 100:
		await create_timer(0.02).timeout
		if toy.bumps == 1 and toy.bump_sum == 4:
			break
	check("a command without fields arrives, in order", toy.bumps == 1 and toy.bump_sum == 4,
		[toy.bumps, toy.bump_sum])


# Nested values (src/godot/README.md, Data and classes): a field that reads as an object or an Array gives the same
# value while its bytes don't change, so a HUD that reads them under `changed` makes nothing. A change refills an
# object in place while no script holds it; one a script holds never changes (the change makes another), and one whose
# field a script sets is its own (the next read gives another; a command takes it). Arrays are read-only and made anew.
func check_nested_values(session: UnifiedSession, toy: DataToy) -> void:
	var constants: UnifiedConstants = Unified.constants
	var area: DataMarkArea = toy.mark_area
	var areas: Array[DataMarkArea] = toy.areas
	check("a nested struct field: the same object on every read while its bytes don't change",
		toy.mark_area == area and constants.limits == constants.limits, [area, toy.mark_area])
	check("an Array field: the same Array while its bytes don't change, its struct elements the same objects",
		is_same(toy.areas, areas) and toy.areas[1] == areas[1] and is_same(toy.trail, toy.trail) \
		and is_same(toy.open, toy.open) and is_same(constants.ranges, constants.ranges), areas)
	check("a nested struct's own Array field: the same", is_same(toy.trail_box.points, toy.trail_box.points))
	check("an Array field is read-only, also in a constant; duplicate() gives one to change", areas.is_read_only() \
		and toy.open.is_read_only() and constants.sizes.is_read_only() and not toy.open.duplicate().is_read_only(),
		[areas.is_read_only(), toy.open.is_read_only(), constants.sizes.is_read_only()])
	var open: Array[int] = toy.open.duplicate()
	open.append(3)
	check("a duplicate changes, the field doesn't", open == [1, 7, 3] and toy.open == [1, 7], [open, toy.open])
	area = null
	areas = []

	# a HUD's reads of unchanged nested values, on every `changed` (toy changes every tick: Unified.input.drift),
	# counted around its own reads (the pooled views read their changing data meanwhile)
	var reads := [0, 0]  # values read, nested values made by those reads
	var hud := func() -> void:
		session.take_sync_stats()
		var shown: Array = [toy.mark_area.layer, toy.areas[0].corner, toy.trail.size(), toy.trail_box.points.size(),
			toy.open.size(), toy.queue.size(), Unified.constants.limits.high, Unified.constants.ranges.size()]
		reads[0] += shown.size()
		reads[1] += int(session.take_sync_stats().nested_values)
	toy.changed.connect(hud)
	for i in 20:
		await create_timer(0.02).timeout
	toy.changed.disconnect(hud)
	check("a HUD reading unchanged nested values under `changed` makes none", reads[0] > 40 and reads[1] == 0, reads)

	# a change while no script holds the value: refilled in place (only its instance id is kept here)
	var area_id := toy.mark_area.get_instance_id()
	check("send a Mark with another area", session.send_command(_mark_with_layer(4)))
	await _layer_reaches(toy, 4)
	check("a change while nobody holds it: the same object, refilled", toy.mark_area.get_instance_id() == area_id \
		and toy.mark_area.layer == 4, [area_id, toy.mark_area.get_instance_id(), toy.mark_area.layer])

	# a value a script holds never changes under it: the change makes another
	var held: DataMarkArea = toy.mark_area
	check("send a Mark with a third area", session.send_command(_mark_with_layer(5)))
	await _layer_reaches(toy, 5)
	check("a held value never changes: the change makes another", held.layer == 4 and toy.mark_area != held \
		and toy.mark_area.layer == 5, [held.layer, toy.mark_area.layer])
	var held_trail: Array = toy.trail
	var trail := CommandTrail.new()
	trail.points = [Vector2(1, 1), Vector2(2, 2), Vector2(3, 3)]
	check("send a longer trail", session.send_command(trail))
	for i in 100:
		await create_timer(0.02).timeout
		if toy.trail.size() == 3:
			break
	check("an Array's change makes a new read-only Array; a held one keeps its items", held_trail.size() == 2 \
		and toy.trail.size() == 3 and not is_same(held_trail, toy.trail) and toy.trail.is_read_only(),
		[held_trail, toy.trail])

	# setting a field of a read value: the script's own copy, which a command takes
	var mine: DataMarkArea = toy.mark_area
	mine.layer = 9
	check("a set field: the value is the script's own, the next read another with the sim's values",
		mine.layer == 9 and toy.mark_area != mine and toy.mark_area.layer == 5, [mine.layer, toy.mark_area.layer])
	var mark := _mark_with_layer(0)
	mark.area = mine
	check("send a Mark with the value set", session.send_command(mark))
	await _layer_reaches(toy, 9)
	check("a command takes the value a script set", toy.mark_area.layer == 9, toy.mark_area.layer)
	var before: Array = toy.areas
	var element: DataMarkArea = before[1]
	element.layer = 7
	check("a set field of a cached Array's struct element: the next read builds the Array anew",
		not is_same(toy.areas, before) and toy.areas[1].layer == 6 and element.layer == 7,
		[toy.areas[1].layer, element.layer])

	# events and commands read through one path (their classes' fields); the toy's events hold no nested field, so a
	# command stands for them
	var command := CommandMark.new()
	check("a command's nested fields: the same value on every read, its Arrays read-only", command.area == command.area \
		and is_same(command.shapes, command.shapes) and command.shapes.is_read_only(), command.shapes)
	var old_area := command.area
	command.area = _area_with_layer(2)
	command.shapes = [EnumShape.RING]
	check("setting a whole nested field: read back anew, the old value as it was", command.area.layer == 2 \
		and old_area.layer == 0 and command.shapes == [EnumShape.RING], [command.area.layer, old_area.layer])


func _mark_with_layer(layer: int) -> CommandMark:
	var mark := CommandMark.new()
	mark.area = _area_with_layer(layer)
	return mark


func _area_with_layer(layer: int) -> DataMarkArea:
	var area := DataMarkArea.new()
	area.corner = Vector2(1, 2)
	area.layer = layer
	return area


func _layer_reaches(toy: DataToy, layer: int) -> void:
	for i in 100:
		await create_timer(0.02).timeout
		if toy.mark_area.layer == layer:
			return


func finish(session: UnifiedSession) -> void:
	session.leave()
	for i in 50:
		if not session.running:
			break
		await create_timer(0.02).timeout
	root.get_child(0).queue_free()
	session.queue_free()
	await process_frame


# The view lookup: by kind and key, by kind and player, and every view of a kind (UnifiedSession.get_view...). An
# unknown kind is null or empty, with an error line once (the suite expects it).
func check_view_lookup(session: UnifiedSession, typed: Node, plain: Node, me: int) -> void:
	check("get_view by kind and key", session.get_view(EnumView.PLAIN2D, 2) == plain and session.get_view(EnumView.PLAIN2D, 99) == null \
		and session.get_view(99, 2) == null, session.get_view(EnumView.PLAIN2D, 2))
	check("get_player_view by kind and player", session.get_player_view(EnumView.TYPED2D, me) == typed \
		and session.get_player_view(EnumView.TYPED2D, 0) == null, session.get_player_view(EnumView.TYPED2D, me))
	var plains: Array[Node] = session.get_views(EnumView.PLAIN2D)  # typed: assigning it to Array[Node] would fail otherwise
	check("get_views: every view of a kind", plains.has(plain) and session.get_views(99).is_empty(), plains)
	check("the view kinds are the classes EnumView and EnumMultiView", EnumView.PLAIN3D == 2 \
		and EnumView.name(EnumView.TYPED2D) == "typed2d" and EnumMultiView.MULTI3D == 1,
		[EnumView.PLAIN3D, EnumMultiView.MULTI3D])
