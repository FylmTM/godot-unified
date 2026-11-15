extends UnifiedTool
## Real-play check with the game library, driven like a player: real clicks, InputMap
## actions held and released, the level-up panel answered with its keys.
##   godot --path games/survivor --resolution 1280x720 -s res://game/tools/play_check.gd -- [--minutes 3] [--coop]
##         [--shots=res://.out/shots]
## --bench N (single player, the extension holds N enemies in an endless match): only the timed play, for frame
## time at a fixed population.
## --coop hosts on LAN instead and starts a headless second player (scripted input) that joins: the match then
## survives one death, so the enemy count climbs past 1000 for the frame-time numbers.
## menu -> single player -> lobby -> walk out of the start circle -> play (circle-strafe, pick level-ups) ->
## stand still until the match is over -> back in the lobby. Measures frame time and sim rate by enemy count.
## The result adds the sim events seen, the most enemies alive and the frame times by enemy count.

const COOP_PORT := 47777

var minutes := 3.0
var coop := false
var bench := 0
var _events: Dictionary[StringName, int] = {}
## Enemy band (0, 250, 500, 750, 1000) -> [count, sum_ms, max_ms, frames over 33 ms].
var _frames_by_band: Dictionary[int, Array] = {}
var _last_us := 0
var _max_enemies := 0
var _levelups_chosen := 0
var _joiner_pid := -1
var _paused_measure := false
var _heading := Vector2.RIGHT
var _plan_frame := 0


func _process(delta: float) -> bool:
	var now := Time.get_ticks_usec()
	if _last_us != 0 and not _paused_measure and game != null and Unified.data.hud.phase == EnumPhase.MATCH:
		var ms := (now - _last_us) / 1000.0
		var n: int = Unified.data.hud.enemies_alive
		_max_enemies = maxi(_max_enemies, n)
		var band := mini(floori(n / 250.0), 4) * 250
		var b: Array = _frames_by_band.get(band, [0, 0.0, 0.0, 0])
		b[0] += 1
		b[1] += ms
		b[2] = maxf(b[2], ms)
		if ms > 33.0:
			b[3] += 1
		_frames_by_band[band] = b
	_last_us = now
	return super(delta)


func _run() -> void:
	minutes = float(arg("minutes", "3"))
	coop = flag("coop")
	bench = int(arg("bench", "0"))
	session.sim_event.connect(func(event: UnifiedEvent, state: int) -> void:
		if state == UnifiedSession.EVENT_CONFIRMED:
			var kind := StringName(event.kind)
			_events[kind] = _events.get(kind, 0) + 1)
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await wait_for_scene("MainMenu", 5.0)
	await frames(5)
	if coop:
		game.host_direct(COOP_PORT)
	else:
		await click_menu("Single")
	await wait_for_scene("Arena", 5.0)
	if bench > 0:
		await _bench_run()
		return
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.LOBBY and _me() != null, 5.0,
		"lobby with my player view")
	if coop:
		_joiner_pid = OS.create_process(OS.get_executable_path(), ["--headless", "--path",
			ProjectSettings.globalize_path("res://"),
			"--", "--join", "127.0.0.1:%d" % COOP_PORT, "--scripted", "--no-settings"])
		await wait_for(func() -> bool: return game.present_players().size() == 2, 15.0,
			"the scripted second player joins")
		step("co-op: second player joined (pid %d)" % _joiner_pid)
	expect(Unified.data.hud.circle_radius > 0.0, "start circle radius in the lobby (%s)" % Unified.data.hud.circle_radius)
	await seconds(1.0)
	await _shot_paused("play_01_lobby")
	step("single player lobby (circle %.1f m)" % Unified.data.hud.circle_radius)

	# Walk out of the start circle.
	Input.action_press(&"move_right")
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.MATCH, 6.0,
		"walking out of the circle starts the match")
	Input.action_release(&"move_right")
	expect(_events.get(&"match_started", 0) >= 1, "match_started event")
	step("walked out: match started")

	# Play: circle-strafe around the arena centre, answer level-ups with keys 1-3.
	var end := Time.get_ticks_msec() + int(minutes * 60000.0)
	var shot_match := false
	var shot_levelup := false
	var shot_crowd := false
	var held: Array[StringName] = []
	while not failed() and Time.get_ticks_msec() < end and Unified.data.hud.phase == EnumPhase.MATCH:
		var me := _me()
		var lp: Dictionary = game.local_player_info()
		if me != null and lp.get("alive", false):
			held = _steer(me.global_position, held)
		if lp.get("pending_levelups", 0) > 0 and _visible("HUD/Root/LevelUp"):
			if not shot_levelup:
				shot_levelup = true
				await frames(8)
				await _shot_paused("play_03_levelup")
			var before: int = lp.pending_levelups
			await press_action(StringName("levelup_%d" % (_levelups_chosen % 3 + 1)))
			await wait_for(func() -> bool: return int(game.local_player_info().get("pending_levelups", 0)) < before, 2.0,
				"a level-up key consumes the level-up")
			_levelups_chosen += 1
		if not shot_match and Unified.data.hud.time_s > 20.0:
			shot_match = true
			await _shot_paused("play_02_match")
		if not shot_crowd and Unified.data.hud.enemies_alive >= (1000 if coop else 600):
			shot_crowd = true
			await _shot_paused("play_04_crowd_%d%s" % [Unified.data.hud.enemies_alive, "_coop" if coop else ""])
		await process_frame
	for a in held:
		Input.action_release(a)
	Input.action_release(&"dash")
	step("played %.0f s: wave %d, %d enemies alive (max %d), %d kills, %d gems, %d level-ups chosen" % [
		Unified.data.hud.time_s, Unified.data.hud.wave, Unified.data.hud.enemies_alive, _max_enemies, _events.get(&"enemy_died", 0),
		_events.get(&"gem_collected", 0), _levelups_chosen])
	expect(_events.get(&"enemy_died", 0) > 0, "auto-attack kills enemies")
	expect(_events.get(&"gem_collected", 0) > 0, "gems are collected")

	if coop and _joiner_pid > 0:
		OS.kill(_joiner_pid)  # the match ends once everyone present is dead
		_joiner_pid = -1
		await wait_for(func() -> bool: return game.present_players().size() == 1, 15.0, "the second player leaves")
	# Stand still until the match is over (single player: the first death ends it).
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.OVER, 240.0, "standing still: the match ends")
	expect(_events.get(&"player_died", 0) >= 1, "player_died event")
	await wait_for(func() -> bool: return _visible("HUD/Root/GameOver"), 3.0, "match-over panel shows")
	await frames(15)
	await _shot_paused("play_05_game_over")
	step("match over after %.0f s, wave %d" % [Unified.data.hud.time_s, Unified.data.hud.wave])
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.LOBBY, 10.0, "the sim returns to the lobby")
	await wait_for(func() -> bool: return _me() != null and game.local_player_info().get("alive", false), 5.0,
		"player respawned in the lobby")
	await seconds(1.0)
	await _shot_paused("play_06_back_in_lobby")
	expect(_events.get(&"player_respawned", 0) >= 1, "player_respawned event")
	step("back in the lobby (matches played: %d)" % Unified.data.hud.matches)
	await _devui_check()


## F1 as a real key opens the dev UI (inspector over the predicted survivor state), F1 again closes it.
func _devui_check() -> void:
	await _press_key(KEY_F1)
	await wait_for(func() -> bool: return game.session.is_devui_visible(), 2.0, "F1 opens the dev UI")
	await frames(20)
	await _shot_paused("play_08_devui")
	await _press_key(KEY_F1)
	await wait_for(func() -> bool: return not game.session.is_devui_visible(), 2.0, "F1 closes the dev UI")
	step("dev UI toggled with F1")


func _press_key(key: Key) -> void:
	for pressed: bool in [true, false]:
		var e := InputEventKey.new()
		e.keycode = key
		e.physical_keycode = key
		e.pressed = pressed
		Input.parse_input_event(e)
		await process_frame
	await process_frame


## Dodge: score 16 headings by the enemies near the point 2.5 m ahead (read from the MultiMesh views the
## extension writes), walls and pillars as hard edges, a pull towards nearby gems and a bonus for keeping the last
## heading; replanned every 4 frames. Dash when an enemy is close. Strengths go through the InputMap like a stick.

func _bulk_points(kinds: Array, near: Vector2, radius: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var r2 := radius * radius
	for marker: Node in root.find_children("*", "UnifiedMultiView", true, false):
		var mmi := marker.get_parent() as MultiMeshInstance3D
		if not ((marker as UnifiedMultiView).kind in kinds) or mmi == null or mmi.multimesh == null:
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
		var enemies := _bulk_points(["grunt", "runner", "brute"], me, 12.0)
		var gems := _bulk_points(["gem"], me, 10.0)
		for e in enemies:
			nearest = minf(nearest, e.distance_to(me))
		var best := 1e18
		var best_dir := _heading
		for k in 16:
			var dir := Vector2.from_angle(k * TAU / 16.0)
			var cost := 0.0
			for ahead: float in [1.2, 2.5, 4.0]:
				var q: Vector2 = me + dir * ahead
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
	var player: int = game.local_player()
	if current_scene == null or player == 0:
		return null
	for n in views(&"player"):
		if (n.get_node(^"UnifiedView") as UnifiedView).player == player:
			return n as Node3D
	return null


## Bench: an endless match holding `bench` enemies; the bot dodges for `minutes`, frames are measured.
func _bench_run() -> void:
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.MATCH and _me() != null, 10.0,
		"bench match running")
	await wait_for(func() -> bool: return Unified.data.hud.enemies_alive >= bench * 0.9, 20.0,
		"the bench population spawns")
	step("bench: %d enemies" % Unified.data.hud.enemies_alive)
	var end := Time.get_ticks_msec() + int(minutes * 60000.0)
	var shot_taken := false
	var held: Array[StringName] = []
	var tick0: int = Unified.data.hud.tick
	var t0 := Time.get_ticks_msec()
	while not failed() and Time.get_ticks_msec() < end:
		var me := _me()
		if me != null and game.local_player_info().get("alive", false):
			held = _steer(me.global_position, held)
		if not shot_taken and Time.get_ticks_msec() - t0 > 10000:
			shot_taken = true
			await _shot_paused("play_07_bench_%d" % Unified.data.hud.enemies_alive)
		await process_frame
	for a in held:
		Input.action_release(a)
	var ticks_per_s := (Unified.data.hud.tick - tick0) * 1000.0 / maxf(Time.get_ticks_msec() - t0, 1)
	expect(ticks_per_s > 60.0, "the sim keeps its 64 Hz (%.1f ticks/s)" % ticks_per_s)
	step("bench: %.0f s at %d enemies, sim %.1f ticks/s, %d kills, %d deaths" % [minutes * 60.0, Unified.data.hud.enemies_alive,
		ticks_per_s, _events.get(&"enemy_died", 0), _events.get(&"player_died", 0)])


func _visible(path: String) -> bool:
	var n := current_scene.get_node_or_null(path) if current_scene != null else null
	return n != null and n.is_visible_in_tree()



func finish() -> void:
	if _joiner_pid > 0:
		OS.kill(_joiner_pid)
		_joiner_pid = -1
	var bands := {}
	for band: int in _frames_by_band:
		var b: Array = _frames_by_band[band]
		bands[str(band)] = {"frames": b[0], "mean_ms": snappedf(b[1] / maxf(b[0], 1), 0.01),
			"max_ms": snappedf(b[2], 0.01), "over_33ms": b[3]}
	result.merge({"events": _events, "max_enemies": _max_enemies, "frame_ms_by_enemies": bands,
		"levelups_chosen": _levelups_chosen})
	super()


## A screenshot (a window only) left out of the frame times: the capture itself stalls the frame.
func _shot_paused(shot_name: String) -> void:
	if shots_dir == "" or DisplayServer.get_name() == "headless":
		return
	_paused_measure = true
	await shot(shot_name + ("_coop" if coop and not shot_name.ends_with("_coop") else ""))
	await process_frame
	_paused_measure = false
	_last_us = 0
