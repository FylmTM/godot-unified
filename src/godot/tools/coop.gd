class_name UnifiedCoop
extends UnifiedTool
## Real co-op, one process per role (`uni coop <game>` starts both). No menus: each side's session starts from the
## session flags on its command line (src/godot/SPEC.md), which uni passes:
##   host:   -- --role=host --code-file=<f> --host-online           (--lan: --host-port N)
##   joiner: -- --role=join --code-file=<f> --join-code <code>      (--lan: --join 127.0.0.1:N)
## The host writes its lobby code (or address) to the code file once it has one, and uni starts the joiner with it.
## Both wait for two players; then the game's own play (`_host_play()`, `_join_play()`, in a game's
## game/tools/coop.gd that extends this), and the host leaves: the joiner's session must end (`_host_left()`: what
## the game shows its player then). A desync on either side fails the run.
## --rejoin (both roles): once the host has played (it writes <code file>.played), the joiner leaves and joins again
## (a late join) before the host leaves.
## --crash (both roles): once the host has played, the joiner kills its own process (no goodbye, like a crash) and
## uni starts another with --after-crash and the same identity (its EOS account, or its LAN token): the host times
## how long it takes to have the friend back, the second joiner how long from starting to playing again.
## A game's play and its app layer follow the session, whoever started it: a game whose session lives in an
## autoload goes to its play scene on its own, one that keeps it in its main scene gets that scene loaded here.

var role := ""
var code_file := ""
var rejoin := false
var crash := false
var after_crash := false
## Why the session's status last changed (status_changed's detail).
var status_detail := ""


func _run() -> void:
	role = arg("role")
	code_file = arg("code-file")
	rejoin = flag("rejoin")
	crash = flag("crash")
	after_crash = flag("after-crash")
	tag = "[%s]" % role
	result["role"] = role
	if role not in ["host", "join"] or code_file == "":
		fail("pass --role=host|join and --code-file=<file>")
		return
	await load_session()
	if failed():
		return
	session.status_changed.connect(func(_status: UnifiedSession.Status, detail: String) -> void: status_detail = detail)
	session.desync.connect(func(tick: int, detail: String) -> void: fail("desync at tick %d: %s" % [tick, detail]))
	if role == "host":
		await _host()
	else:
		await _join()


## The host's play once both players are in (default: a few seconds together).
func _host_play() -> void:
	await seconds(3.0)
	step("played together: %s" % player_names())


## The joiner's play once both players are in (default: none; the host leads).
func _join_play() -> void:
	pass


## Whether the game's play is under way, as a returning player sees it (default: always).
func _playing() -> bool:
	return true


## The joiner, once the host left and its session ended: what the game shows its player (default: nothing more).
func _host_left() -> void:
	pass


func _host() -> void:
	DirAccess.remove_absolute(_played_file())
	var code := ""
	if arg("host-port") != "":
		code = "127.0.0.1:%s" % arg("host-port")
	else:
		var codes: Array[String] = []
		session.lobby_code.connect(func(c: String) -> void: codes.append(c))
		await wait_for(func() -> bool: return not codes.is_empty() and codes.back() != "", 30.0, "a lobby code")
		code = codes.back() if not codes.is_empty() else ""
	await wait_for(_connected, 20.0, "the host's session")
	if failed():
		return
	var f := FileAccess.open(code_file, FileAccess.WRITE)
	f.store_string(code)
	f.close()
	await shot("c01_host_code")
	step("hosting, %s %s" % ["address" if arg("host-port") != "" else "code", code])
	await wait_for(func() -> bool: return _present() >= 2, 60.0, "the friend joins")
	await seconds(1.5)
	await shot("c02_two_players")
	step("friend joined: %s" % player_names())
	await _host_play()
	if crash or rejoin:
		FileAccess.open(_played_file(), FileAccess.WRITE).close()
	if crash:
		# The crashed player drops out once the host gives up on its connection, or at once when the friend's
		# restarted game connects again (the relay knows them by their Product User ID, or their LAN token, and
		# the newest connection wins); they come back as the same player, in whatever slot is free.
		var friend := _friend_player()
		var t := Time.get_ticks_msec()
		await wait_for(func() -> bool: return friend not in session.get_players(), 60.0,
			"the crashed friend drops out")
		step("friend (player %d) dropped out after %.1f s: %s" % [friend, (Time.get_ticks_msec() - t) / 1000.0,
			player_names()])
		t = Time.get_ticks_msec()
		await wait_for(func() -> bool: return _present() >= 2, 120.0, "the friend is back")
		step("friend back %.1f s after dropping out: %s" % [(Time.get_ticks_msec() - t) / 1000.0, player_names()])
		await seconds(4.0)
	elif rejoin:
		await wait_for(func() -> bool: return _present() == 1, 30.0, "the friend leaves")
		step("friend left: %s" % player_names())
		await wait_for(func() -> bool: return _present() >= 2, 60.0, "the friend rejoins")
		step("friend rejoined: %s" % player_names())
		await seconds(4.0)
	session.leave()
	await wait_for(func() -> bool: return not _connected(), 10.0, "the host's session ends")
	step("host left")
	await seconds(3.0)  # let the joiner notice


func _join() -> void:
	if after_crash:
		# The same player, back after its game crashed: the play is under way already.
		var t := Time.get_ticks_msec()
		await wait_for(func() -> bool: return _connected() and _present() >= 2 and _playing(), 120.0,
			"back in the game after the crash")
		step("back %.1f s after starting, player %d: %s" % [(Time.get_ticks_msec() - t) / 1000.0,
			session.local_player, player_names()])
		await _wait_host_left()
		return
	await wait_for(func() -> bool: return _connected() and _present() >= 2, 30.0, "both players in")
	step("joined as player %d: %s" % [session.local_player, player_names()])
	await _join_play()
	if crash or rejoin:
		await wait_for(func() -> bool: return FileAccess.file_exists(_played_file()), 60.0, "the host's play")
	if crash:
		await seconds(2.0)
		step("crashing (the process kills itself: no leave, no goodbye)")
		print("UNIFIED_RESULT " + JSON.stringify({"ok": true, "role": role, "steps": _steps, "crashed": true}))
		OS.kill(OS.get_process_id())
		return
	if rejoin:
		await seconds(2.0)
		session.leave()
		await wait_for(func() -> bool: return not _connected(), 10.0, "the joiner's session ends")
		step("left")
		await seconds(1.0)
		if arg("join-code") != "":
			session.join_online(arg("join-code"))
		else:
			session.join_direct(arg("join"))
		await wait_for(func() -> bool: return _connected() and _present() >= 2 and _playing(), 30.0,
			"back in the game")
		step("rejoined as player %d: %s" % [session.local_player, player_names()])
	await _wait_host_left()


func _wait_host_left() -> void:
	await wait_for(func() -> bool: return session.status in [UnifiedSession.STATUS_DISCONNECTED,
		UnifiedSession.STATUS_FAILED], 60.0, "the host leaves: the session ends")
	if failed():
		return
	step("host left: the session ended (%s)" % status_detail)
	await _host_left()


func _connected() -> bool:
	return session.status == UnifiedSession.STATUS_CONNECTED


func _present() -> int:
	return session.get_players().size()


## The first present player other than the local one (0: none).
func _friend_player() -> int:
	for player: int in session.get_players():
		if player != session.local_player:
			return player
	return 0


## Written by the host once its play is done: the joiner's cue to leave (--rejoin) or crash (--crash).
func _played_file() -> String:
	return code_file + ".played"
