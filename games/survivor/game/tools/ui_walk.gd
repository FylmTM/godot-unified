extends SceneTree
## Scripted UI walk through every flow with the MockSession, driven by real input events (clicks, actions):
##   godot --headless --path games/survivor -s res://game/tools/ui_walk.gd -- --mock --no-settings
## menu -> single player -> lobby -> walk out -> match -> level-up (key 1) -> Esc menu -> match over -> lobby
## -> leave -> host online (code, bot joins, squad list) -> leave -> join a bad code (error shown) -> menu.
## With `--shots=<dir>` (needs a window, not --headless) it saves PNGs at the key moments.
## Prints each step, one `WALK_JSON {...}` line, exits 1 on the first failure or any engine/script error.

var cap: Logger
var shots_dir := ""
var _steps: Array[Dictionary] = []
var _t0 := 0
var _started := false
var _failed := ""
var _done := false


func _init() -> void:
	cap = load("res://game/tools/log_capture.gd").new()
	OS.add_logger(cap)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			shots_dir = a.trim_prefix("--shots=")


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_t0 = Time.get_ticks_msec()
		_run()
	return false


func _run() -> void:
	var game: Node = root.get_node(^"Game")
	if not game.is_mock:
		_fail("the walk needs the mock session: pass -- --mock")
		return
	var mock: MockSession = game.session
	mock.over_seconds = 0.6
	mock.bot_join_seconds = 0.3
	if shots_dir == "":
		Engine.time_scale = 4.0  # the fake sim's waits (walking, connect delays) dominate; shots run real time
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))

	# Main menu.
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "MainMenu", 3.0, "main menu loads")
	await _frames(5)
	await _shot("01_menu")
	_step("main menu")

	# Settings: open from the menu, toggle Show FPS with a click (applies at once), Done.
	await _click(_find(current_scene, "UI/Root/Left/VBox/Buttons/Settings"))
	var panel: Control = _find(current_scene, "UI/Root/Side/SettingsPanel")
	var fps_toggle := _settings_control(panel, "Show FPS") as CheckButton
	await _click(fps_toggle)
	var settings: Node = root.get_node(^"Settings")
	_expect(settings.get_value(&"show_fps") == true, "Show FPS toggles the setting")
	_expect(game._fps_label.visible, "the FPS counter shows")
	await _frames(3)
	await _shot("01b_settings")
	await _click(fps_toggle)
	_expect(settings.get_value(&"show_fps") == false and not game._fps_label.visible, "Show FPS toggles back")
	await _click(_find(panel, "VBox/Back"))
	_expect(not panel.visible, "Done closes the settings")
	_step("settings panel")

	# Controller: d-pad to Settings, A opens it, B closes it; the game notices the pad.
	_find(current_scene, "UI/Root/Left/VBox/Buttons/Single").grab_focus()
	for i in 4:
		await _pad(JOY_BUTTON_DPAD_DOWN)
	_expect(get_root().gui_get_focus_owner() == _find(current_scene, "UI/Root/Left/VBox/Buttons/Settings"), "d-pad moves focus to Settings")
	await _pad(JOY_BUTTON_A)
	_expect(panel.visible, "pad A opens the focused Settings")
	await _pad(JOY_BUTTON_B)
	_expect(not panel.visible, "pad B closes the panel")
	_expect(game.using_pad, "the game switched to pad hints")
	await _type("q")  # any key switches back to keyboard hints (not Space: it presses the focused button)
	_expect(not game.using_pad, "a key switches back to keyboard hints")
	_step("controller menu navigation")

	# Single player -> arena, lobby phase.
	await _click(_find(current_scene, "UI/Root/Left/VBox/Buttons/Single"))
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "Arena", 3.0, "arena loads")
	await _wait_for(func() -> bool: return game.hud.phase == "lobby" and _player_views() == 1, 2.0, "lobby with one player view")
	_expect(_find(current_scene, "HUD/Root/Hint").visible, "start hint visible in lobby")
	_expect(_find(current_scene, "StartCircle").visible, "start circle visible in lobby")
	_expect(not _find(current_scene, "HUD/Root/Side").visible, "no lobby panel in single player")
	await _frames(20)
	await _shot("02_lobby_single")
	_step("single player lobby")

	# Walk out of the circle -> match starts.
	Input.action_press(&"move_right")
	await _wait_for(func() -> bool: return game.hud.phase == "match", 3.0, "walking out starts the match")
	Input.action_release(&"move_right")
	_step("walked out: match started")
	mock.debug_spawn(40, 11.0)
	await _wait_for(func() -> bool: return game.hud.enemies_alive > 0 and _bulk_count(&"grunt") > 0, 2.0, "enemies spawn and render")
	_expect(_find(current_scene, "HUD/Root/Top").visible, "wave/time visible in match")
	Input.action_press(&"move_left")
	await _wait_seconds(0.3)
	Input.action_release(&"move_left")
	await _wait_for(func() -> bool: return _bulk_count(&"projectile") > 0 or _bulk_count(&"gem") > 0, 3.0, "auto-attack fires")
	await _shot("03_match")
	_step("match running (enemies, projectiles)")

	# Level-up: panel shows, key 1 picks fire rate.
	mock.debug_grant_levelup()
	await _wait_for(func() -> bool: return _find(current_scene, "HUD/Root/LevelUp").visible, 1.0, "level-up panel shows")
	await _frames(10)
	await _shot("04_levelup")
	await _press_action(&"levelup_1")
	await _wait_for(func() -> bool: return int(game.local_player().pending_levelups) == 0, 1.0, "key 1 consumes the level-up")
	await _wait_for(func() -> bool: return not _find(current_scene, "HUD/Root/LevelUp").visible, 1.0, "level-up panel hides")
	_step("level-up chosen with key 1")

	# Esc menu opens and closes; the sim keeps running.
	var tick0: int = game.hud.tick
	await _press_action(&"menu")
	_expect(_find(current_scene, "PauseMenu").visible, "Esc opens the menu")
	await _wait_seconds(0.2)
	_expect(int(game.hud.tick) > tick0, "sim keeps running under the menu")
	await _press_action(&"menu")
	_expect(not _find(current_scene, "PauseMenu").visible, "Esc closes the menu")
	_step("Esc menu")

	# Match over -> panel -> back to lobby automatically.
	mock.debug_end_match()
	await _wait_for(func() -> bool: return _find(current_scene, "HUD/Root/GameOver").visible, 1.0, "match-over panel shows")
	await _frames(12)
	await _shot("05_game_over")
	await _wait_for(func() -> bool: return game.hud.phase == "lobby", 3.0, "sim returns to the lobby")
	await _frames(2)
	_expect(not _find(current_scene, "HUD/Root/GameOver").visible, "match-over panel hides in the lobby")
	_step("match over -> lobby")

	# Leave through the Esc menu.
	await _press_action(&"menu")
	await _click(_find(current_scene, "PauseMenu/Center/Panel/VBox/Leave"))
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "MainMenu", 3.0, "leave returns to the menu")
	_expect(game.flow == game.Flow.MENU and game.status == "idle", "flow back to MENU, session idle")
	_step("left to menu")

	# Host online: connecting overlay with the code, then the lobby; a bot friend joins.
	await _frames(3)
	await _click(_find(current_scene, "UI/Root/Left/VBox/Buttons/Host"))
	await _wait_for(func() -> bool: return game.lobby_code.length() == 6, 2.0, "host gets a lobby code")
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "Arena", 3.0, "host reaches the arena")
	_expect(_find(current_scene, "HUD/Root/Side").visible, "lobby panel visible when hosting")
	_expect(_find(current_scene, "HUD/Root/Side/VBox/CodeRow/Code").text == game.lobby_code, "lobby panel shows the code")
	await _wait_for(func() -> bool: return _player_views() == 2, 5.0, "the bot friend joins")
	if shots_dir != "":
		await _wait_seconds(0.6)
	await _shot("06_lobby_hosting")
	_step("hosted: code %s, friend joined" % game.lobby_code)
	Input.action_press(&"move_forward")
	await _wait_for(func() -> bool: return game.hud.phase == "match", 3.0, "host walks out: match starts")
	Input.action_release(&"move_forward")
	mock.debug_spawn(60, 12.0)
	mock.debug_spawn(80)
	await _wait_for(func() -> bool: return _bulk_count(&"projectile") > 0, 3.0, "co-op auto-attack fires")
	if shots_dir != "":
		await _wait_seconds(2.0)  # let the fight develop for the picture
	await _measure_frames("co-op match, %d enemies" % game.hud.enemies_alive)
	mock.debug_explode_nearest_barrel()
	await _frames(4)
	await _shot("07_match_coop")
	_step("co-op match")

	# Losing the connection mid-match returns to the menu with the reason.
	mock.debug_disconnect()
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "MainMenu" and _find(current_scene, "UI/Root/Side/ErrorPanel").visible, 3.0, "disconnect shows the error on the menu")
	_expect(String(_find(current_scene, "UI/Root/Side/ErrorPanel/VBox/Message").text).begins_with("Disconnected"), "error names the disconnect")
	await _click(_find(current_scene, "UI/Root/Side/ErrorPanel/VBox/Ok"))
	_step("disconnect -> menu with the reason")

	# Host on LAN from the address panel: the lobby panel shows this machine's address instead of a code.
	await _click(_find(current_scene, "UI/Root/Left/VBox/Buttons/Address"))
	await _click(_find(current_scene, "UI/Root/Side/AddressPanel/VBox/HostLan"))
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "Arena", 3.0, "LAN host reaches the arena")
	await _frames(2)
	_expect(String(_find(current_scene, "HUD/Root/Side/VBox/CodeRow/Code").text).ends_with(":7777"), "lobby panel shows host:port")
	_step("hosted on LAN: %s" % game.lan_address)
	game.leave_to_menu()
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "MainMenu", 3.0, "leave returns to the menu")

	# Join with a code that fails -> error panel on the menu.
	await _frames(3)
	await _click(_find(current_scene, "UI/Root/Left/VBox/Buttons/Join"))
	var code_edit: LineEdit = _find(current_scene, "UI/Root/Side/JoinPanel/VBox/Code")
	code_edit.clear()  # windowed runs may have prefilled it from the real clipboard
	await _type("zz-zz zz")  # messy input: cleaned to ZZZZZZ
	await _frames(2)  # LineEdit emits text_changed deferred
	_expect(code_edit.text == "ZZZZZZ", "code field cleans and uppercases input (got '%s')" % code_edit.text)
	await _shot("08_join_code")
	await _click(_find(current_scene, "UI/Root/Side/JoinPanel/VBox/Row/Go"))
	await _wait_for(func() -> bool: return game.flow == game.Flow.CONNECTING, 1.0, "joining shows connecting")
	await _frames(3)
	await _shot("09_connecting")
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "MainMenu" and _find(current_scene, "UI/Root/Side/ErrorPanel").visible, 3.0, "failed join shows the error on the menu")
	await _frames(3)
	await _shot("10_join_error")
	_step("bad code -> error on the menu")

	_finish()


# --- Helpers ------------------------------------------------------------------------------------


func _step(name: String) -> void:
	if _failed != "":
		return
	var ms := Time.get_ticks_msec() - _t0
	_steps.append({"step": name, "ms": ms})
	print("  ok  %5d ms  %s" % [ms, name])


func _expect(cond: bool, what: String) -> void:
	if not cond:
		_fail("expected: " + what)


func _fail(msg: String) -> void:
	if _failed != "":
		return
	_failed = msg
	print("  FAIL  " + msg)
	_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	var ok: bool = _failed == "" and cap.errors.is_empty()
	var ms := Time.get_ticks_msec() - _t0
	print("ui walk: %d steps, %s in %d ms" % [_steps.size(), "OK" if ok else "FAILED", ms])
	if not cap.errors.is_empty() or not cap.warnings.is_empty():
		print(cap.report())
	print("WALK_JSON " + JSON.stringify({"ok": ok, "ms": ms, "steps": _steps, "failed": _failed, "errors": cap.errors}))
	OS.remove_logger(cap)
	for p in root.get_node(^"Sfx").get_children():
		p.stop()
	print("music synthesis: %d us last frame" % root.get_node(^"Sfx").music.cost_us)  # a sound still playing at quit shows up as a leaked AudioStreamWAV
	quit(0 if ok else 1)


func _find(from: Node, path: String) -> Node:
	var n := from.get_node_or_null(path) if from != null else null
	if n == null:
		_fail("node not found: " + path)
	return n


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _wait_seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end and _failed == "":
		await process_frame


func _wait_for(cond: Callable, timeout_s: float, what: String) -> void:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while _failed == "":
		if cond.call():
			return
		if Time.get_ticks_msec() > end:
			_fail("timed out (%.1f s): %s" % [timeout_s, what])
			return
		await process_frame


## A real click: motion, press, release at the control's centre, in window coordinates.
func _click(c: Control) -> void:
	if c == null or _failed != "":
		return
	if not c.is_visible_in_tree():
		_fail("cannot click hidden " + str(c.get_path()))
		return
	var pos := c.get_viewport().get_final_transform() * (c.get_global_transform_with_canvas() * (c.size / 2.0))
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	await process_frame
	for pressed: bool in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		Input.parse_input_event(e)
		await process_frame
	await process_frame


## Press and release a gamepad button through the event pipeline.
func _pad(button: JoyButton) -> void:
	for pressed: bool in [true, false]:
		var e := InputEventJoypadButton.new()
		e.button_index = button
		e.pressed = pressed
		Input.parse_input_event(e)
		await process_frame
	await process_frame


## Type text into the focused control with key events (as a keyboard would).
func _type(text: String) -> void:
	for ch in text:
		for pressed: bool in [true, false]:
			var e := InputEventKey.new()
			e.pressed = pressed
			e.unicode = ch.unicode_at(0) if pressed else 0
			e.keycode = OS.find_keycode_from_string(ch.to_upper()) if ch != " " else KEY_SPACE
			Input.parse_input_event(e)
		await process_frame


## Press and release an InputMap action through the event pipeline (handlers and Input state both see it).
func _press_action(action: StringName) -> void:
	for pressed: bool in [true, false]:
		var e := InputEventAction.new()
		e.action = action
		e.pressed = pressed
		Input.parse_input_event(e)
		await process_frame
	await process_frame


## The input control next to a label in the settings grid.
func _settings_control(panel: Control, label: String) -> Control:
	var grid := panel.get_node(^"VBox/Grid")
	for i in grid.get_child_count() - 1:
		var c := grid.get_child(i)
		if c is Label and c.text == label:
			return grid.get_child(i + 1)
	_fail("settings row not found: " + label)
	return null


## Wall time per frame and the mock session's own cost (fake sim + view/bulk writes) over 60 frames.
func _measure_frames(what: String) -> void:
	var mock: Node = root.get_node(^"Game").session
	var frame_total := 0.0
	var frame_max := 0.0
	var mock_total := 0.0
	var t := Time.get_ticks_usec()
	for i in 60:
		await process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - t) / 1000.0
		t = now
		frame_total += ms
		frame_max = maxf(frame_max, ms)
		mock_total += mock.cost_us / 1000.0
	var music_us: int = root.get_node(^"Sfx").music.cost_us
	print("  perf  %s: frame %.2f ms mean, %.2f ms max; mock session %.2f ms; music %d us (time scale %.0f)" % [
		what, frame_total / 60.0, frame_max, mock_total / 60.0, music_us, Engine.time_scale])


func _player_views() -> int:
	var n := 0
	var views := current_scene.get_node_or_null(^"Views") if current_scene != null else null
	if views != null:
		for v in views.get_children():
			if v is GameView and v.kind == &"player" and not v.is_queued_for_deletion():
				n += 1
	return n


func _bulk_count(kind: StringName) -> int:
	for n in get_nodes_in_group(&"sim_bulk"):
		if n.kind == kind and n.multimesh != null:
			return n.multimesh.visible_instance_count
	return 0


func _shot(name: String) -> void:
	if shots_dir == "" or _failed != "":
		return
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(shots_dir)
	var path := shots_dir.path_join(name + ".png")
	img.save_png(path)
	print("  shot " + ProjectSettings.globalize_path(path))
