extends SceneTree
## A tour of the real game with the native session (the game library must be built), driven by input actions:
##   godot --path games/survivor -s res://game/tools/tour.gd -- --no-settings [--shots=<dir>] [--quick]
## menu -> single player -> lobby -> walk out -> match (kite in circles) -> level-up -> stand still until the
## match is lost -> over -> back to the lobby -> leave. `--quick` stops after the match has enemies (a headless
## smoke check of the real flow, a few seconds). `--frames` records every frame's time, tagged with the sim events,
## steps, dashes and HUD panels around it, and reports the hitches (frames over HITCH_MS) and the worst frame after
## each first use ("FIRST <tag>"). Prints steps and `TOUR_JSON {...}`; exits 1 on failure or errors.

var cap: Logger
var shots_dir := ""
var quick := false
var _t0 := 0
var _started := false
var _failed := ""
var _done := false
var _steps: Array[Dictionary] = []

const HITCH_MS := 25.0
var frames := false
var _frame_us: PackedInt32Array = []
var _frame_tags := {}  # frame index -> Array of strings (events, steps) seen during it
var _seen := {}  # tags seen so far, for "FIRST <tag>"
var _last_us := 0
var _last_hp := -1.0
const HUD_PANELS := [^"LevelUp", ^"GameOver", ^"Respawn"]


func _init() -> void:
	cap = load("res://game/tools/log_capture.gd").new()
	OS.add_logger(cap)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			shots_dir = a.trim_prefix("--shots=")
		elif a == "--quick":
			quick = true
		elif a == "--frames":
			frames = true


func _process(_delta: float) -> bool:
	if frames:
		var now := Time.get_ticks_usec()
		if _last_us != 0:
			_frame_us.append(now - _last_us)
		_last_us = now
		_watch_hud()
	if not _started:
		_started = true
		_t0 = Time.get_ticks_msec()
		_run()
	return false


func _run() -> void:
	var game: Node = root.get_node(^"Game")
	if game.is_mock:
		_fail("the tour needs the game library (python tools/dev.py game build survivor)")
		return
	if frames:
		game.session.sim_event.connect(func(kind: StringName, _t: int, _e: int, _p: Vector3, _v: float) -> void: _tag_first(kind))
		# A window that loses focus or gets covered can stall a frame in the driver; tag it so it's not blamed on us.
		root.focus_entered.connect(_tag.bind("window focused"))
		root.focus_exited.connect(_tag.bind("window unfocused"))
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await _wait_for(func() -> bool: return _scene_is("MainMenu"), 5.0, "main menu")
	await _seconds(3.0 if frames else 0.5)  # --frames: a player's time in the menu, for what loads in the background
	await _shot("r01_menu")
	_step("menu (native session)")

	await _click(current_scene.get_node(^"UI/Root/Left/VBox/Buttons/Single"))
	await _wait_for(func() -> bool: return _scene_is("Arena"), 5.0, "arena")
	await _wait_for(func() -> bool: return game.hud.get("phase") == "lobby" and _player_views() >= 1, 8.0, "lobby with the player")
	await _seconds(1.0)
	await _shot("r02_lobby")
	_step("lobby: circle %.1f m, %d views" % [game.hud.circle_radius, current_scene.get_node(^"Views").get_child_count()])

	# Walk out of the circle (diagonally, between the crates).
	Input.action_press(&"move_right")
	Input.action_press(&"move_back")
	await _seconds(0.25)
	await _shot("r02b_leaving")  # the ring heats up near the edge
	await _wait_for(func() -> bool: return game.hud.get("phase") == "match", 6.0, "walking out starts the match")
	_step("match started")
	await _seconds(0.15)
	Input.action_release(&"move_back")
	await _shot("r03_match_start")  # shockwave + flash
	await _wait_for(func() -> bool: return int(game.hud.enemies_alive) > 0, 8.0, "enemies spawn")
	_step("enemies: %d" % game.hud.enemies_alive)
	if quick:
		_release_all()
		_finish()
		return

	# Kite in a big circle so the auto-attack works and gems get collected.
	var dirs := [[&"move_right"], [&"move_right", &"move_back"], [&"move_back"], [&"move_left", &"move_back"], [&"move_left"], [&"move_left", &"move_forward"], [&"move_forward"], [&"move_right", &"move_forward"]]
	var leveled := false
	var shot_fight := false
	var shot_dead := false
	for i in 400:  # up to ~40 s
		_release_all()
		for a: StringName in dirs[floori(i / 4.0) % dirs.size()]:
			Input.action_press(a)
		if i % 25 == 0:
			_press(&"dash")
		if frames and i == 60:
			_probe_explosion()
		await _seconds(0.1)
		if not shot_fight and int(game.hud.enemies_alive) > 25:
			shot_fight = true
			await _shot("r04_fight")
		if int(game.local_player().get("pending_levelups", 0)) > 0 and not leveled:
			leveled = true
			await _seconds(0.3)
			await _shot("r05_levelup")
			_press(&"levelup_2")
			_step("level-up offered and chosen (key 2)")
		if (leveled and shot_fight and i > 150) or game.hud.get("phase") != "match":
			break
		if not game.local_player().get("alive", true) and not shot_dead:
			shot_dead = true
			await _seconds(0.25)
			await _shot("r05b_down")
	_release_all()
	await _shot("r06_fight_later")
	_step("fight: wave %d, %d enemies, level %d" % [game.hud.wave, game.hud.enemies_alive, game.local_player().get("level", 0)])

	# Stand still until the horde wins.
	await _wait_for(func() -> bool: return game.hud.get("phase") == "over", 90.0, "the match is lost")
	await _seconds(0.8)
	await _shot("r07_over")
	_step("match over after %.0f s" % game.hud.time_s)
	await _wait_for(func() -> bool: return game.hud.get("phase") == "lobby", 10.0, "back to the lobby")
	await _seconds(0.8)
	await _shot("r08_back_in_lobby")
	_step("back in the lobby")
	game.leave_to_menu()
	await _wait_for(func() -> bool: return _scene_is("MainMenu"), 5.0, "leave")
	_step("left to the menu")
	_finish()


func _scene_is(n: String) -> bool:
	return current_scene != null and current_scene.name == n


func _player_views() -> int:
	var n := 0
	for v in current_scene.get_node(^"Views").get_children():
		if v is GameView and v.kind == &"player":
			n += 1
	return n


func _release_all() -> void:
	for a: StringName in [&"move_left", &"move_right", &"move_forward", &"move_back", &"dash", &"levelup_1", &"levelup_2", &"levelup_3"]:
		Input.action_release(a)


func _press(a: StringName) -> void:
	if a == &"dash":
		_tag_first("dash")
	Input.action_press(a)
	await process_frame
	await process_frame
	Input.action_release(a)


func _step(name: String) -> void:
	if _failed != "":
		return
	var ms := Time.get_ticks_msec() - _t0
	_steps.append({"step": name, "ms": ms})
	_tag("step: " + name)
	print("  ok  %6d ms  %s" % [ms, name])


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
	var errors: Array = cap.errors.filter(func(e: Dictionary) -> bool: return not String(e.msg).contains("ObjectDB"))
	var ok := _failed == "" and errors.is_empty()
	var frame_report := _frame_report() if frames else {}
	print("tour: %d steps, %s in %d ms" % [_steps.size(), "OK" if ok else "FAILED", Time.get_ticks_msec() - _t0])
	if not cap.errors.is_empty() or not cap.warnings.is_empty():
		print(cap.report())
	print("TOUR_JSON " + JSON.stringify({"ok": ok, "steps": _steps, "failed": _failed, "errors": errors, "frames": frame_report}))
	OS.remove_logger(cap)
	var game: Node = root.get_node(^"Game")
	if game.status != "idle":
		game.session.leave()
	game.quit_app(0 if ok else 1)  # stops the audio first: a live playback leaks at exit


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
	var path := shots_dir.path_join(name + ".png")
	root.get_texture().get_image().save_png(path)
	print("  shot " + ProjectSettings.globalize_path(path))


func _tag(t: String) -> void:
	if not frames:
		return
	var i := _frame_us.size()
	if not _frame_tags.has(i):
		_frame_tags[i] = []
	if not _frame_tags[i].has(t):
		_frame_tags[i].append(t)


## Barrels only explode from stray shots, so the run rarely sees one: play the effect (client-only, no sim change) near
## the camera to measure its first use.
func _probe_explosion() -> void:
	var at: Vector3 = current_scene.get_node(^"Views").get_children().filter(func(v: Node) -> bool: return v is GameView and v.kind == &"player")[0].global_position
	_tag_first("probe: barrel_exploded")
	current_scene.get_node(^"Fx").play(&"barrel_exploded", 0, at + Vector3(3, 0, 0), 4.0, false)


func _tag_first(t: String) -> void:
	_tag(t if _seen.has(t) else "FIRST " + t)
	_seen[t] = true


## Tags the first frame each HUD panel and banner size is shown (a first draw can rasterize glyphs or compile).
func _watch_hud() -> void:
	var hud := current_scene.get_node_or_null(^"HUD/Root") if current_scene != null else null
	if hud == null:
		return
	for p: NodePath in HUD_PANELS:
		var c: CanvasItem = hud.get_node(p)
		if c.is_visible_in_tree() and not _seen.has("show " + str(p)):
			_tag_first("show " + str(p))
	var banner: Label = hud.get_node(^"Banner")
	if banner.is_visible_in_tree() and banner.modulate.a > 0.0:
		_tag_first("banner %dpx" % banner.get_theme_font_size(&"font_size"))
	var hp: float = root.get_node(^"Game").local_player().get("hp", -1.0)
	if _last_hp >= 0.0 and hp < _last_hp - 0.01:
		_tag_first("player hit")  # the hit flash
	_last_hp = hp


## Frame-time summary plus every hitch with what happened in it and the three frames before ([-1] = one frame
## earlier: work started there, e.g. a new material, is drawn and measured in the next frame).
func _frame_report() -> Dictionary:
	var sorted := _frame_us.duplicate()
	sorted.sort()
	var n := sorted.size()
	if n == 0:
		return {}
	var pct := func(q: float) -> float: return sorted[mini(n - 1, int(q * n))] / 1000.0
	var hitches: Array = []
	for i in n:
		var ms := _frame_us[i] / 1000.0
		if ms < HITCH_MS:
			continue
		var tags: Array = []
		for j in range(i - 3, i + 1):
			for t: String in _frame_tags.get(j, []):
				tags.append("%s%s" % ["" if j == i else "[%d] " % (j - i), t])
		if ms > 990.0 and ms < 1030.0:  # Metal waits up to 1 s for a drawable while the window is hidden or covered
			tags.append("~1 s: window hidden or covered?")
		hitches.append({"frame": i, "ms": snappedf(ms, 0.1), "tags": tags})
	print("frames: %d, p50 %.1f ms, p99 %.1f ms, max %.1f ms, %d over %.0f ms" % [n, pct.call(0.5), pct.call(0.99), sorted[n - 1] / 1000.0, hitches.size(), HITCH_MS])
	for h: Dictionary in hitches:
		print("  hitch  frame %5d  %6.1f ms  %s" % [h.frame, h.ms, ", ".join(h.tags)])
	# The worst of the four frames from each first use: a first draw is measured in the same or the next frame.
	var firsts := {}
	for i: int in _frame_tags:
		for t: String in _frame_tags[i]:
			if t.begins_with("FIRST "):
				var worst := 0
				for j in range(i, mini(i + 4, n)):
					worst = maxi(worst, _frame_us[j])
				firsts[t.trim_prefix("FIRST ")] = snappedf(worst / 1000.0, 0.1)
	print("first uses (worst frame of 4): " + ", ".join(firsts.keys().map(func(k: String) -> String: return "%s %.1f" % [k, firsts[k]])))
	return {"count": n, "p50_ms": pct.call(0.5), "p99_ms": pct.call(0.99), "max_ms": sorted[n - 1] / 1000.0, "hitches": hitches, "firsts": firsts}
