extends SceneTree
## Session lifecycle check with the native extension (headless, no game UI): Leave, then Host or Join at once, while
## the left session is still saying goodbye.
##   godot --path games/friendslop --headless -s res://game/tools/session_check.gd -- [--idle-end S]
## 1. join a silent UDP peer (the client lingers up to 2 s for its Leave's ack), leave, start single player at once:
##    the start is accepted, waits for the goodbye (cut to 1 s) and connects.
## 2. host on a LAN port, leave, host on the same port at once: the old socket is closed before the new one opens.
## 3. leave, host at once, leave again before the old session is gone: the waiting start is dropped ("disconnected").
## --idle-end S: stay S seconds with no session before quitting (to see the power activity released).
## Prints `UNIFIED_RESULT {...}`; exits 1 on a failed expectation or any engine/script error.

var cap: Logger
var s: Node
var _statuses: Array[String] = []
var _failed := ""
var _steps: Array[Dictionary] = []
var _t0 := 0
var _started := false
var idle_end := 0.0
const PORT := 47788


func _init() -> void:
	cap = load("res://game/tools/log_capture.gd").new()
	OS.add_logger(cap)
	var args := OS.get_cmdline_user_args()
	var i := args.find("--idle-end")
	if i >= 0 and i + 1 < args.size():
		idle_end = float(args[i + 1])


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_t0 = Time.get_ticks_msec()
		_run()
	return false


func _run() -> void:
	if not ClassDB.class_exists(&"UnifiedSession"):
		_fail("the extension is not loaded")
		return _finish()
	# the Game autoload's session (only one UnifiedSession runs per process)
	var game := root.get_node_or_null("Game")
	s = game.session if game != null else null
	if s == null or s.get_class() != "UnifiedSession":
		_fail("the Game autoload has no UnifiedSession")
		return _finish()
	s.status_changed.connect(func(st: String, detail: String) -> void: _statuses.append(st + (":" + detail if detail != "" else "")))
	await process_frame

	# 1. a client lingering for its Leave's ack, then single player at once
	var silent := PacketPeerUDP.new()
	if silent.bind(0, "127.0.0.1") != OK:
		_fail("cannot bind the silent peer")
		return _finish()
	_check(s.join_direct("127.0.0.1:%d" % silent.get_local_port()), "join the silent peer")
	await _sleep(0.4)
	_statuses.clear()
	s.leave()
	var t := Time.get_ticks_msec()
	_check(s.start_single(), "start_single right after leave is accepted")
	_check(s.get_status() == "connecting", "status is connecting while the goodbye runs (got %s)" % s.get_status())
	await _wait_for(func() -> bool: return s.get_status() == "connected" and s.get_tick() > 10, 5.0, "single player runs")
	var waited := Time.get_ticks_msec() - t
	_step("leave join, start single", {"ms_to_running": waited, "statuses": _statuses.duplicate()})
	_check(waited < 2000, "the goodbye was cut short (%d ms)" % waited)
	_check(not _statuses.has("failed") and not _statuses.any(func(x: String) -> bool: return x.begins_with("disconnected")),
		"no failed/disconnected status reaches the game: %s" % [_statuses])
	silent.close()

	# 2. host, leave, host on the same port at once
	s.leave()
	await _wait_for(func() -> bool: return not s.is_running(), 5.0, "single player ends")
	_check(s.host_direct(PORT), "host on port %d" % PORT)
	await _wait_for(func() -> bool: return s.get_status() == "connected" and s.get_tick() > 5, 5.0, "hosting")
	_statuses.clear()
	s.leave()
	t = Time.get_ticks_msec()
	_check(s.host_direct(PORT), "host again on the same port right after leave")
	await _wait_for(func() -> bool: return s.get_status() == "connected" and s.get_tick() > 5, 5.0, "hosting again")
	_step("leave host, host again", {"ms_to_running": Time.get_ticks_msec() - t, "statuses": _statuses.duplicate()})
	_check(not _statuses.has("failed:cannot listen on UDP port %d" % PORT), "the port was free: %s" % [_statuses])

	# 3. leave, host at once, leave again: the waiting start is dropped
	_statuses.clear()
	s.leave()
	_check(s.host_direct(PORT), "host right after leave (to be cancelled)")
	s.leave()
	_check(s.get_status() == "disconnected", "cancelled start reports disconnected (got %s)" % s.get_status())
	await _wait_for(func() -> bool: return not s.is_running(), 5.0, "no session runs after the cancel")
	await _sleep(0.3)
	_check(not s.is_running(), "the cancelled start never ran")
	_step("leave, host, leave", {"statuses": _statuses.duplicate()})

	if idle_end > 0.0:
		print("session_check: idle with no session for %.1f s" % idle_end)
		await _sleep(idle_end)
	_finish()


func _sleep(sec: float) -> void:
	await create_timer(sec).timeout


func _wait_for(cond: Callable, timeout_s: float, what: String) -> void:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while _failed == "":
		if cond.call():
			return
		if Time.get_ticks_msec() > end:
			_fail("timed out (%.0f s): %s" % [timeout_s, what])
			return
		await process_frame


func _check(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fail(what)


func _step(name: String, data: Dictionary) -> void:
	data["step"] = name
	data["t_ms"] = Time.get_ticks_msec() - _t0
	_steps.append(data)
	print("session_check: %s %s" % [name, JSON.stringify(data)])


func _fail(why: String) -> void:
	if _failed == "":
		_failed = why


func _finish() -> void:
	var ok: bool = _failed == "" and cap.errors.is_empty()
	if not cap.errors.is_empty():
		print(cap.report())
	print("UNIFIED_RESULT " + JSON.stringify({"ok": ok, "failed": _failed, "errors": cap.errors, "steps": _steps}))
	OS.remove_logger(cap)
	root.get_node(^"Game").quit_app(0 if ok else 1)  # audio first: a live playback leaks
