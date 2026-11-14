class_name UnifiedCoop
extends UnifiedTool
## Real co-op through the menus, one process per role (`uni coop <game>` starts both):
##   godot --path games/<game> -s <coop script> -- --role=host --code-file=<f> [--lan] [--shots=<dir>]
##   godot --headless --path games/<game> -s <coop script> -- --role=join --code-file=<f> [--lan]
## The host clicks Host online (`--lan`: Host on LAN, direct UDP, no EOS) and writes the lobby code (or address) to
## the file; the joiner enters it in the Join panel (or Join by address). Both wait for two players; then the game's
## own play (`_host_play()` and `_join_play()`, in a game's game/tools/coop.gd that extends this), and the host
## leaves: the joiner must land on its menu.
## --rejoin (both roles): once the host has played (it writes <code file>.played), the joiner leaves and joins again
## with the same code (a late join) before the host leaves.
## --crash (both roles): once the host has played, the joiner kills its own process (no goodbye, like a crash) and
## `uni coop --crash` starts another with --after-crash and the same EOS identity: the host times how long it takes
## to have the friend back, the second joiner how long from entering the code to playing again.

## The lobby code's length (the shared MainMenu.CODE_LENGTH).
const CODE_LENGTH := 6

var role := ""
var code_file := ""
var lan := false
var rejoin := false
var crash := false
var after_crash := false


func _run() -> void:
	role = arg("role")
	code_file = arg("code-file")
	lan = flag("lan")
	rejoin = flag("rejoin")
	crash = flag("crash")
	after_crash = flag("after-crash")
	tag = "[%s]" % role
	result["role"] = role
	if role not in ["host", "join"] or code_file == "":
		fail("pass --role=host|join and --code-file=<file>")
		return
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await wait_for_scene("MainMenu", 5.0)
	await seconds(0.3)
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


func _host() -> void:
	var code := ""
	DirAccess.remove_absolute(_played_file())
	if lan:
		await click_menu("JoinAddress")
		await click_menu("HostLan")
		code = "127.0.0.1:%d" % game.lan_port
	else:
		await click_menu("Host")
		await wait_for(func() -> bool: return game.lobby_code.length() == CODE_LENGTH, 30.0, "a lobby code")
		code = game.lobby_code
	if failed():
		return
	var f := FileAccess.open(code_file, FileAccess.WRITE)
	f.store_string(code)
	f.close()
	await shot("c01_host_code")
	step("hosting, %s %s" % ["address" if lan else "code", code])
	await wait_for_scene("Arena", 20.0)
	await wait_for(func() -> bool: return game.present_players().size() >= 2, 60.0, "the friend joins")
	await seconds(1.5)
	await shot("c02_two_players")
	step("friend joined: %s" % player_names())
	await _host_play()
	if crash or rejoin:
		FileAccess.open(_played_file(), FileAccess.WRITE).close()
	if crash:
		# The crashed player's seat drops out once the host gives up on it. Through EOS the friend comes back
		# as the same peer (their Product User ID), which ends the old connection first; over direct UDP the
		# new process is a new endpoint, so the friend is back in another seat before the old one times out.
		var friend := _friend_player()
		var t := Time.get_ticks_msec()
		await wait_for(func() -> bool: return not _is_present(friend), 60.0, "the crashed friend drops out")
		step("friend (player %d) dropped out after %.1f s: %s" % [friend, (Time.get_ticks_msec() - t) / 1000.0,
			player_names()])
		t = Time.get_ticks_msec()
		await wait_for(func() -> bool: return game.present_players().size() >= 2, 120.0, "the friend is back")
		step("friend back %.1f s after dropping out: %s" % [(Time.get_ticks_msec() - t) / 1000.0, player_names()])
		await seconds(4.0)
	elif rejoin:
		await wait_for(func() -> bool: return game.present_players().size() == 1, 30.0, "the friend leaves")
		step("friend left: %s" % player_names())
		await wait_for(func() -> bool: return game.present_players().size() >= 2, 60.0, "the friend rejoins")
		step("friend rejoined: %s" % player_names())
		await seconds(4.0)
	game.leave_to_menu()
	await wait_for_scene("MainMenu", 5.0)
	step("host left")
	await seconds(3.0)  # let the joiner notice


func _join() -> void:
	await wait_for(func() -> bool: return FileAccess.get_file_as_string(code_file).length() >= CODE_LENGTH,
		60.0, "the host's code")
	var code := FileAccess.get_file_as_string(code_file)
	if after_crash:
		# The same player, back after its game crashed: the play is under way already.
		var t := Time.get_ticks_msec()
		await _enter_code(code)
		await wait_for(func() -> bool: return scene_is("Arena") and game.present_players().size() >= 2 and _playing(),
			120.0, "back in the game after the crash")
		step("back %.1f s after entering the code, player %d: %s" % [(Time.get_ticks_msec() - t) / 1000.0,
			game.local_player(), player_names()])
		await wait_for_scene("MainMenu", 60.0)
		return
	await _enter_code(code)
	await wait_for_scene("Arena", 30.0)
	await wait_for(func() -> bool: return game.present_players().size() >= 2, 30.0, "both players in")
	step("joined as player %d: %s" % [game.local_player(), player_names()])
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
		game.leave_to_menu()
		await wait_for_scene("MainMenu", 10.0)
		step("left")
		await seconds(1.0)
		await _enter_code(code)
		await wait_for_scene("Arena", 30.0)
		await wait_for(func() -> bool: return game.present_players().size() >= 2 and _playing(), 30.0,
			"back in the game")
		step("rejoined as player %d: %s" % [game.local_player(), player_names()])
	await wait_for_scene("MainMenu", 60.0)
	var error := find(menu(), ^"%ErrorMessage") as Label
	if failed():
		return
	step("host left -> menu: %s" % (error.text if error.is_visible_in_tree() else "(no error shown)"))


func _enter_code(code: String) -> void:
	if lan:
		await click_menu("JoinAddress")
		var address := find(menu(), ^"%AddressEdit") as LineEdit
		if failed():
			return
		address.clear()
		address.insert_text_at_caret(code)
		await seconds(0.1)
		await click_menu("AddressConnect")
	else:
		await click_menu("Join")
		var edit := find(menu(), ^"%CodeEdit") as LineEdit
		if failed():
			return
		edit.clear()
		edit.insert_text_at_caret(code.to_lower())
		edit.text_changed.emit(edit.text)
		await seconds(0.1)
		await click_menu("CodeJoin")
	step("joining %s" % code)


## The first present player other than the local one (-1: none).
func _friend_player() -> int:
	for info: Dictionary in game.present_players():
		var player := int(info.get("player", -1))
		if player != game.local_player():
			return player
	return -1


func _is_present(player: int) -> bool:
	for info: Dictionary in game.present_players():
		if int(info.get("player", -1)) == player:
			return true
	return false


## Written by the host once its play is done: the joiner's cue to leave (--rejoin) or crash (--crash).
func _played_file() -> String:
	return code_file + ".played"
