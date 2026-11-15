extends UnifiedTool
## A tour of the real game with the native session (the game library must be built), driven by input actions as
## a player would (the right stick aims, so the tour needs no mouse):
##   godot --path games/drift -s res://game/tools/tour.gd -- --no-settings [--shots=<dir>] [--quick]
## menu -> single player -> lobby (the ship, the station and both gates are there) -> click Start (the `start`
## command) -> match: aim with the stick (the ship turns to it), thrust (it moves, the camera follows), fire
## (bullets in the bulk view) while the first wave's rocks drift in (rock bulk views) -> leave to the menu.
## Without `--quick` it also hunts rocks (aims at the nearest, read back from the rock bulk views' MultiMesh) until
## one splits or is destroyed. The result adds the sim events seen.

const ROCK_KINDS: Array[String] = ["rock_0", "rock_1", "rock_2", "rock_3"]

## Sim event name -> count of confirmed events, from sim_event.
var _events: Dictionary[String, int] = {}


func _run() -> void:
	session.sim_event.connect(func(event: UnifiedEvent, state: int) -> void:
		if state == UnifiedSession.EVENT_CONFIRMED:
			_events[event.kind] = int(_events.get(event.kind, 0)) + 1)
	result["events"] = _events
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await wait_for_scene("MainMenu", 5.0)
	await seconds(0.5)
	await shot("r01_menu")
	step("menu")

	await click_menu("Single")
	await wait_for_scene("Arena", 5.0)
	if not failed():
		current_scene.mouse_aim_enabled = false  # the stick aims; a real mouse over a window must not
	await wait_for(func() -> bool: return _me() != null, 8.0, "the local ship's view")
	await wait_for(func() -> bool: return _views("station") == 1 and _views("gate") == 2, 3.0,
		"the station and 2 gate views")
	await wait_for(func() -> bool: return _phase() == "lobby", 3.0, "the lobby")
	if failed():
		return
	await seconds(0.8)
	await shot("r02_lobby")
	step("lobby: %d views, ship at %s" % [current_scene.get_node(^"Views").get_child_count(),
		_v(_me().global_position)])

	var hud: Node = current_scene.get_node(^"HUD")
	var start: Button = hud.start_button
	if not start.is_visible_in_tree():
		fail("the Start button isn't shown in the lobby")
	else:
		await click(start)
		await wait_for(func() -> bool: return _phase() == "match", 3.0, "the match after Start (the start command)")
	if failed():
		return
	step("match started (wave %d)" % int(game.hud.get("wave", 0)))

	# aim: the stick turns the ship (its view's rotation, set by the host from the sim's heading)
	for aim: Array in [[&"aim_right", 0.0], [&"aim_up", -PI / 2.0], [&"aim_left", PI]]:
		Input.action_press(aim[0], 1.0)
		await seconds(0.8)
		Input.action_release(aim[0])
		var off := absf(angle_difference(_me().rotation, aim[1]))
		step("aimed %s: heading %.2f rad (off by %.2f)" % [aim[0], _me().rotation, off])
		if off > 0.3:
			fail("aiming %s didn't turn the ship (rotation %.2f, want %.2f)" % [aim[0], _me().rotation, aim[1]])
	# thrust: the ship moves and the camera follows it
	var cam: Camera2D = current_scene.get_node(^"Camera")
	var p0 := _me().global_position
	var c0 := cam.get_screen_center_position()
	Input.action_press(&"move_right")
	await seconds(1.0)
	Input.action_release(&"move_right")
	var moved := _me().global_position.x - p0.x
	var cam_moved := cam.get_screen_center_position().x - c0.x
	step("thrust right: ship %+.0f px, camera %+.0f px" % [moved, cam_moved])
	if moved < 40.0:
		fail("thrusting right moved the ship only %.0f px" % moved)
	elif cam_moved < 10.0:
		fail("the camera didn't follow the ship (%.0f px)" % cam_moved)
	# fire while the first wave drifts in
	Input.action_press(&"fire")
	Input.action_press(&"aim_up", 1.0)
	await wait_for(func() -> bool: return _bulk_count(["bullet"]) > 0, 2.0, "bullets in the bullet bulk view")
	await wait_for(func() -> bool: return _bulk_count(ROCK_KINDS) > 0, 6.0, "rocks in the rock bulk views")
	Input.action_release(&"aim_up")
	if failed():
		Input.action_release(&"fire")
		return
	await seconds(0.5)
	await shot("r03_match")
	step("match: %d bullets, %d rocks, %d gems drawn; shots fired %d" % [_bulk_count(["bullet"]),
		_bulk_count(ROCK_KINDS), _bulk_count(["gem"]), int(game.local_player_info().get("shots", 0))])

	if not flag("quick"):
		# hunt: aim at the nearest rock until one breaks
		var end := Time.get_ticks_msec() + 40000
		var shot_mid := false
		while not failed() and Time.get_ticks_msec() < end:
			if _events.get("rock_split", 0) + _events.get("rock_destroyed", 0) > 0 and shot_mid:
				break
			var at := _me().global_position
			var target := _nearest_rock(at)
			var dir := (target - at).normalized() if target != Vector2.INF else Vector2.ZERO
			_stick(dir)
			_move(dir if target != Vector2.INF and at.distance_to(target) > 350.0 else Vector2.ZERO)  # into range
			if not shot_mid and Time.get_ticks_msec() > end - 34000:
				shot_mid = true
				await shot("r04_fight")
			await process_frame
		_stick(Vector2.ZERO)
		_move(Vector2.ZERO)
		var broke: int = _events.get("rock_split", 0) + _events.get("rock_destroyed", 0)
		await seconds(0.3)
		await shot("r05_split")
		step("hunt: %d rock hits, %d splits, %d destroyed, %d station hits, score %d" % [_events.get("rock_hit", 0),
			_events.get("rock_split", 0), _events.get("rock_destroyed", 0), _events.get("station_hit", 0),
			int(game.hud.get("score", 0))])
		if _events.get("rock_hit", 0) == 0:
			fail("no bullet hit a rock in 40 s of firing at them")
		elif broke == 0:
			fail("no rock split or was destroyed in 40 s of firing at them")
		await _warp()
	Input.action_release(&"fire")

	game.leave_to_menu()
	await wait_for_scene("MainMenu", 5.0)
	await seconds(0.3)
	step("left to the menu")


## Flies into the nearest gate: the ship comes out of its pair (a `warped` event, a jump of the ship's view past
## teleport_dist, so it snaps) and the camera cuts to it.
func _warp() -> void:
	if failed():
		return
	var gates: Array = current_scene.views_of("gate")
	var at := _me().global_position
	var gate: Node2D = null
	for g: Node2D in gates:
		if gate == null or at.distance_to(g.global_position) < at.distance_to(gate.global_position):
			gate = g
	var warps: int = _events.get("warped", 0)
	var end := Time.get_ticks_msec() + 15000
	var last := at
	var jump := 0.0
	while not failed() and jump < 400.0:
		if Time.get_ticks_msec() > end:
			fail("timed out (15 s) flying into the gate at %s (ship at %s)" % [_v(gate.global_position), _v(last)])
			break
		var dir := (gate.global_position - _me().global_position).normalized()
		_move(dir)
		_stick(dir)
		await process_frame
		jump = maxf(jump, _me().global_position.distance_to(last))
		last = _me().global_position
	_move(Vector2.ZERO)
	_stick(Vector2.ZERO)
	await seconds(0.25)
	var lag := _camera_lag()
	await shot("r06_warp")
	step("warped: the ship jumped %.0f px in a frame; 0.25 s later the camera is %.0f px from where it should be"
		% [jump, lag])
	await wait_for(func() -> bool: return int(_events.get("warped", 0)) > warps, 1.0, "the verified warped event")
	if lag > 64.0:
		fail("the camera didn't cut to the ship after the warp (%.0f px off)" % lag)


## How far the camera's view centre is from the local ship, clamped to where the arena's limits let it be.
func _camera_lag() -> float:
	var cam: Camera2D = current_scene.get_node(^"Camera")
	var half := cam.get_viewport_rect().size / cam.zoom / 2.0
	var p := _me().global_position
	var want := Vector2(clampf(p.x, cam.limit_left + half.x, cam.limit_right - half.x),
		clampf(p.y, cam.limit_top + half.y, cam.limit_bottom - half.y))
	return cam.get_screen_center_position().distance_to(want)  # shake moves it by 10 px at most


func _phase() -> String:
	return String(root.get_node(^"Game").hud.get("phase", ""))


func _me() -> Node2D:
	if current_scene == null or not current_scene.has_method(&"local_ship_view"):
		return null
	return current_scene.local_ship_view()


func _views(kind: String) -> int:
	return current_scene.views_of(kind).size() if current_scene != null and current_scene.has_method(&"views_of") else 0


## Instances the host drew this frame in the MultiMesh views of these kinds.
func _bulk_count(kinds: Array) -> int:
	var n := 0
	for kind: String in kinds:
		n += multi_count(kind)
	return n


## The nearest rock's position, read back from the rock bulk views' instance transforms (what the host wrote).
func _nearest_rock(from: Vector2) -> Vector2:
	var best := Vector2.INF
	for b in current_scene.get_node(^"Bulk").get_children():
		var mmi := b as MultiMeshInstance2D
		if mmi == null or mmi.multimesh == null or not (String(b.get(&"kind")) in ROCK_KINDS):
			continue
		for i in maxi(mmi.multimesh.visible_instance_count, 0):
			var p := mmi.multimesh.get_instance_transform_2d(i).origin
			if best == Vector2.INF or from.distance_to(p) < from.distance_to(best):
				best = p
	return best


## The right stick, as Input actions (what Input.get_vector reads).
func _stick(dir: Vector2) -> void:
	_press_vector(dir, [&"aim_right", &"aim_left", &"aim_down", &"aim_up"])


## The left stick (thrust).
func _move(dir: Vector2) -> void:
	_press_vector(dir, [&"move_right", &"move_left", &"move_down", &"move_up"])


## A direction as four actions (+x, -x, +y, -y) pressed with its components as strengths.
func _press_vector(dir: Vector2, actions: Array) -> void:
	for pair: Array in [[actions[0], dir.x], [actions[1], -dir.x], [actions[2], dir.y], [actions[3], -dir.y]]:
		if pair[1] > 0.05:
			Input.action_press(pair[0], pair[1])
		else:
			Input.action_release(pair[0])


static func _v(p: Vector2) -> String:
	return "(%.0f, %.0f)" % [p.x, p.y]
