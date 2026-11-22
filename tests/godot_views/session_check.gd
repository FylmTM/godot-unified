# unified:godot session lifecycle tests: run headless by `uni test --suite godot-bindings`, on the toy's session (the
# extension in ext/). Leave, then host or join at once, while the left session is still saying goodbye:
# 1. join a silent UDP peer (the client lingers up to 2 s for its Leave's ack), leave, start single player at once:
#    the start is accepted, waits for the goodbye (cut to 1 s) and connects.
# 2. host on a LAN port, leave, host on the same port at once: the old socket is closed before the new one opens; it
#    closes to new players and opens again (close_online, open_direct).
# 3. (after 2) leave, host at once, leave again before the old session is gone: the waiting start is dropped ("left").
# 4. a session that ends on its own (its ticks ran out) stops answering from its last frame: no local player.
# 5. a session's Setup (start_single(setup), session.setup, the default again; a save from save_changed) and a second
#    local player (and local_players_changed saying so, and roster_changed once the shown tick has them present, and
#    gone).
# 6. open to friends: a running single-player session hosts on a port and closes; a failed open leaves it running.
# 7. a replay: a 40-tick session's recording (user://recordings) played back, and every control a replay viewer uses
#    (speed, seek, step, loop, the player it follows, the checkpoints it agreed with).
# 8. a start on a running session leaves it by itself: start_single again restarts with the new Setup, no failure; a
#    host then a single player started at once: the newest start wins.
# 9. event objects: none while nobody listens; one per class, refilled, while a listener keeps none; a new one for
#    each event a listener keeps, never refilled.
# Every run ends with UnifiedSession.quit while a sound plays: the quit stops it first, so no playback leaks at exit
# (the suite fails on a leak).
# (The LAN token's claim, each copy of a game a slot and a token of its own, is tested in tests/godot_driver.)
#   godot --path tests/godot_views --headless -s res://session_check.gd -- [--sections 1,2,...] [--idle-end S]
# --sections: only these, in order (default: all). Most of the time is spent waiting on purpose (goodbyes, timers),
# so the suite runs groups of them in Godot processes at once. Ports are the OS's pick: runs at once never meet.
# --idle-end S: stay S seconds with no session before quitting (to see the power activity released).
# Prints one line per check and "SESSION TESTS: <n> failed"; exits with the failure count.
extends SceneTree

## The replay section's session length: no other section records one as long, so its recording is told from theirs.
const REPLAY_TICKS := 48

var s: Node
var failed := 0
var idle_end := 0.0
var sections: Array[int] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
var _statuses: Array[String] = []
var _started := false
var _port := 0  # the port section 2 hosted on (section 3 hosts there again)


func check(name: String, ok: bool, detail = "") -> void:
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, str(detail)])
	if not ok:
		failed += 1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--idle-end")
	if i >= 0 and i + 1 < args.size():
		idle_end = float(args[i + 1])
	i = args.find("--sections")
	if i >= 0 and i + 1 < args.size():
		sections.clear()
		for part in args[i + 1].split(","):
			sections.append(int(part))
	s = ClassDB.instantiate("UnifiedSession")
	s.view_root = null  # status checks only: no scene views (unset, they would go under the session's parent)
	root.add_child(s)
	s.status_changed.connect(func(st: UnifiedSession.Status, detail: String) -> void:
		_statuses.append(_status_name(st) + (":" + detail if detail != "" else "")))


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	await process_frame
	for section in sections:
		var went_on: bool
		match section:
			1:
				went_on = await _leave_then_single()
			2:
				went_on = await _host_again_on_the_port()
			3:
				went_on = await _cancelled_start()
			4:
				went_on = await _ended_session()
			5:
				went_on = await _setup_and_locals()
			6:
				went_on = await _open_to_friends()
			7:
				went_on = await _replay()
			8:
				went_on = await _restart()
			9:
				went_on = await _event_objects()
			_:
				check("section %d exists" % section, false)
				went_on = false
		if not went_on:
			return _finish()
	if idle_end > 0.0:
		print("session_check: idle with no session for %.1f s" % idle_end)
		await _sleep(idle_end)
	_finish()


# Each section returns false when a wait timed out (a failed check): the run stops there.


# 1. a client lingering for its Leave's ack, then single player at once
func _leave_then_single() -> bool:
	var silent := PacketPeerUDP.new()
	if silent.bind(0, "127.0.0.1") != OK:
		check("bind the silent peer", false)
		return false
	check("join the silent peer", s.join_direct("127.0.0.1:%d" % silent.get_local_port()))
	await _sleep(0.4)
	_statuses.clear()
	s.leave()
	var t := Time.get_ticks_msec()
	check("start_single right after leave is accepted", s.start_single())
	check("status is connecting while the goodbye runs", s.status == UnifiedSession.STATUS_CONNECTING, s.status)
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 10, 5.0, "single player runs"):
		return false
	var waited := Time.get_ticks_msec() - t
	check("the goodbye was cut short", waited < 2000, "%d ms" % waited)
	check("no failed/disconnected/left status reaches the game",
		not _statuses.has("failed") and not _statuses.any(func(x: String) -> bool:
			return x.begins_with("disconnected") or x.begins_with("left")), _statuses)
	silent.close()
	return true


# 2. host, leave, host on the same port at once
func _host_again_on_the_port() -> bool:
	s.leave()
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "no session runs"):
		return false
	check("host on a port the OS picks", s.host_direct(0))
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 5 and s.join_code != "", 5.0, "hosting"):
		return false
	_port = int(s.join_code.get_slice(":", 1))
	check("the join code names the port", _port > 0, s.join_code)
	_statuses.clear()
	s.leave()
	check("host again on port %d right after leave" % _port, s.host_direct(_port))
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 5, 5.0, "hosting again"):
		return false
	check("the port was free", not _statuses.has("failed:cannot listen on UDP port %d" % _port), _statuses)
	# a session hosted from the start closes and opens again like one opened from single player
	var code: String = s.join_code
	check("close_online on a hosted session", s.close_online())
	check("closing clears its join code", s.join_code == "", s.join_code)
	check("open_direct again", s.open_direct(_port))
	if not await _wait_for(func() -> bool: return s.join_code == code, 5.0, "the join code is back"):
		return false
	return true


# 3. leave, host at once, leave again: the waiting start is dropped
func _cancelled_start() -> bool:
	_statuses.clear()
	s.leave()
	check("host right after leave (to be cancelled)", s.host_direct(_port))
	s.leave()
	check("a cancelled start reports left", s.status == UnifiedSession.STATUS_LEFT, s.status)
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "no session runs after the cancel"):
		return false
	await _sleep(0.3)
	check("the cancelled start never ran", not s.running)
	return true


# 4. a session that ends on its own: its last frame stays on screen, nothing answers from it
func _ended_session() -> bool:
	s.ticks = 40
	check("start a 40-tick single player", s.start_single())
	if not await _wait_for(func() -> bool: return s.local_player != 0, 5.0, "the short session runs"):
		return false
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "the short session ends"):
		return false
	await _sleep(0.2)
	check("an ended session has no local player", s.local_player == 0, s.local_player)
	s.ticks = 0
	return true


# 5. the session's Setup, its save, the player's Profile, a second local player
func _setup_and_locals() -> bool:
	var setup := UnifiedSetup.new()
	check("a new UnifiedSetup is the game's default", setup.life_bonus == 0, setup.life_bonus)
	setup.life_bonus = 4
	# The toy's save (Game.save) gives life_bonus from the things spawned: 0 at the start, which differs from this
	# session's 4, so the first verified tick's save is a change.
	var saves: Array[UnifiedSetup] = []
	var keep_save := func(save: UnifiedSetup) -> void: saves.append(save)
	s.save_changed.connect(keep_save)
	Unified.profile.color = 9
	check("start_single(setup) with a Setup", s.start_single(setup))
	if not await _wait_for(func() -> bool: return s.local_player != 0, 5.0, "the Setup's session runs"):
		return false
	check("session.setup is the session's", s.setup.life_bonus == 4, s.setup.life_bonus)
	if not await _wait_for(func() -> bool: return saves.size() > 0, 5.0, "save_changed"):
		return false
	check("save_changed gives the save", saves[0].life_bonus == 0, saves[0].life_bonus)
	s.save_changed.disconnect(keep_save)
	var changes: Array[int] = [0]
	var count_change := func() -> void: changes[0] += 1
	s.local_players_changed.connect(count_change)
	# A player list redrawn on roster_changed alone (as the games' HUDs do) lists whoever is present: the roster's
	# entry comes before the tick that seats the player is shown, and roster_changed comes again when it is.
	var listed: Array = [s.get_players()]
	var redraw := func() -> void: listed[0] = s.get_players()
	s.roster_changed.connect(redraw)
	var second: int = s.add_local_player(UnifiedSession.DEVICE_KEYBOARD, "Second")
	check("add_local_player gives local 1", second == 1, second)
	if not await _wait_for(func() -> bool: return s.local_players.size() == 2 and s.get_players().size() == 2, 5.0,
			"the second local player joins"):
		return false
	check("local_players_changed said it joined", changes[0] >= 1, changes[0])
	check("roster_changed came once both were present", listed[0] == s.get_players(), [listed[0], s.get_players()])
	var second_player: int = s.get_local_player_key(1)
	check("get_local_index names local 1", s.get_local_index(second_player) == 1, second_player)
	check("its device is the keyboard", s.get_local_device(1) == UnifiedSession.DEVICE_KEYBOARD)
	check("send_command from local 1", s.send_command(CommandBump.new(), 1))
	check("remove_local_player(1)", s.remove_local_player(1))
	var joined_changes: int = changes[0]
	if not await _wait_for(func() -> bool: return s.local_players.size() == 1 and s.get_players().size() == 1, 5.0,
			"the second local player leaves"):
		return false
	check("local_players_changed said it left", changes[0] > joined_changes, changes[0])
	check("roster_changed came once it was gone", listed[0] == s.get_players(), [listed[0], s.get_players()])
	s.local_players_changed.disconnect(count_change)
	s.roster_changed.disconnect(redraw)
	s.leave()
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "the Setup's session ends"):
		return false
	check("a session started without one plays the default again", s.start_single())
	if not await _wait_for(func() -> bool: return s.local_player != 0, 5.0, "the default session runs"):
		return false
	check("its Setup is the default", s.setup.life_bonus == 0, s.setup.life_bonus)
	s.leave()
	return await _wait_for(func() -> bool: return not s.running, 5.0, "the default session ends")


# 6. open to friends: a running single-player session hosts on a port, closes; a failed open leaves it single player
func _open_to_friends() -> bool:
	var modes: Array[String] = []
	s.mode_changed.connect(func(mode: UnifiedSession.Mode, detail: String) -> void:
		modes.append("%d:%s" % [mode, detail]))
	check("start single player to open", s.start_single())
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 5, 5.0, "single player runs to open"):
		return false
	var ticked: int = s.tick
	check("open_direct on a port the OS picks", s.open_direct(0))
	if not await _wait_for(func() -> bool: return s.mode == UnifiedSession.MODE_HOST_DIRECT and s.join_code != "", 5.0, "the session hosts on the port"):
		return false
	# (opening can take less than a tick: wait for the next one rather than look at once)
	await _wait_for(func() -> bool: return s.tick > ticked, 2.0, "a tick after opening")
	check("the session went on, its ticks kept", s.tick > ticked, [ticked, s.tick])
	check("mode_changed said so", modes.has("%d:" % UnifiedSession.MODE_HOST_DIRECT), modes)
	check("close_online", s.close_online())
	check("closing clears the join code", s.join_code == "", s.join_code)
	s.leave()
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "the opened session ends"):
		return false
	check("start single player again", s.start_single())
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 10, 5.0, "single player runs again"):
		return false
	modes.clear()
	check("open_online without a lobby service is asked", s.open_online())
	if not await _wait_for(func() -> bool: return modes.size() > 0, 5.0, "the failed open is told"):
		return false
	check("a failed open leaves it single player, running", s.mode == UnifiedSession.MODE_SINGLE and s.status == UnifiedSession.STATUS_CONNECTED and modes[0].begins_with("%d:" % UnifiedSession.MODE_SINGLE), modes)
	s.leave()
	return await _wait_for(func() -> bool: return not s.running, 5.0, "the session ends")


# 7. a replay of a recording and its controls
func _replay() -> bool:
	s.ticks = REPLAY_TICKS
	check("record a %d-tick single player" % REPLAY_TICKS, s.start_single())
	if not await _wait_for(func() -> bool: return s.local_player != 0, 5.0, "the recorded session runs"):
		return false
	var recorder: int = s.local_player
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "the recorded session ends"):
		return false
	s.ticks = 0
	await _sleep(0.2)  # a recording another process saves at once is whole by now
	var folder := _newest_recording(REPLAY_TICKS)
	check("its recording was kept", folder != "", folder)
	check("replay it", s.replay(folder))
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.replay_last_tick > 0, 5.0, "the replay runs"):
		return false
	check("its ticks", s.replay_first_tick < s.replay_last_tick and s.replay_last_tick >= REPLAY_TICKS, [s.replay_first_tick, s.replay_last_tick])
	check("it follows whoever recorded it", s.replay_player == recorder and s.local_player == recorder, [s.replay_player, recorder])
	s.replay_speed = 2.0
	if not await _wait_for(func() -> bool: return s.replay_speed == 2.0, 2.0, "the speed is taken"):
		return false
	s.replay_speed = 100.0
	if not await _wait_for(func() -> bool: return s.replay_speed == 4.0, 2.0, "the speed is clamped"):
		return false
	s.replay_seek(10)
	s.replay_step(5)
	if not await _wait_for(func() -> bool: return s.tick == 15 and s.paused, 2.0, "seek 10, step 5: paused on 15"):
		return false
	s.replay_step(-3)
	if not await _wait_for(func() -> bool: return s.tick == 12, 2.0, "a step back"):
		return false
	s.replay_loop(20, 24)
	s.paused = false
	if not await _wait_for(func() -> bool: return s.tick >= 20 and s.tick <= 24, 3.0, "the loop plays its range"):
		return false
	await _sleep(0.3)  # at 4x, more than one round of the 5-tick loop
	check("it stays in the loop", s.tick >= 20 and s.tick <= 24, s.tick)
	s.replay_loop(0, 0)
	if not await _wait_for(func() -> bool: return s.tick == s.replay_last_tick, 3.0, "the loop stopped: it plays to the end"):
		return false
	check("every checkpoint agreed", s.replay_diverged_tick == 0 and s.replay_agreed_tick > 0, [s.replay_agreed_tick, s.replay_diverged_tick])
	s.replay_player = 0
	if not await _wait_for(func() -> bool: return s.replay_player == 0, 2.0, "the followed player is set"):
		return false
	s.leave()
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "the replay ends"):
		return false
	# A replay started on a running live session: the live one is left and still keeps its recording.
	check("a live single player", s.start_single())
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 60, 5.0, "the live session runs"):
		return false
	s.paused = true
	if not await _wait_for(func() -> bool: return s.paused, 2.0, "the live session pauses"):
		return false
	await _sleep(0.3)  # every tick verified: its recording ends on the shown tick
	var paused_on: int = s.tick
	var before := Array(DirAccess.get_directories_at(OS.get_user_data_dir() + "/recordings"))
	check("replay on the running live session", s.replay(folder))
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.replay_last_tick > 0, 5.0, "the replay runs after the live session"):
		return false
	await _sleep(0.2)
	var kept := ""
	var root := OS.get_user_data_dir() + "/recordings"
	for name: String in DirAccess.get_directories_at(root):
		var info: Variant = JSON.parse_string(FileAccess.get_file_as_string(root + "/" + name + "/session.json"))
		if not before.has(name) and info is Dictionary and absi(int((info as Dictionary).get("to_tick", 0)) - paused_on) <= 2:
			kept = name
	check("the left live session kept its recording", kept != "", "paused on %d" % paused_on)
	s.leave()
	return await _wait_for(func() -> bool: return not s.running, 5.0, "the replay ends")


# The newest whole recording folder under user://recordings that ends on `to_tick` ("" for none): its session.json is
# written last, and the other sections' processes (the same user folder) record sessions of their own beside it.
func _newest_recording(to_tick: int) -> String:
	var root := OS.get_user_data_dir() + "/recordings"
	var sorted := Array(DirAccess.get_directories_at(root))
	sorted.sort()  # the local time sorts by name
	sorted.reverse()
	for name: String in sorted:
		var session := root + "/" + name + "/session.json"
		if not FileAccess.file_exists(session):
			continue
		var info: Variant = JSON.parse_string(FileAccess.get_file_as_string(session))
		if info is Dictionary and int((info as Dictionary).get("to_tick", 0)) == to_tick:
			return root + "/" + name
	return ""


# 8. starting on a running session, without a leave: the start leaves it first; the newest start wins
func _restart() -> bool:
	check("start single player", s.start_single())
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 10, 5.0, "single player runs"):
		return false
	_statuses.clear()
	var setup := UnifiedSetup.new()
	setup.life_bonus = 3
	check("start_single on the running session is accepted", s.start_single(setup))
	check("it is connecting while the old one says goodbye", s.status == UnifiedSession.STATUS_CONNECTING, s.status)
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.local_player != 0 and s.setup.life_bonus == 3, 5.0, "the new session runs with its Setup"):
		return false
	check("no failed/disconnected/left status reaches the game",
		not _statuses.any(func(x: String) -> bool:
			return x.begins_with("failed") or x.begins_with("disconnected") or x.begins_with("left")), _statuses)
	check("host on a port while single player runs", s.host_direct(0))
	check("then single player at once, while the host waits", s.start_single())
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.local_player != 0 and s.setup.life_bonus == 0, 5.0, "the newest start runs"):
		return false
	await _sleep(0.3)
	check("the replaced start never ran", s.mode == UnifiedSession.MODE_SINGLE and s.join_code == "", "%d %s" % [s.mode, s.join_code])
	# A start that comes after the left session ended but before the waiting start launched (the same frame): the
	# waiting one is replaced, and the new session's messages reach the game.
	check("host while single player runs (it waits)", s.host_direct(0))
	var end := Time.get_ticks_msec() + 3000
	while s.running and Time.get_ticks_msec() < end:
		OS.delay_msec(5)  # this frame: the left session's thread ends, the waiting start has not launched
	check("the left session ended within the frame", not s.running)
	_statuses.clear()
	check("single player then, in that frame", s.start_single())
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.local_player != 0, 5.0, "the newest start runs, its messages shown"):
		return false
	await _sleep(0.3)
	check("the waiting host start never ran", s.mode == UnifiedSession.MODE_SINGLE and s.join_code == "", "%d %s" % [s.mode, s.join_code])
	s.leave()
	return await _wait_for(func() -> bool: return not s.running, 5.0, "the restarted session ends")


# 9. event objects: none while nobody listens (no scene views here, no sim_event connection); a listener that keeps
# none gets one object per class, refilled; a listener that keeps them gets a new one each time, never refilled
func _event_objects() -> bool:
	check("start single player", s.start_single())
	if not await _wait_for(func() -> bool: return s.local_player != 0 and s.tick > 5, 5.0, "single player runs"):
		return false
	s.take_sync_stats()
	if not await _ticks_pass(48):
		return false
	var quiet: Dictionary = s.take_sync_stats()
	check("no listener: its events are routed, no object made",
		int(quiet.events) >= 4 and int(quiet.event_objects) == 0, quiet)

	var objects := {}  # instance id: true
	var classes := {}  # class name: true
	var ids := {}  # event id: true
	var hear := func(event: UnifiedEvent, _state: UnifiedSession.EventState) -> void:
		objects[event.get_instance_id()] = true
		classes[event.get_class()] = true
		ids[event.id] = true
	s.sim_event.connect(hear)
	if not await _ticks_pass(48):
		return false
	s.sim_event.disconnect(hear)
	var heard: Dictionary = s.take_sync_stats()
	check("a listener that keeps none: one object per class, refilled with each event",
		int(heard.events) >= 4 and objects.size() == classes.size() and int(heard.event_objects) == classes.size()
		and ids.size() >= 2, [heard, objects.size(), classes.keys(), ids.size()])

	var kept: Array[Array] = []  # [event, its id, its tick, its class] as delivered
	var keep := func(event: UnifiedEvent, _state: UnifiedSession.EventState) -> void:
		kept.append([event, event.id, event.tick, event.get_class()])
	s.sim_event.connect(keep)
	if not await _ticks_pass(48):
		return false
	s.sim_event.disconnect(keep)
	var unique := {}
	for k: Array in kept:
		unique[(k[0] as Object).get_instance_id()] = true
	check("a listener that keeps them: a new object for each", kept.size() >= 4 and unique.size() == kept.size(),
		[kept.size(), unique.size()])
	check("a kept event is never refilled", kept.all(func(k: Array) -> bool:
		var event: UnifiedEvent = k[0]
		return event.id == k[1] and event.tick == k[2] and event.get_class() == k[3]))
	s.leave()
	return await _wait_for(func() -> bool: return not s.running, 5.0, "the session ends")


# Waits until `count` more ticks are shown.
func _ticks_pass(count: int) -> bool:
	var until: int = s.tick + count
	return await _wait_for(func() -> bool: return s.tick >= until, 10.0, "%d ticks pass" % count)


func _sleep(sec: float) -> void:
	await create_timer(sec).timeout


# Waits for `cond` (true) or the timeout (a failed check, false).
func _wait_for(cond: Callable, timeout_s: float, what: String) -> bool:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call():
		if Time.get_ticks_msec() > end:
			check(what, false, "timed out (%.0f s)" % timeout_s)
			return false
		await process_frame
	return true


func _finish() -> void:
	print("SESSION TESTS: %d failed" % failed)
	_play_a_sound()
	s.quit(failed)


## A looping sound, playing as the run quits.
func _play_a_sound() -> void:
	var wav := AudioStreamWAV.new()
	wav.mix_rate = 8000
	var silence := PackedByteArray()
	silence.resize(1600)
	wav.data = silence
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = 800
	var player := AudioStreamPlayer.new()
	player.stream = wav
	root.add_child(player)
	player.play()


func _status_name(status: UnifiedSession.Status) -> String:
	match status:
		UnifiedSession.STATUS_CONNECTING:
			return "connecting"
		UnifiedSession.STATUS_CONNECTED:
			return "connected"
		UnifiedSession.STATUS_FAILED:
			return "failed"
		UnifiedSession.STATUS_DISCONNECTED:
			return "disconnected"
		UnifiedSession.STATUS_LEFT:
			return "left"
	return "idle"
