extends SceneTree
## A tour of the real game with the native session (the game library must be built), driven by input actions and
## the camera rig (the tour steers by turning the camera and holding "forward", as a player would):
##   godot --path games/friendslop -s res://game/tools/tour.gd -- --no-settings [--shots=<dir>] [--quick]
## menu -> single player -> hub: walk to a crate, grab it, charge and throw it, walk onto the jump pad and get
## launched onto the high ledge, then leave. `--quick` stops after the throw (a headless smoke check, a few
## seconds). Prints steps and `UNIFIED_RESULT {...}`; exits 1 on failure or errors.

var cap: Logger
var shots_dir := ""
var quick := false
var _t0 := 0
var _started := false
var _failed := ""
var _steps: Array[Dictionary] = []


func _init() -> void:
	cap = load("res://game/tools/log_capture.gd").new()
	OS.add_logger(cap)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			shots_dir = a.trim_prefix("--shots=")
		elif a == "--quick":
			quick = true


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_t0 = Time.get_ticks_msec()
		_run()
	return false


func _run() -> void:
	var game: Node = root.get_node(^"Game")
	if game.session == null:
		_fail("the tour needs the game library (python tools/dev.py game build friendslop)")
		return
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await _wait_for(func() -> bool: return _scene_is("MainMenu"), 5.0, "main menu")
	await _seconds(0.5)
	await _shot("r01_menu")
	_step("menu")

	await _click(current_scene.get_node(^"UI/Root/Left/VBox/Buttons/Single"))
	await _wait_for(func() -> bool: return _scene_is("Arena"), 5.0, "arena")
	await _wait_for(func() -> bool: return _me() != null, 8.0, "the player's view")
	await _wait_for(func() -> bool: return _markers() >= 10, 5.0, "marker views (items, platforms)")
	if _failed != "":
		_finish()
		return
	await _seconds(1.0)
	await _shot("r02_hub")
	_step("hub: %d views, %d markers adopted" % [current_scene.get_node(^"Views").get_child_count(), _markers()])

	var crate := _marker_view("Crate1")
	if _failed != "":
		pass
	elif crate == null:
		_fail("no view for Crate1")
	else:
		await _walk_to(func() -> Vector3: return crate.global_position + Vector3(-1.1, 0, 0), 8.0, 0.35)
		await _face(crate.global_position)
		await _press(&"grab")
		await _wait_for(func() -> bool: return int(game.local_player().get("holding", 0)) == 1, 1.0, "holding the crate")
		await _seconds(0.5)
		await _shot("r03_holding")
		_step("grabbed a crate next to %s" % _v(crate.global_position))
		var before := _marker_positions()
		Input.action_press(&"throw")
		await _seconds(0.4)
		Input.action_release(&"throw")
		await _wait_for(func() -> bool: return int(game.local_player().get("holding", 0)) == 0, 1.0, "the throw")
		await _seconds(0.5)
		await _shot("r04_thrown")
		var moved := 0.0
		var after := _marker_positions()
		for k: int in before:
			moved = maxf(moved, (after.get(k, before[k]) as Vector3).distance_to(before[k]))
		_step("threw it %.1f m" % moved)
		if moved < 2.0:
			_fail("the thrown crate moved only %.1f m" % moved)
	if quick or _failed != "":
		_finish()
		return

	var pad := _volume_marker("Pad")
	await _walk_to(func() -> Vector3: return pad, 10.0, 0.3)
	var peak := 0.0
	var end := Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < end and _failed == "":
		peak = maxf(peak, _me().global_position.y)
		await process_frame
	await _shot("r05_ledge")
	_step("jump pad: peak %.1f m, now %s" % [peak, _v(_me().global_position)])
	if peak < 4.0:
		_fail("the jump pad didn't launch the player (peak %.1f m)" % peak)
	_finish()


func _finish() -> void:
	var game: Node = root.get_node(^"Game")
	var ok: bool = _failed == "" and cap.errors.is_empty()
	var report := {"ok": ok, "steps": _steps, "errors": cap.errors, "failed": _failed,
		"seconds": (Time.get_ticks_msec() - _t0) / 1000.0}
	print("UNIFIED_RESULT " + JSON.stringify(report))
	OS.remove_logger(cap)
	if game.session != null:
		game.session.leave()
	game.quit_app(0 if ok else 1)


func _me() -> Node3D:
	return current_scene.local_player_view() if current_scene != null and current_scene.has_method(&"local_player_view") else null


func _marker_positions() -> Dictionary:
	var out := {}
	for v in current_scene.get_node(^"Views").get_children():
		if v is GameView and v.kind == &"marker":
			out[v.entity] = v.global_position
	return out


func _markers() -> int:
	var n := 0
	for v in current_scene.get_node(^"Views").get_children():
		if v is GameView and v.kind == &"marker":
			n += 1
	return n


## The view of a level marker by its node name (the marker view's entity is its marker index + 1).
func _marker_view(marker_name: String) -> Node3D:
	var markers: Array = current_scene.markers
	for v in current_scene.get_node(^"Views").get_children():
		if v is GameView and v.kind == &"marker" and v.entity >= 1 and v.entity <= markers.size():
			if markers[v.entity - 1].name == marker_name:
				return v
	return null


func _volume_marker(marker_name: String) -> Vector3:
	for m: Node in current_scene.markers:
		if m.name == marker_name:
			return (m as Node3D).global_position
	_fail("no marker " + marker_name)
	return Vector3.ZERO


## Steers by turning the camera towards the target and holding forward, until within `near` (xz).
func _walk_to(target: Callable, timeout_s: float, near: float) -> void:
	var rig: Node3D = current_scene.camera_rig
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	Input.action_press(&"move_forward")
	while _failed == "":
		var at := _me().global_position
		var t: Vector3 = target.call()
		var d := Vector2(t.x - at.x, t.z - at.z)
		if d.length() < near:
			break
		if Time.get_ticks_msec() > end:
			_fail("timed out walking to %s (at %s)" % [_v(t), _v(at)])
			break
		rig.yaw = atan2(d.x, d.y)
		await process_frame
	Input.action_release(&"move_forward")
	await _seconds(0.3)


func _face(t: Vector3) -> void:
	var rig: Node3D = current_scene.camera_rig
	var at := _me().global_position
	rig.yaw = atan2(t.x - at.x, t.z - at.z)
	rig.pitch = -0.35
	await _seconds(0.2)


func _press(action: StringName) -> void:
	Input.action_press(action)
	await _seconds(0.1)
	Input.action_release(action)
	await process_frame


func _scene_is(n: String) -> bool:
	return current_scene != null and current_scene.name == n


func _step(what: String) -> void:
	var t := (Time.get_ticks_msec() - _t0) / 1000.0
	_steps.append({"t": t, "step": what})
	print("  %5.1f s  %s" % [t, what])


func _fail(why: String) -> void:
	if _failed == "":
		_failed = why
		print("  FAILED: " + why)


static func _v(p: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end and _failed == "":
		await process_frame


func _wait_for(cond: Callable, timeout_s: float, what: String) -> void:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while _failed == "":
		if cond.call():
			return
		if Time.get_ticks_msec() > end:
			_fail("timed out (%.0f s): %s" % [timeout_s, what])
			return
		await process_frame


func _click(c: Control) -> void:
	var pos := c.get_viewport().get_final_transform() * (c.get_global_transform_with_canvas() * (c.size / 2.0))
	for pressed: bool in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		Input.parse_input_event(e)
		await process_frame
	await process_frame


func _shot(shot_name: String) -> void:
	if shots_dir == "" or _failed != "":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(shots_dir)
	var path := shots_dir.path_join(shot_name + ".png")
	root.get_texture().get_image().save_png(path)
	print("  shot " + ProjectSettings.globalize_path(path))
