extends SceneTree
## SPIKE (dev UI on Godot controls vs Dear ImGui): frame cost and input focus, with the real game and real input
## events. Run once per backend, windowed:
##   uni tool survivor devui_spike --window --shots -- --bench 600            (Dear ImGui)
##   uni tool survivor devui_spike --window --shots -- --bench 600 --devui-controls
## A bench match (fixed enemy population), vsync off: frame time with the dev UI hidden and shown (default panels:
## overlay, inspector one level open, events), alternated; then the focus checks: the mouse over a panel and over
## the game, a click into a panel and back into the game, F3 + typing + Enter.
## Prints `UNIFIED_RESULT {...}`.

var cap: Logger
var shots_dir := ""
var bench := 600
var controls := false
var _game: Node
var _t0 := 0
var _steps: Array[String] = []
var _failed := ""
var _done := false
var _started := false
var _result := {}
const PHASE_S := 2.0
const ROUNDS := 5
const MID := 2


func _init() -> void:
	cap = load("res://game/tools/log_capture.gd").new()
	OS.add_logger(cap)
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--shots="):
			shots_dir = a.trim_prefix("--shots=")
	controls = "--devui-controls" in args
	var bi := args.find("--bench")
	if bi >= 0 and bi + 1 < args.size():
		bench = int(args[bi + 1])


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_t0 = Time.get_ticks_msec()
		_run()
	return false


func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_game = root.get_node(^"Game")
	if _game.is_mock:
		_fail("needs the native extension")
		return
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "MainMenu", 5.0, "main menu")
	await _frames(5)
	await _click_at(_center(current_scene.get_node(^"UI/Root/Left/VBox/Buttons/Single")))
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "Arena", 5.0, "arena")
	await _wait_for(func() -> bool: return _game.hud.get("phase", "") == "match", 10.0, "bench match")
	await _wait_for(func() -> bool: return int(_game.hud.enemies_alive) >= bench * 0.9, 20.0, "bench population")
	_step("%s, %d enemies, window %s" % ["Godot controls" if controls else "Dear ImGui", _game.hud.enemies_alive,
		DisplayServer.window_get_size()])

	# Frame cost: hidden / shown, alternated; the median of the per-round differences.
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	var hidden: Array[Dictionary] = []
	var shown: Array[Dictionary] = []
	var d_frame: Array[float] = []
	var d_render: Array[float] = []
	for _r in ROUNDS:
		if _game.session.is_devui_visible():
			_game.session.toggle_devui()
		var h := await _measure()
		_game.session.toggle_devui()
		var s := await _measure()
		hidden.append(h)
		shown.append(s)
		d_frame.append(s.frame_ms - h.frame_ms)
		d_render.append(s.render_cpu_ms - h.render_cpu_ms)
	d_frame.sort()
	d_render.sort()
	var ui: Array[float] = []
	for x in shown:
		ui.append(x.ui_ms)
	ui.sort()
	_result["hidden"] = hidden
	_result["shown"] = shown
	_result["cost_frame_ms"] = snappedf(d_frame[MID], 0.001)
	_result["cost_render_cpu_ms"] = snappedf(d_render[MID], 0.001)
	_result["ui_ms"] = ui[MID]
	_result["items"] = _game.session.devui_probe().items
	_step("median cost: frame +%.3f ms, renderer CPU +%.3f ms, dev UI code %.3f ms" % [_result.cost_frame_ms, _result.cost_render_cpu_ms, _result.ui_ms])
	await _shot("devui_%s" % ("controls" if controls else "imgui"))

	# Stress (Godot controls only): 64 enemies fully expanded in the inspector, ~700 value rows refreshed at 10 Hz.
	if controls:
		_game.session.devui_debug_expand("enemies/items/[0 .. 63]/*")
		await _frames(10)
		var st: Array[float] = []
		var worst := 0.0
		for _r in 3:
			_game.session.toggle_devui()
			var h := await _measure()
			_game.session.toggle_devui()
			var s := await _measure()
			st.append(s.frame_ms - h.frame_ms)
			worst = maxf(worst, s.ui_max_ms)
		st.sort()
		_result["stress_cost_frame_ms"] = snappedf(st[1], 0.001)
		_result["stress_ui_max_ms"] = worst
		_result["stress_items"] = _game.session.devui_probe().items
		_step("stress: frame +%.3f ms, worst dev UI frame %.2f ms" % [st[1], worst])
		await _shot("devui_controls_stress")
		# OS windows: the panels become native windows (the OS window count goes up), and come back.
		var before_w := DisplayServer.get_window_list().size()
		await _click_at(Vector2(1230, 24))
		await _frames(20)
		_result["os_windows_added"] = DisplayServer.get_window_list().size() - before_w
		await _shot("devui_controls_native")
		await _click_at(Vector2(1230, 24))
		await _frames(20)
		_result["os_windows_after_back"] = DisplayServer.get_window_list().size() - before_w
		_step("OS windows: +%d, back: +%d" % [_result.os_windows_added, _result.os_windows_after_back])

	# Focus: who gets the mouse and the keyboard.
	var focus := {}
	var panel := Vector2(120, 320)  # inside the inspector (both backends place it at x 8, y ~200, 360+ x 400+)
	var game_pt := Vector2(900, 360)  # open game area
	await _move(panel)
	focus["mouse_over_panel"] = _probe().wants_mouse
	await _move(game_pt)
	focus["mouse_over_game"] = _probe().wants_mouse
	await _click_at(panel)
	await _frames(3)
	focus["keyboard_after_click_in_panel"] = _probe().wants_keyboard
	var x0: float = _me_x()
	await _until_alive()
	x0 = _me_x()
	await _hold_key(KEY_D, 0.6)  # move_right while the panel has the keyboard
	focus["player_moved_while_panel_has_keyboard"] = absf(_me_x() - x0) > 0.05
	await _click_at(game_pt)
	await _frames(3)
	focus["keyboard_after_click_in_game"] = _probe().wants_keyboard
	x0 = _me_x()
	await _until_alive()
	x0 = _me_x()
	await _hold_key(KEY_D, 0.6)
	focus["player_moved_after_click_in_game"] = absf(_me_x() - x0) > 0.05

	# F3: the note opens with the keyboard, typing goes into it, Enter sends.
	var fb := OS.get_user_data_dir().path_join("feedback")
	var before := DirAccess.get_directories_at(fb).size() if DirAccess.dir_exists_absolute(fb) else 0
	await _key(KEY_F3)
	await _frames(5)
	focus["keyboard_with_note_open"] = _probe().wants_keyboard
	for c in "spike note":
		await _key(OS.find_keycode_from_string(c.to_upper()) if c != " " else KEY_SPACE, c.unicode_at(0))
	await _shot("devui_note_%s" % ("controls" if controls else "imgui"))
	await _key(KEY_ENTER)
	await _frames(5)
	var after := DirAccess.get_directories_at(fb).size() if DirAccess.dir_exists_absolute(fb) else 0
	focus["note_sent"] = after > before
	if after > before:
		var dirs := DirAccess.get_directories_at(fb)
		focus["note_text"] = FileAccess.get_file_as_string(fb.path_join(dirs[dirs.size() - 1]).path_join("note.txt")).strip_edges()
	_result["focus"] = focus
	_step("focus: %s" % JSON.stringify(focus))
	_finish()


func _measure() -> Dictionary:
	await _frames(20)
	var n := 0
	var frame_us := 0
	var render_ms := 0.0
	var vp := root.get_viewport_rid()
	var ui_ms := 0.0
	var ui_max := 0.0
	var last := Time.get_ticks_usec()
	var end := Time.get_ticks_msec() + int(PHASE_S * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
		var now := Time.get_ticks_usec()
		frame_us += now - last
		last = now
		render_ms += RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu()
		var u := float(_game.session.devui_probe().ui_ms)
		ui_ms += u
		ui_max = maxf(ui_max, u)
		n += 1
	return {"frames": n, "frame_ms": snappedf(frame_us / 1000.0 / n, 0.001), "render_cpu_ms": snappedf(render_ms / n, 0.001),
		"ui_ms": snappedf(ui_ms / n, 0.001), "ui_max_ms": snappedf(ui_max, 0.001)}


func _probe() -> Dictionary:
	return _game.session.devui_probe()


func _me_x() -> float:
	var slot: int = _game.hud.get("local_slot", -1)
	for n: Node in _game.session.view_root.get_children() if _game.session.view_root != null else []:
		if n.get("slot") == slot and n.get("kind") == &"player":
			return (n as Node3D).global_position.x
	return 0.0


func _center(c: Control) -> Vector2:
	return c.get_viewport().get_final_transform() * (c.get_global_transform_with_canvas() * (c.size / 2.0))


func _move(pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	Input.parse_input_event(m)
	await _frames(3)


func _click_at(pos: Vector2) -> void:
	await _move(pos)
	for pressed: bool in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		Input.parse_input_event(e)
		await process_frame
	await process_frame


func _key(key: Key, unicode := 0) -> void:
	for pressed: bool in [true, false]:
		var e := InputEventKey.new()
		e.keycode = key
		e.physical_keycode = key
		e.unicode = unicode if pressed else 0
		e.pressed = pressed
		Input.parse_input_event(e)
		await process_frame
	await process_frame


func _until_alive() -> void:
	var end := Time.get_ticks_msec() + 6000
	while not _game.local_player().get("alive", false) and Time.get_ticks_msec() < end:
		await process_frame


func _hold_key(key: Key, seconds: float) -> void:
	var e := InputEventKey.new()
	e.keycode = key
	e.physical_keycode = key
	e.pressed = true
	Input.parse_input_event(e)
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
	var u := InputEventKey.new()
	u.keycode = key
	u.physical_keycode = key
	Input.parse_input_event(u)
	await _frames(3)


func _step(name: String) -> void:
	_steps.append(name)
	print("  ok  %6d ms  %s" % [Time.get_ticks_msec() - _t0, name])


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
	if not cap.errors.is_empty() or not cap.warnings.is_empty():
		print(cap.report())
	_result.merge({"ok": ok, "failed": _failed, "steps": _steps, "errors": cap.errors})
	print("UNIFIED_RESULT " + JSON.stringify(_result))
	OS.remove_logger(cap)
	for p in root.get_node(^"Sfx").get_children():
		p.stop()
	root.get_node(^"Game").quit_app(0 if ok else 1)


func _frames(n: int) -> void:
	for i in n:
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


func _shot(name: String) -> void:
	if shots_dir == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shots_dir))
	get_root().get_texture().get_image().save_png("%s/%s.png" % [shots_dir, name])
	await process_frame
