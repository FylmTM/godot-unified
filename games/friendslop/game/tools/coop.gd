extends SceneTree
## Real online co-op through the menus (game library with EOS built), one process per role:
##   godot --path games/friendslop -s res://game/tools/coop.gd -- --role=host --code-file=<f> [--shots=<dir>]
##   godot --headless --path games/friendslop -s res://game/tools/coop.gd -- --role=join --code-file=<f>
## The host clicks Host online and writes the lobby code to the file; the joiner types it into the Join panel.
## Both wait for two players in the hub; the host walks over and picks the friend up, the friend mashes jump and
## breaks free, the host leaves; the joiner must see the disconnect on its menu. With --rejoin (both roles), the
## joiner leaves and joins again with the same code (a late join) before the host leaves. With --lan (both roles),
## no EOS: the host clicks Host on LAN (direct UDP, port 7777) and the joiner types 127.0.0.1:7777. Prints steps and
## `UNIFIED_RESULT {...}`; exits 1 on failure.

var cap: Logger
var role := ""
var code_file := ""
var shots_dir := ""
var rejoin := false
var lan := false
var _t0 := 0
var _started := false
var _failed := ""
var _done := false
var _steps: Array[Dictionary] = []


func _init() -> void:
	cap = load("res://game/tools/log_capture.gd").new()
	OS.add_logger(cap)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.trim_prefix("--role=")
		elif a.begins_with("--code-file="):
			code_file = a.trim_prefix("--code-file=")
		elif a.begins_with("--shots="):
			shots_dir = a.trim_prefix("--shots=")
		elif a == "--rejoin":
			rejoin = true
		elif a == "--lan":
			lan = true


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_t0 = Time.get_ticks_msec()
		_run()
	return false


func _run() -> void:
	var game: Node = root.get_node(^"Game")
	if game.session == null:
		_fail("needs the game library")
		return
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await _wait_for(func() -> bool: return _scene_is("MainMenu"), 5.0, "main menu")
	await _seconds(0.3)
	if role == "host":
		await _host(game)
	else:
		await _join(game)
	_finish()


func _host(game: Node) -> void:
	var code := ""
	if lan:
		await _click(current_scene.get_node(^"UI/Root/Left/VBox/Buttons/Address"))
		await _click(current_scene.get_node(^"UI/Root/Side/AddressPanel/VBox/HostLan"))
		code = "127.0.0.1:%d" % game.LAN_PORT
		await _wait_for(func() -> bool: return _scene_is("Arena"), 20.0, "host arena")
	else:
		await _click(current_scene.get_node(^"UI/Root/Left/VBox/Buttons/Host"))
		await _wait_for(func() -> bool: return game.lobby_code.length() == 6, 30.0, "a lobby code")
		code = game.lobby_code
	var f := FileAccess.open(code_file, FileAccess.WRITE)
	f.store_string(code)
	f.close()
	await _shot("c01_host_code")
	_step("hosting, %s %s" % ["address" if lan else "code", code])
	await _wait_for(func() -> bool: return _scene_is("Arena"), 20.0, "host arena")
	await _wait_for(func() -> bool: return _present(game) >= 2, 60.0, "the friend joins")
	await _seconds(1.5)
	await _shot("c02_lobby_two_players")
	_step("friend joined: %s" % _names(game))
	# Walk over to the friend and pick them up; they break free (the joiner mashes jump).
	var friend := 1 - int(game.hud.get("local_slot", 0))
	if _failed != "":
		return
	await _walk_to(func() -> Vector3: return current_scene.player_view(friend).global_position, 15.0, 1.4)
	await _face(current_scene.player_view(friend).global_position)
	for attempt in 5:
		await _press(&"grab")
		if _player(game, friend).get("held", false):
			break
		await _seconds(0.3)
	await _wait_for(func() -> bool: return _player(game, friend).get("held", false), 5.0, "holding the friend")
	await _shot("c03_holding_friend")
	_step("holding the friend")
	await _wait_for(func() -> bool: return not _player(game, friend).get("held", false), 20.0, "the friend breaks free")
	_step("the friend broke free")
	if rejoin:
		await _wait_for(func() -> bool: return _present(game) == 1, 30.0, "the friend leaves")
		_step("friend left: %s" % _names(game))
		await _wait_for(func() -> bool: return _present(game) >= 2, 60.0, "the friend rejoins")
		_step("friend rejoined: %s" % _names(game))
		await _seconds(4.0)
	game.leave_to_menu()
	await _wait_for(func() -> bool: return _scene_is("MainMenu"), 5.0, "host leaves")
	_step("host left")
	await _seconds(3.0)  # let the joiner notice


func _join(game: Node) -> void:
	await _wait_for(func() -> bool: return FileAccess.file_exists(code_file) and FileAccess.get_file_as_string(code_file).length() >= 6, 60.0, "the host's code")
	var code := FileAccess.get_file_as_string(code_file)
	await _enter_code(code)
	await _wait_for(func() -> bool: return _scene_is("Arena"), 30.0, "joiner arena")
	await _wait_for(func() -> bool: return _present(game) >= 2, 30.0, "both players in the lobby")
	_step("joined as slot %d: %s" % [game.hud.local_slot, _names(game)])
	await _wait_for(func() -> bool: return game.local_player().get("held", false), 60.0, "the host picks us up")
	_step("held by the host")
	await _seconds(0.7)
	while game.local_player().get("held", false) and _failed == "":
		await _press(&"jump")
		await _seconds(0.1)
	_step("broke free")
	if rejoin:
		await _seconds(2.0)
		game.leave_to_menu()
		await _wait_for(func() -> bool: return _scene_is("MainMenu"), 10.0, "the joiner leaves")
		_step("left")
		await _seconds(1.0)
		await _enter_code(code)
		await _wait_for(func() -> bool: return _scene_is("Arena"), 30.0, "joiner arena again")
		await _wait_for(func() -> bool: return _present(game) >= 2, 30.0, "back in the game")
		_step("rejoined as slot %d: %s" % [game.hud.local_slot, _names(game)])
	Input.action_press(&"move_back")
	await _wait_for(func() -> bool: return _scene_is("MainMenu"), 60.0, "back on the menu when the host leaves")
	Input.action_release(&"move_back")
	var err: Label = current_scene.get_node(^"UI/Root/Side/ErrorPanel/VBox/Message")
	_step("host left -> menu: %s" % (err.text if err.is_visible_in_tree() else "(no error shown)"))


func _player(game: Node, slot: int) -> Dictionary:
	for p: Dictionary in game.hud.get("players", []):
		if int(p.get("slot", -1)) == slot:
			return p
	return {}


## Steers by turning the camera towards the target and holding forward, until within `near` (xz).
func _walk_to(target: Callable, timeout_s: float, near: float) -> void:
	var rig: Node3D = current_scene.camera_rig
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	Input.action_press(&"move_forward")
	while _failed == "":
		var at: Vector3 = current_scene.local_player_view().global_position
		var t: Vector3 = target.call()
		var d := Vector2(t.x - at.x, t.z - at.z)
		if d.length() < near:
			break
		if Time.get_ticks_msec() > end:
			_fail("timed out walking to (%.1f, %.1f)" % [t.x, t.z])
			break
		rig.yaw = atan2(d.x, d.y)
		await process_frame
	Input.action_release(&"move_forward")
	await _seconds(0.3)


func _face(t: Vector3) -> void:
	var rig: Node3D = current_scene.camera_rig
	var at: Vector3 = current_scene.local_player_view().global_position
	rig.yaw = atan2(t.x - at.x, t.z - at.z)
	rig.pitch = -0.1
	await _seconds(0.3)


func _press(action: StringName) -> void:
	Input.action_press(action)
	await _seconds(0.08)
	Input.action_release(action)
	await process_frame


func _enter_code(code: String) -> void:
	if lan:
		await _click(current_scene.get_node(^"UI/Root/Left/VBox/Buttons/Address"))
		var addr: LineEdit = current_scene.get_node(^"UI/Root/Side/AddressPanel/VBox/Address")
		addr.clear()
		addr.insert_text_at_caret(code)
		await _seconds(0.1)
		await _click(current_scene.get_node(^"UI/Root/Side/AddressPanel/VBox/Row/Go"))
		_step("joining %s" % code)
		return
	await _click(current_scene.get_node(^"UI/Root/Left/VBox/Buttons/Join"))
	var edit: LineEdit = current_scene.get_node(^"UI/Root/Side/JoinPanel/VBox/Code")
	edit.clear()
	edit.insert_text_at_caret(code.to_lower())
	edit.text_changed.emit(edit.text)
	await _seconds(0.1)
	await _click(current_scene.get_node(^"UI/Root/Side/JoinPanel/VBox/Row/Go"))
	_step("joining %s" % code)


func _present(game: Node) -> int:
	var n := 0
	for p: Dictionary in game.hud.get("players", []):
		if p.get("present", false):
			n += 1
	return n


func _names(game: Node) -> String:
	var out := []
	for p: Dictionary in game.hud.get("players", []):
		if p.get("present", false):
			out.append("%d:%s" % [p.slot, game.player_name(p)])
	return ", ".join(out)


func _scene_is(n: String) -> bool:
	return current_scene != null and current_scene.name == n


func _step(name: String) -> void:
	if _failed != "":
		return
	var ms := Time.get_ticks_msec() - _t0
	_steps.append({"step": name, "ms": ms})
	print("  [%s] ok %6d ms  %s" % [role, ms, name])


func _fail(msg: String) -> void:
	if _failed != "":
		return
	_failed = msg
	print("  [%s] FAIL  %s" % [role, msg])
	_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	var ok := _failed == ""
	print("coop %s: %s" % [role, "OK" if ok else "FAILED"])
	print("UNIFIED_RESULT " + JSON.stringify({"ok": ok, "role": role, "steps": _steps, "failed": _failed, "errors": cap.errors}))
	OS.remove_logger(cap)
	var game: Node = root.get_node(^"Game")
	if game.status != "idle":
		game.session.leave()
	root.get_node(^"Game").quit_app(0 if ok else 1)  # audio first: a live playback leaks


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


func _shot(name: String) -> void:
	if shots_dir == "" or _failed != "":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(shots_dir)
	root.get_texture().get_image().save_png(shots_dir.path_join(name + ".png"))
