extends "res://game/tools/ui_walk.gd"
## A tour of the real game with the native session (the game library must be built): the walk's match
## (ui_walk.gd: the lobby, Start, aiming, thrust, firing until a bullet hits a rock), then what only a longer run
## reaches: hunting rocks until one splits or is destroyed, warping through a gate (the camera cuts to the ship), and
## leaving to the menu.
##   godot --path examples/drift -s res://game/tools/tour.gd -- --no-settings [--shots=<dir>] [--end-in-match]
## By hand (`uni tool drift tour`). `--end-in-match`: the run ends after the hunt, fire held, so the app quits
## mid-match with sounds playing (in a window with `--shots` a quit must free their playbacks before Sfx.close).
## The result adds the sim events seen.

## Sim event name -> count of confirmed events, from sim_event.
var _events: Dictionary[String, int] = {}
## Where a bullet last hit or split a rock (pixels) and when (msec): what the hunt aims at when no rock is in a clear
## line.
var _rock_seen := Vector2.INF
var _rock_seen_ms := 0


func _run() -> void:
	session.sim_event.connect(_count_event)
	result["events"] = _events
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await wait_for_scene("MainMenu", 5.0)
	await seconds(0.5)
	await shot("r01_menu")
	step("menu")

	await click_menu("Single")
	await wait_for_scene("Arena", 5.0)
	if failed():
		return
	current_scene.mouse_aim_enabled = false  # the stick aims; a real mouse over a window must not
	var on_event := _on_sim_event
	session.sim_event.connect(on_event)
	await _lobby_and_start()
	await _aim_and_thrust()
	await _fire_and_hunt()  # fire stays held
	session.sim_event.disconnect(on_event)
	await _hunt()
	if flag("end-in-match"):
		return  # fire still held: the run quits mid-match, with sounds playing (Game.quit_app frees them)
	await _warp()
	Input.action_release(&"fire")

	game.leave_to_menu()
	await wait_for_scene("MainMenu", 5.0)
	await seconds(0.3)
	step("left to the menu")


func _count_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state == UnifiedSession.EVENT_CONFIRMED:
		_events[event.kind] = int(_events.get(event.kind, 0)) + 1  # by its name: the result's counts
	elif state == UnifiedSession.EVENT_EMITTED and event is EventRockHit:
		_rock_seen = (event as EventRockHit).position
		_rock_seen_ms = Time.get_ticks_msec()
	elif state == UnifiedSession.EVENT_EMITTED and event is EventRockSplit:
		_rock_seen = (event as EventRockSplit).position
		_rock_seen_ms = Time.get_ticks_msec()


## Fires on until a rock splits or is destroyed, 40 s at most: aims at the nearest rock in a clear line (the walk's
## _clear_rock), else at the last rock hit for a second after each hit, else sweeps the aim; thrusts towards the
## nearest rock drawn while it is out of range.
func _hunt() -> void:
	var budget_s := 40
	var start := Time.get_ticks_msec()
	var end := start + budget_s * 1000
	var shot_mid := false
	while not failed() and Time.get_ticks_msec() < end:
		if shot_mid and _events.get("rock_split", 0) + _events.get("rock_destroyed", 0) > 0:
			break
		var at := _me().global_position
		var nearest := Vector2.INF
		for rock: Vector2 in _rock_positions():
			if nearest == Vector2.INF or at.distance_to(rock) < at.distance_to(nearest):
				nearest = rock
		var target := _clear_rock(at)
		var dir := Vector2.from_angle((Time.get_ticks_msec() - start) * 0.002)  # 2 rad/s, slower than the ship turns
		if target != Vector2.INF:
			dir = (target - at).normalized()
		elif _rock_seen != Vector2.INF and Time.get_ticks_msec() - _rock_seen_ms < 1000:
			dir = (_rock_seen - at).normalized()
		elif nearest != Vector2.INF:
			dir = (nearest - at).normalized()
		_stick(dir)
		_move(dir if target == Vector2.INF and nearest != Vector2.INF and at.distance_to(nearest) > HUNT_RANGE else Vector2.ZERO)
		if not shot_mid and Time.get_ticks_msec() > start + 6000:
			shot_mid = true
			await shot("r04_fight")
		await process_frame
	_stick(Vector2.ZERO)
	_move(Vector2.ZERO)
	await seconds(0.3)
	await shot("r05_hunt")
	var broke: int = _events.get("rock_split", 0) + _events.get("rock_destroyed", 0)
	step("hunt: %d rock hits, %d splits, %d destroyed, %d station hits, score %d" % [_events.get("rock_hit", 0),
		_events.get("rock_split", 0), _events.get("rock_destroyed", 0), _events.get("station_hit", 0),
		Unified.data.hud.score])
	if broke == 0:
		fail("no rock split or was destroyed in %d s of firing at them" % budget_s)


## Flies into the nearest gate: the ship comes out of its pair (a `warped` event, a jump of the ship's view past
## teleport_dist, so it snaps) and the camera cuts to it.
func _warp() -> void:
	if failed():
		return
	var at := _me().global_position
	var gate: Node2D = null
	for v in views(EnumView.GATE):
		var g := v as Node2D
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
