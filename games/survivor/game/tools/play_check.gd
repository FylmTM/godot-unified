extends SceneTree
## Real-play check with the native extension (not the mock), driven like a player: real clicks, InputMap
## actions held and released, the level-up panel answered with its keys.
##   godot --path games/survivor --resolution 1280x720 -s res://game/tools/play_check.gd -- [--minutes 3] [--coop]
##         [--shots=res://.uni/shots]
## --bench N (single player, the extension holds N enemies in an endless match): only the timed play, for frame
## time at a fixed population.
## --coop hosts on LAN instead and starts a headless second player (scripted input) that joins: the match then
## survives one death, so the enemy count climbs past 1000 for the frame-time numbers.
## menu -> single player -> lobby -> walk out of the start circle -> play (circle-strafe, pick level-ups) ->
## stand still until the match is over -> back in the lobby. Measures frame time and sim rate by enemy count.
## Prints `PLAY_JSON {...}`; exits 1 on a failed expectation or any engine/script error.

var cap: Logger
var shots_dir := ""
var minutes := 3.0
var _t0 := 0
var _steps: Array[Dictionary] = []
var _failed := ""
var _done := false
var _started := false
var _events := {}
var _shots: Array[String] = []
var _frames_by_band := {}  # enemy band (0, 250, 500, 750, 1000) -> [count, sum_ms, max_ms]
var _last_us := 0
var _max_enemies := 0
var _levelups_chosen := 0
var _game: Node
var coop := false
var bench := 0
var _joiner_pid := -1
var _paused_measure := false
const COOP_PORT := 47777


func _init() -> void:
	cap = load("res://game/tools/log_capture.gd").new()
	OS.add_logger(cap)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			shots_dir = a.trim_prefix("--shots=")
	var args := OS.get_cmdline_user_args()
	coop = "--coop" in args
	var bi := args.find("--bench")
	if bi >= 0 and bi + 1 < args.size():
		bench = int(args[bi + 1])
	var i := args.find("--minutes")
	if i >= 0 and i + 1 < args.size():
		minutes = float(args[i + 1])


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_t0 = Time.get_ticks_msec()
		_run()
	var now := Time.get_ticks_usec()
	if _last_us != 0 and not _paused_measure and _game != null and _game.hud.get("phase", "") == "match":
		var ms := (now - _last_us) / 1000.0
		var n: int = _game.hud.get("enemies_alive", 0)
		_max_enemies = max(_max_enemies, n)
		var band := mini(floori(n / 250.0), 4) * 250
		var b: Array = _frames_by_band.get(band, [0, 0.0, 0.0, 0])
		b[0] += 1
		b[1] += ms
		b[2] = maxf(b[2], ms)
		if ms > 33.0:
			b[3] += 1
		_frames_by_band[band] = b
	_last_us = now
	return false


func _run() -> void:
	_game = root.get_node(^"Game")
	if _game.is_mock:
		_fail("the play check needs the native extension (python tools/dev.py game build survivor)")
		return
	_game.session.sim_event.connect(func(kind: StringName, _t: int, _e: int, _p: Vector3, _v: float) -> void: _events[kind] = _events.get(kind, 0) + 1)
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "MainMenu", 5.0, "main menu loads")
	await _frames(5)
	if coop:
		_game.host_direct(COOP_PORT)
	else:
		await _click(_find(current_scene, "UI/Root/Left/VBox/Buttons/Single"))
	await _wait_for(func() -> bool: return current_scene != null and current_scene.name == "Arena", 5.0, "arena loads")
	if bench > 0:
		await _bench_run()
		return
	await _wait_for(func() -> bool: return _game.hud.get("phase", "") == "lobby" and _me() != null, 5.0, "lobby with my player view")
	if coop:
		_joiner_pid = OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--", "--join", "127.0.0.1:%d" % COOP_PORT, "--scripted", "--no-settings"])
		await _wait_for(func() -> bool: return _present() == 2, 15.0, "the scripted second player joins")
		_step("co-op: second player joined (pid %d)" % _joiner_pid)
	_expect(_game.hud.circle_radius > 0.0, "start circle radius in the lobby (%s)" % _game.hud.circle_radius)
	await _wait_seconds(1.0)
	await _shot("play_01_lobby")
	_step("single player lobby (circle %.1f m)" % _game.hud.circle_radius)

	# Walk out of the start circle.
	Input.action_press(&"move_right")
	await _wait_for(func() -> bool: return _game.hud.phase == "match", 6.0, "walking out of the circle starts the match")
	Input.action_release(&"move_right")
	_expect(_events.get(&"match_started", 0) >= 1, "match_started event")
	_step("walked out: match started")

	# Play: circle-strafe around the arena centre, answer level-ups with keys 1-3.
	var end := Time.get_ticks_msec() + int(minutes * 60000.0)
	var shot_match := false
	var shot_levelup := false
	var shot_crowd := false
	var held: Array[StringName] = []
	while _failed == "" and Time.get_ticks_msec() < end and _game.hud.phase == "match":
		var me := _me()
		var lp: Dictionary = _game.local_player()
		if me != null and lp.get("alive", false):
			held = _steer(me.global_position, held)
		if lp.get("pending_levelups", 0) > 0 and _visible("HUD/Root/LevelUp"):
			if not shot_levelup:
				shot_levelup = true
				await _frames(8)
				await _shot("play_03_levelup")
			var before: int = lp.pending_levelups
			await _press_action(StringName("levelup_%d" % (_levelups_chosen % 3 + 1)))
			await _wait_for(func() -> bool: return int(_game.local_player().get("pending_levelups", 0)) < before, 2.0, "a level-up key consumes the level-up")
			_levelups_chosen += 1
		if not shot_match and _game.hud.time_s > 20.0:
			shot_match = true
			await _shot("play_02_match")
		if not shot_crowd and _game.hud.enemies_alive >= (1000 if coop else 600):
			shot_crowd = true
			await _shot("play_04_crowd_%d%s" % [_game.hud.enemies_alive, "_coop" if coop else ""])
		await process_frame
	for a in held:
		Input.action_release(a)
	Input.action_release(&"dash")
	_step("played %.0f s: wave %d, %d enemies alive (max %d), %d kills, %d gems, %d level-ups chosen" % [
		_game.hud.time_s, _game.hud.wave, _game.hud.enemies_alive, _max_enemies, _events.get(&"enemy_died", 0),
		_events.get(&"gem_collected", 0), _levelups_chosen])
	_expect(_events.get(&"enemy_died", 0) > 0, "auto-attack kills enemies")
	_expect(_events.get(&"gem_collected", 0) > 0, "gems are collected")

	if coop and _joiner_pid > 0:
		OS.kill(_joiner_pid)  # the match ends once everyone present is dead
		_joiner_pid = -1
		await _wait_for(func() -> bool: return _present() == 1, 15.0, "the second player leaves")
	# Stand still until the match is over (single player: the first death ends it).
	await _wait_for(func() -> bool: return _game.hud.phase == "over", 240.0, "standing still: the match ends")
	_expect(_events.get(&"player_died", 0) >= 1, "player_died event")
	await _wait_for(func() -> bool: return _visible("HUD/Root/GameOver"), 3.0, "match-over panel shows")
	await _frames(15)
	await _shot("play_05_game_over")
	_step("match over after %.0f s, wave %d" % [_game.hud.time_s, _game.hud.wave])
	await _wait_for(func() -> bool: return _game.hud.phase == "lobby", 10.0, "the sim returns to the lobby")
	await _wait_for(func() -> bool: return _me() != null and _game.local_player().get("alive", false), 5.0, "player respawned in the lobby")
	await _wait_seconds(1.0)
	await _shot("play_06_back_in_lobby")
	_expect(_events.get(&"player_respawned", 0) >= 1, "player_respawned event")
	_step("back in the lobby (matches played: %d)" % _game.hud.get("matches", 0))
	await _devui_check()
	_finish()


## F1 as a real key opens the dev UI (inspector over the predicted survivor state), F1 again closes it.
func _devui_check() -> void:
	await _press_key(KEY_F1)
	await _wait_for(func() -> bool: return _game.session.is_devui_visible(), 2.0, "F1 opens the dev UI")
	await _frames(20)
	await _shot("play_08_devui")
	await _press_key(KEY_F1)
	await _wait_for(func() -> bool: return not _game.session.is_devui_visible(), 2.0, "F1 closes the dev UI")
	_step("dev UI toggled with F1")


func _press_key(key: Key) -> void:
	for pressed: bool in [true, false]:
		var e := InputEventKey.new()
		e.keycode = key
		e.physical_keycode = key
		e.pressed = pressed
		Input.parse_input_event(e)
		await process_frame
	await process_frame


## Dodge: score 16 headings by the enemies near the point 2.5 m ahead (read from the bulk MultiMeshes the
## extension writes), walls and pillars as hard edges, a pull towards nearby gems and a bonus for keeping the last
## heading; replanned every 4 frames. Dash when an enemy is close. Strengths go through the InputMap like a stick.
var _heading := Vector2.RIGHT
var _plan_frame := 0


func _bulk_points(kinds: Array, near: Vector2, radius: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var r2 := radius * radius
	for mmi in get_nodes_in_group(&"sim_bulk"):
		if not (mmi.get("kind") in kinds) or mmi.multimesh == null:
			continue
		var mm: MultiMesh = mmi.multimesh
		for i in mm.visible_instance_count:
			var o := mm.get_instance_transform(i).origin
			var q := Vector2(o.x, o.z)
			if q.distance_squared_to(near) < r2:
				out.append(q)
	return out


func _steer(p: Vector3, _held: Array[StringName]) -> Array[StringName]:
	var me := Vector2(p.x, p.z)
	_plan_frame += 1
	var nearest := 1e9
	if _plan_frame % 4 == 0:
		var enemies := _bulk_points([&"grunt", &"runner", &"brute"], me, 12.0)
		var gems := _bulk_points([&"gem"], me, 10.0)
		for e in enemies:
			nearest = minf(nearest, e.distance_to(me))
		var best := 1e18
		var best_dir := _heading
		for k in 16:
			var dir := Vector2.from_angle(k * TAU / 16.0)
			var cost := 0.0
			for step: float in [1.2, 2.5, 4.0]:
				var q: Vector2 = me + dir * step
				if absf(q.x) > 27.5 or absf(q.y) > 27.5:
					cost += 1000.0
				for kk in 8:
					if q.distance_to(Vector2.from_angle(kk * PI / 4.0) * 14.0) < 2.2:
						cost += 200.0
				for e in enemies:
					var d := q.distance_to(e)
					if d < 6.0:
						cost += 8.0 / (0.3 + d * d)
			for g in gems:
				cost -= 1.5 / (1.0 + (me + dir * 2.5).distance_to(g))
			cost -= dir.dot(_heading) * 0.8  # smooth
			cost += (me + dir * 2.5).length() * 0.02  # mild pull to the centre
			if cost < best:
				best = cost
				best_dir = dir
		_heading = best_dir
		if nearest < 1.5:
			Input.action_press(&"dash")
		else:
			Input.action_release(&"dash")
	var acts: Array[StringName] = [&"move_right", &"move_left", &"move_back", &"move_forward"]
	var strength := [maxf(_heading.x, 0.0), maxf(-_heading.x, 0.0), maxf(_heading.y, 0.0), maxf(-_heading.y, 0.0)]
	for i in 4:
		if strength[i] > 0.05:
			Input.action_press(acts[i], strength[i])
		else:
			Input.action_release(acts[i])
	return acts


func _me() -> Node3D:
	var slot: int = _game.hud.get("local_slot", -1)
	if current_scene == null or slot < 0:
		return null
	for n: Node in _game.session.view_root.get_children() if _game.session.view_root != null else []:
		if n.get("slot") == slot and n.get("kind") == &"player":
			return n
	return null


## Bench: an endless match holding `bench` enemies; the bot dodges for `minutes`, frames are measured.
func _bench_run() -> void:
	await _wait_for(func() -> bool: return _game.hud.get("phase", "") == "match" and _me() != null, 10.0, "bench match running")
	await _wait_for(func() -> bool: return int(_game.hud.enemies_alive) >= bench * 0.9, 20.0, "the bench population spawns")
	_step("bench: %d enemies" % _game.hud.enemies_alive)
	var end := Time.get_ticks_msec() + int(minutes * 60000.0)
	var shot := false
	var held: Array[StringName] = []
	var tick0: int = _game.hud.tick
	var t0 := Time.get_ticks_msec()
	while _failed == "" and Time.get_ticks_msec() < end:
		var me := _me()
		if me != null and _game.local_player().get("alive", false):
			held = _steer(me.global_position, held)
		if not shot and Time.get_ticks_msec() - t0 > 10000:
			shot = true
			await _shot("play_07_bench_%d" % _game.hud.enemies_alive)
		await process_frame
	for a in held:
		Input.action_release(a)
	var ticks_per_s := (int(_game.hud.tick) - tick0) * 1000.0 / maxf(Time.get_ticks_msec() - t0, 1)
	_expect(ticks_per_s > 60.0, "the sim keeps its 64 Hz (%.1f ticks/s)" % ticks_per_s)
	_step("bench: %.0f s at %d enemies, sim %.1f ticks/s, %d kills, %d deaths" % [minutes * 60.0, _game.hud.enemies_alive,
		ticks_per_s, _events.get(&"enemy_died", 0), _events.get(&"player_died", 0)])
	_finish()


func _present() -> int:
	var n := 0
	for p: Dictionary in _game.hud.get("players", []):
		if p.get("present", false):
			n += 1
	return n


func _visible(path: String) -> bool:
	var n := current_scene.get_node_or_null(path) if current_scene != null else null
	return n != null and n.is_visible_in_tree()


# --- harness (as tools/ui_walk.gd) ----------------------------------------------------------------


func _step(name: String) -> void:
	if _failed != "":
		return
	var ms := Time.get_ticks_msec() - _t0
	_steps.append({"step": name, "ms": ms})
	print("  ok  %6d ms  %s" % [ms, name])


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
	if _joiner_pid > 0:
		OS.kill(_joiner_pid)
	var ok: bool = _failed == "" and cap.errors.is_empty()
	var bands := {}
	for band: int in _frames_by_band:
		var b: Array = _frames_by_band[band]
		bands[str(band)] = {"frames": b[0], "mean_ms": snappedf(b[1] / maxf(b[0], 1), 0.01), "max_ms": snappedf(b[2], 0.01),
			"over_33ms": b[3]}
	if not cap.errors.is_empty() or not cap.warnings.is_empty():
		print(cap.report())
	print("PLAY_JSON " + JSON.stringify({"ok": ok, "ms": Time.get_ticks_msec() - _t0, "steps": _steps, "failed": _failed,
		"errors": cap.errors, "events": _events, "max_enemies": _max_enemies, "frame_ms_by_enemies": bands,
		"levelups_chosen": _levelups_chosen, "shots": _shots}))
	OS.remove_logger(cap)
	for p in root.get_node(^"Sfx").get_children():
		p.stop()
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


func _click(c: Control) -> void:
	if c == null or _failed != "":
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


func _press_action(action: StringName) -> void:
	for pressed: bool in [true, false]:
		var e := InputEventAction.new()
		e.action = action
		e.pressed = pressed
		Input.parse_input_event(e)
		await process_frame
	await process_frame


func _shot(name: String) -> void:
	if shots_dir == "" or DisplayServer.get_name() == "headless":
		return
	_paused_measure = true  # the capture itself stalls the frame
	await RenderingServer.frame_post_draw
	var path := "%s/%s%s.png" % [shots_dir, name, "_coop" if coop and not name.ends_with("_coop") else ""]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shots_dir))
	get_root().get_texture().get_image().save_png(path)
	_shots.append(path)
	await process_frame
	_paused_measure = false
	_last_us = 0
