extends SceneTree
## Real online co-op through the menus (game library with EOS built), one process per role:
##   godot --path games/survivor -s res://game/tools/coop.gd -- --role=host --code-file=<f> [--shots=<dir>]
##   godot --headless --path games/survivor -s res://game/tools/coop.gd -- --role=join --code-file=<f>
## The host clicks Host online and writes the lobby code to the file; the joiner types it into the Join panel.
## Both wait for two players in the lobby; the host walks out, they fight ~8 s, the host leaves; the joiner must
## see the disconnect on its menu. With --rejoin (both roles), the joiner leaves mid-match and joins again with the
## same code (a late join into the running match) before the host leaves. Prints steps and `UNIFIED_RESULT {...}`; exits
## 1 on failure.
## With --crash, the joiner kills its own process mid-match (no goodbye, like a crash) and `uni coop --crash` starts
## another with --after-crash and the same EOS identity: the host times how long it takes to have the friend back,
## the second joiner how long from entering the code to playing again.

var cap: Logger
var role := ""
var code_file := ""
var shots_dir := ""
var rejoin := false
var crash := false
var after_crash := false
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
		elif a == "--crash":
			crash = true
		elif a == "--after-crash":
			after_crash = true


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_t0 = Time.get_ticks_msec()
		_run()
	return false


func _run() -> void:
	var game: Node = root.get_node(^"Game")
	if game.is_mock:
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
	await _click(current_scene.get_node(^"UI/Root/Left/VBox/Buttons/Host"))
	await _wait_for(func() -> bool: return game.lobby_code.length() == 6, 30.0, "a lobby code")
	var f := FileAccess.open(code_file, FileAccess.WRITE)
	f.store_string(game.lobby_code)
	f.close()
	await _shot("c01_host_code")
	_step("hosting, code %s" % game.lobby_code)
	await _wait_for(func() -> bool: return _scene_is("Arena"), 20.0, "host arena")
	await _wait_for(func() -> bool: return _present(game) >= 2, 60.0, "the friend joins")
	await _seconds(1.5)
	await _shot("c02_lobby_two_players")
	_step("friend joined: %s" % _names(game))
	Input.action_press(&"move_forward")
	await _wait_for(func() -> bool: return game.hud.get("phase") == "match", 10.0, "host walks out")
	Input.action_release(&"move_forward")
	_step("match started")
	var dirs := [&"move_left", &"move_back", &"move_right", &"move_forward"]
	for i in 32:
		Input.action_press(dirs[floori(i / 8.0) % 4])
		await _seconds(0.25)
		Input.action_release(dirs[floori(i / 8.0) % 4])
	await _shot("c03_coop_match")
	_step("co-op match: %d enemies" % game.hud.enemies_alive)
	if crash:
		var t := Time.get_ticks_msec()
		await _wait_for(func() -> bool: return _present(game) == 1, 60.0, "the crashed friend drops out")
		_step("friend dropped out after %.1f s: %s" % [(Time.get_ticks_msec() - t) / 1000.0, _names(game)])
		t = Time.get_ticks_msec()
		await _wait_for(func() -> bool: return _present(game) >= 2, 120.0, "the friend is back")
		_step("friend back %.1f s after dropping out: %s" % [(Time.get_ticks_msec() - t) / 1000.0, _names(game)])
		await _seconds(4.0)
		_step("co-op again: phase %s, %d enemies" % [game.hud.get("phase"), game.hud.enemies_alive])
	elif rejoin:
		await _wait_for(func() -> bool: return _present(game) == 1, 30.0, "the friend leaves")
		_step("friend left: %s" % _names(game))
		await _wait_for(func() -> bool: return _present(game) >= 2, 60.0, "the friend rejoins")
		_step("friend rejoined: %s" % _names(game))
		await _seconds(4.0)
		_step("co-op again: phase %s, %d enemies" % [game.hud.get("phase"), game.hud.enemies_alive])
	game.leave_to_menu()
	await _wait_for(func() -> bool: return _scene_is("MainMenu"), 5.0, "host leaves")
	_step("host left")
	await _seconds(3.0)  # let the joiner notice


func _join(game: Node) -> void:
	await _wait_for(func() -> bool: return FileAccess.file_exists(code_file) and FileAccess.get_file_as_string(code_file).length() == 6, 60.0, "the host's code")
	var code := FileAccess.get_file_as_string(code_file)
	if after_crash:
		# The same player, back after its game crashed: the match is running already.
		var t := Time.get_ticks_msec()
		await _enter_code(code)
		await _wait_for(func() -> bool: return _scene_is("Arena") and _present(game) >= 2 and game.hud.get("phase") == "match", 120.0, "back in the match after the crash")
		_step("back in the match %.1f s after entering the code, slot %d: %s" % [(Time.get_ticks_msec() - t) / 1000.0, game.hud.local_slot, _names(game)])
		await _wait_for(func() -> bool: return _scene_is("MainMenu"), 60.0, "back on the menu when the host leaves")
		return
	await _enter_code(code)
	await _wait_for(func() -> bool: return _scene_is("Arena"), 30.0, "joiner arena")
	await _wait_for(func() -> bool: return _present(game) >= 2, 30.0, "both players in the lobby")
	_step("joined as slot %d: %s" % [game.hud.local_slot, _names(game)])
	await _wait_for(func() -> bool: return game.hud.get("phase") == "match", 40.0, "the host starts the match")
	_step("match started (seen by the joiner)")
	if crash:
		await _seconds(6.0)
		_step("crashing (the process kills itself: no leave, no goodbye)")
		print("UNIFIED_RESULT " + JSON.stringify({"ok": true, "role": role, "steps": _steps, "crashed": true}))
		OS.kill(OS.get_process_id())
		return
	if rejoin:
		await _seconds(10.0)
		game.leave_to_menu()
		await _wait_for(func() -> bool: return _scene_is("MainMenu"), 10.0, "the joiner leaves")
		_step("left mid-match")
		await _seconds(1.0)
		await _enter_code(code)
		await _wait_for(func() -> bool: return _scene_is("Arena"), 30.0, "joiner arena again")
		await _wait_for(func() -> bool: return _present(game) >= 2 and game.hud.get("phase") == "match", 30.0, "back in the match")
		_step("rejoined as slot %d: %s" % [game.hud.local_slot, _names(game)])
	Input.action_press(&"move_back")
	await _wait_for(func() -> bool: return _scene_is("MainMenu"), 60.0, "back on the menu when the host leaves")
	Input.action_release(&"move_back")
	var err: Label = current_scene.get_node(^"UI/Root/Side/ErrorPanel/VBox/Message")
	_step("host left -> menu: %s" % (err.text if err.is_visible_in_tree() else "(no error shown)"))


func _enter_code(code: String) -> void:
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
