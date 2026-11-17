# unified:godot session lifecycle tests: run headless by `uni test --suite godot-bindings`, on the toy's session (the
# extension in ext/). Leave, then host or join at once, while the left session is still saying goodbye:
# 1. join a silent UDP peer (the client lingers up to 2 s for its Leave's ack), leave, start single player at once:
#    the start is accepted, waits for the goodbye (cut to 1 s) and connects.
# 2. host on a LAN port, leave, host on the same port at once: the old socket is closed before the new one opens.
# 3. leave, host at once, leave again before the old session is gone: the waiting start is dropped ("disconnected").
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
	s.status_changed.connect(func(st: String, detail: String) -> void: _statuses.append(st + (":" + detail if detail != "" else "")))


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
	check("status is connecting while the goodbye runs", s.get_status() == "connecting", s.get_status())
	if not await _wait_for(func() -> bool: return s.get_status() == "connected" and s.get_tick() > 10, 5.0, "single player runs"):
		return _finish()
	var waited := Time.get_ticks_msec() - t
	check("the goodbye was cut short", waited < 2000, "%d ms" % waited)
	check("no failed/disconnected status reaches the game",
		not _statuses.has("failed") and not _statuses.any(func(x: String) -> bool: return x.begins_with("disconnected")), _statuses)
	silent.close()

	# 2. host, leave, host on the same port at once
	s.leave()
	if not await _wait_for(func() -> bool: return not s.is_running(), 5.0, "single player ends"):
		return _finish()
	check("host on port %d" % PORT, s.host_direct(PORT))
	if not await _wait_for(func() -> bool: return s.get_status() == "connected" and s.get_tick() > 5, 5.0, "hosting"):
		return _finish()
	_statuses.clear()
	s.leave()
	check("host again on the same port right after leave", s.host_direct(PORT))
	if not await _wait_for(func() -> bool: return s.get_status() == "connected" and s.get_tick() > 5, 5.0, "hosting again"):
		return _finish()
	check("the port was free", not _statuses.has("failed:cannot listen on UDP port %d" % PORT), _statuses)

	# 3. leave, host at once, leave again: the waiting start is dropped
	_statuses.clear()
	s.leave()
	check("host right after leave (to be cancelled)", s.host_direct(PORT))
	s.leave()
	check("a cancelled start reports disconnected", s.get_status() == "disconnected", s.get_status())
	if not await _wait_for(func() -> bool: return not s.is_running(), 5.0, "no session runs after the cancel"):
		return _finish()
	await _sleep(0.3)
	check("the cancelled start never ran", not s.is_running())

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
