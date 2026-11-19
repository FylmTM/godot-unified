# unified:godot session lifecycle tests: run headless by `uni test --suite godot-bindings`, on the toy's session (the
# extension in ext/). Leave, then host or join at once, while the left session is still saying goodbye:
# 1. join a silent UDP peer (the client lingers up to 2 s for its Leave's ack), leave, start single player at once:
#    the start is accepted, waits for the goodbye (cut to 1 s) and connects.
# 2. host on a LAN port, leave, host on the same port at once: the old socket is closed before the new one opens.
# 3. leave, host at once, leave again before the old session is gone: the waiting start is dropped ("left").
# 4. a session that ends on its own (its ticks ran out) stops answering from its last frame: no local player.
# 5. a session's Setup (start_single(setup), session.setup, the default again) and a second local player.
# 6. open to friends: a running single-player session hosts on a port and closes; a failed open leaves it running.
# (The LAN token's claim, each copy of a game a slot and a token of its own, is tested in tests/godot_driver.)
#   godot --path tests/godot_views --headless -s res://session_check.gd -- [--idle-end S]
# --idle-end S: stay S seconds with no session before quitting (to see the power activity released).
# Prints one line per check and "SESSION TESTS: <n> failed"; exits with the failure count.
extends SceneTree

const PORT := 47788

var s: Node
var failed := 0
var idle_end := 0.0
var _statuses: Array[String] = []
var _started := false


func check(name: String, ok: bool, detail = "") -> void:
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, str(detail)])
	if not ok:
		failed += 1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--idle-end")
	if i >= 0 and i + 1 < args.size():
		idle_end = float(args[i + 1])
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

	# 1. a client lingering for its Leave's ack, then single player at once
	var silent := PacketPeerUDP.new()
	if silent.bind(0, "127.0.0.1") != OK:
		check("bind the silent peer", false)
		return _finish()
	check("join the silent peer", s.join_direct("127.0.0.1:%d" % silent.get_local_port()))
	await _sleep(0.4)
	_statuses.clear()
	s.leave()
	var t := Time.get_ticks_msec()
	check("start_single right after leave is accepted", s.start_single())
	check("status is connecting while the goodbye runs", s.status == UnifiedSession.STATUS_CONNECTING, s.status)
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 10, 5.0, "single player runs"):
		return _finish()
	var waited := Time.get_ticks_msec() - t
	check("the goodbye was cut short", waited < 2000, "%d ms" % waited)
	check("no failed/disconnected/left status reaches the game",
		not _statuses.has("failed") and not _statuses.any(func(x: String) -> bool:
			return x.begins_with("disconnected") or x.begins_with("left")), _statuses)
	silent.close()

	# 2. host, leave, host on the same port at once
	s.leave()
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "single player ends"):
		return _finish()
	check("host on port %d" % PORT, s.host_direct(PORT))
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 5, 5.0, "hosting"):
		return _finish()
	_statuses.clear()
	s.leave()
	check("host again on the same port right after leave", s.host_direct(PORT))
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 5, 5.0, "hosting again"):
		return _finish()
	check("the port was free", not _statuses.has("failed:cannot listen on UDP port %d" % PORT), _statuses)

	# 3. leave, host at once, leave again: the waiting start is dropped
	_statuses.clear()
	s.leave()
	check("host right after leave (to be cancelled)", s.host_direct(PORT))
	s.leave()
	check("a cancelled start reports left", s.status == UnifiedSession.STATUS_LEFT, s.status)
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "no session runs after the cancel"):
		return _finish()
	await _sleep(0.3)
	check("the cancelled start never ran", not s.running)

	# 4. a session that ends on its own: its last frame stays on screen, nothing answers from it
	s.ticks = 40
	check("start a 40-tick single player", s.start_single())
	if not await _wait_for(func() -> bool: return s.local_player != 0, 5.0, "the short session runs"):
		return _finish()
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "the short session ends"):
		return _finish()
	await _sleep(0.2)
	check("an ended session has no local player", s.local_player == 0, s.local_player)
	s.ticks = 0

	# 5. the session's Setup, the player's Profile, a second local player
	var setup := UnifiedSetup.new()
	check("a new UnifiedSetup is the game's default", setup.life_bonus == 0, setup.life_bonus)
	setup.life_bonus = 4
	Unified.profile.color = 9
	check("start_single(setup) with a Setup", s.start_single(setup))
	if not await _wait_for(func() -> bool: return s.local_player != 0, 5.0, "the Setup's session runs"):
		return _finish()
	check("session.setup is the session's", s.setup.life_bonus == 4, s.setup.life_bonus)
	var second: int = s.add_local_player(UnifiedSession.DEVICE_KEYBOARD, "Second")
	check("add_local_player gives local 1", second == 1, second)
	if not await _wait_for(func() -> bool: return s.local_players.size() == 2, 5.0, "the second local player joins"):
		return _finish()
	var second_player: int = s.get_local_player_key(1)
	check("get_local_index names local 1", s.get_local_index(second_player) == 1, second_player)
	check("its device is the keyboard", s.get_local_device(1) == UnifiedSession.DEVICE_KEYBOARD)
	check("send_command from local 1", s.send_command(CommandBump.new(), 1))
	check("remove_local_player(1)", s.remove_local_player(1))
	if not await _wait_for(func() -> bool: return s.local_players.size() == 1, 5.0, "the second local player leaves"):
		return _finish()
	s.leave()
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "the Setup's session ends"):
		return _finish()
	check("a session started without one plays the default again", s.start_single())
	if not await _wait_for(func() -> bool: return s.local_player != 0, 5.0, "the default session runs"):
		return _finish()
	check("its Setup is the default", s.setup.life_bonus == 0, s.setup.life_bonus)
	s.leave()
	await _wait_for(func() -> bool: return not s.running, 5.0, "the default session ends")

	# 6. open to friends: a running single-player session hosts on a port, closes, and a taken port leaves it single
	var modes: Array[String] = []
	s.mode_changed.connect(func(mode: UnifiedSession.Mode, detail: String) -> void:
		modes.append("%d:%s" % [mode, detail]))
	check("start single player to open", s.start_single())
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 30, 5.0, "single player runs to open"):
		return _finish()
	var ticked: int = s.tick
	check("open_direct", s.open_direct(PORT + 1))
	if not await _wait_for(func() -> bool: return s.mode == UnifiedSession.MODE_HOST_DIRECT and s.join_code != "", 5.0, "the session hosts on the port"):
		return _finish()
	# (opening can take less than a tick: wait for the next one rather than look at once)
	await _wait_for(func() -> bool: return s.tick > ticked, 2.0, "a tick after opening")
	check("the session went on, its ticks kept", s.tick > ticked, [ticked, s.tick])
	check("mode_changed said so", modes.has("%d:" % UnifiedSession.MODE_HOST_DIRECT), modes)
	check("close_online", s.close_online())
	check("closing clears the join code", s.join_code == "", s.join_code)
	s.leave()
	if not await _wait_for(func() -> bool: return not s.running, 5.0, "the opened session ends"):
		return _finish()
	check("start single player again", s.start_single())
	if not await _wait_for(func() -> bool: return s.status == UnifiedSession.STATUS_CONNECTED and s.tick > 10, 5.0, "single player runs again"):
		return _finish()
	modes.clear()
	check("open_online without a lobby service is asked", s.open_online())
	if not await _wait_for(func() -> bool: return modes.size() > 0, 5.0, "the failed open is told"):
		return _finish()
	check("a failed open leaves it single player, running", s.mode == UnifiedSession.MODE_SINGLE and s.status == UnifiedSession.STATUS_CONNECTED and modes[0].begins_with("%d:" % UnifiedSession.MODE_SINGLE), modes)
	s.leave()
	await _wait_for(func() -> bool: return not s.running, 5.0, "the session ends")

	if idle_end > 0.0:
		print("session_check: idle with no session for %.1f s" % idle_end)
		await _sleep(idle_end)
	_finish()


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
	s.leave()
	print("SESSION TESTS: %d failed" % failed)
	quit(failed)


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
