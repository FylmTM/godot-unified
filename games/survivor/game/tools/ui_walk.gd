extends MenuTool
## A scripted walk through survivor's UI with real input events (clicks, pad buttons, keys, actions), the godot suite's
## `walk` step:
##   godot --headless --path games/survivor -s res://game/tools/ui_walk.gd -- --no-settings [--shots=<dir>]
## menu -> settings (Show FPS toggles) -> pad navigation -> single player -> the play scene (`_walk_play()`) -> Esc
## menu -> leave -> online play (`_walk_online()`) -> host on LAN (the session panel shows the address) -> leave ->
## join a code that fails (the error on the menu). With `--shots=<dir>` (a window) it saves PNGs at the key moments.
##
## Its play scene (`_walk_play()`), on the real session (single player): the lobby
## (the start circle and hint) -> walk out -> the match (enemies render; it walks towards the nearest until the
## auto-attack fires; a Pick command is accepted). The level-up choice and the match-over panel take a real match to
## reach: the full tour (`uni tool survivor tour`) walks them.


func _run() -> void:
	game.lan_port = 20000 + randi() % 20000  # parallel walks (one per game) must not share a port
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await wait_for_scene("MainMenu", 5.0)
	await frames(5)
	await shot("01_menu")
	step("main menu")

	await _walk_settings()
	await _walk_pad()

	await click_menu("Single")
	await wait_for_scene("Arena", 5.0)
	await wait_for(func() -> bool: return local_row() != null, 5.0,
		"the local player in the HUD")
	expect(not _session_panel().visible, "no session panel in single player")
	expect(_controls_panel().visible, "the controls list shows")
	var move_keys := (_controls_panel().get_child(0).get_child(0) as Label).text  # its first row: Move
	expect(move_keys == ("Left stick / D-pad" if game.using_pad else "WASD / Arrows"),
		"the controls list labels Move with its bindings (InputMap): %s" % move_keys)
	step("single player")
	await _walk_play()
	await _walk_pause_menu()
	await click(find(find(current_scene, ^"PauseMenu"), ^"%Leave") as Control)
	await wait_for_scene("MainMenu", 5.0)
	await wait_for(func() -> bool: return game.flow == game.Flow.MENU and game.status in [UnifiedSession.STATUS_IDLE, UnifiedSession.STATUS_LEFT], 3.0,
		"the flow back to MENU, the session ended")
	step("left to the menu")

	await _walk_online()

	await frames(3)
	await click_menu("JoinAddress")
	await click_menu("HostLan")
	await wait_for_scene("Arena", 5.0)
	await frames(3)
	var code := find(current_scene, ^"HUD/Root/Session/VBox/CodeRow/Code") as Label
	expect(code != null and code.text.ends_with(":%d" % game.lan_port), "the session panel shows host:port")
	await shot("06_lan_host")
	step("hosted on LAN: %s" % game.session.join_code)
	game.leave_to_menu()
	await wait_for_scene("MainMenu", 5.0)

	await frames(3)
	await click_menu("Join")
	var edit := find(menu(), ^"%CodeEdit") as LineEdit
	if failed():
		return
	edit.clear()  # a windowed run may have prefilled it from the real clipboard
	await type_text("zz-zz zz")  # messy input: cleaned to ZZZZZZ
	await frames(2)  # LineEdit emits text_changed deferred
	expect(edit.text == "ZZZZZZ", "the code field cleans and uppercases its input (got '%s')" % edit.text)
	await shot("07_join_code")
	await click_menu("CodeJoin")
	if game.flow == game.Flow.CONNECTING:  # a session without online play fails at once
		await frames(3)
		await shot("08_connecting")
	await wait_for(func() -> bool: return menu() != null and menu().visible_panel() == find(menu(), ^"%ErrorPanel"),
		20.0, "a failed join shows the error on the menu")
	await frames(3)
	await shot("09_join_error")
	step("bad code -> the error on the menu")


func _walk_play() -> void:
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.LOBBY and views(EnumView.PLAYER).size() == 1, 5.0,
		"the lobby with one player view")
	expect(_hud(^"Hint").visible, "the start hint shows in the lobby")
	expect((find(current_scene, ^"StartCircle") as Node3D).visible, "the start circle shows in the lobby")
	await frames(20)
	await shot("02_lobby_single")
	step("single player lobby")

	Input.action_press(&"move_right")
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.MATCH, 6.0, "walking out starts the match")
	Input.action_release(&"move_right")
	step("walked out: the match started")
	await wait_for(func() -> bool: return Unified.data.hud.enemies_alive > 0 and _enemies_drawn() > 0, 8.0,
		"enemies spawn and render")
	expect(_hud(^"Top").visible, "the wave and time show in the match")
	# The enemies spawn 27 m out and the auto-attack reaches 14 m: walk towards the nearest one rather than wait.
	await wait_for(func() -> bool: return _attack_fired_steering(), 15.0, "the auto-attack fires")
	_release_moves()
	await shot("03_match")
	step("match running (enemies, projectiles)")

	var pick := CommandPick.new()
	pick.upgrade = EnumUpgrade.DAMAGE
	expect(session.send_command(pick), "a Pick command is accepted (the sim ignores it without a level-up pending)")
	await frames(5)
	expect(not _hud(^"LevelUp").visible, "no level-up panel without a level-up pending")
	step("Pick command sent")


## Online play through the lobby service (default: skipped; it needs EOS, or a game's stand-in session).
func _walk_online() -> void:
	pass


func _walk_settings() -> void:
	await click_menu("Settings")
	var panel: Control = menu().visible_panel() if menu() != null else null
	expect(panel != null and panel.name == "SettingsPanel", "Settings opens the settings panel")
	if failed():
		return
	var fps: CheckButton = panel.control("Show FPS")
	await click(fps)
	expect(setting(&"show_fps") == true, "Show FPS turns the setting on")
	await frames(3)
	await shot("01b_settings")
	await click(fps)
	expect(setting(&"show_fps") == false, "Show FPS turns it off again")
	await click(find(panel, ^"%Back") as Control)
	expect(not panel.visible, "Done closes the settings")
	step("settings panel")


## A pad drives the menu: the d-pad moves focus, A presses, B goes back; a key switches the hints back.
func _walk_pad() -> void:
	(find(menu(), ^"%Single") as Control).grab_focus()
	for i in 4:
		await pad_button(JOY_BUTTON_DPAD_DOWN)
	expect(root.gui_get_focus_owner() == find(menu(), ^"%Settings"), "the d-pad moves focus to Settings")
	await pad_button(JOY_BUTTON_A)
	expect(menu().visible_panel() != null, "pad A opens the focused Settings")
	await pad_button(JOY_BUTTON_B)
	expect(menu().visible_panel() == null, "pad B closes the panel")
	expect(game.using_pad, "the game switched to pad hints")
	await type_text("q")  # any key switches back (not Space: it presses the focused button)
	expect(not game.using_pad, "a key switches back to keyboard hints")
	step("pad menu navigation")


## The Esc menu opens over the play and closes; in single player it pauses the session meanwhile.
func _walk_pause_menu() -> void:
	var pause := find(current_scene, ^"PauseMenu") as CanvasLayer
	if failed():
		return
	await press_action(&"menu")
	expect(pause.visible, "Esc opens the menu")
	await seconds(0.1)
	expect(session.paused, "single player: the menu pauses the session")
	var held: int = session.tick
	await seconds(0.3)
	expect(session.tick == held, "no tick while paused")
	await shot("03_pause_menu")
	await press_action(&"menu")
	expect(not pause.visible, "Esc closes the menu")
	await seconds(0.3)
	expect(not session.paused and session.tick > held, "the ticks go on once it closes")
	await press_action(&"menu")
	step("Esc menu")


func _session_panel() -> Control:
	return find(current_scene, ^"HUD/Root/Session") as Control


func _controls_panel() -> Control:
	return find(current_scene, ^"HUD/Root/Controls") as Control


## The enemies the MultiMesh views draw.
func _enemies_drawn() -> int:
	return multi_count(EnumMultiView.GRUNT) + multi_count(EnumMultiView.RUNNER) + multi_count(EnumMultiView.BRUTE)


## Whether a projectile or a gem is drawn; until then, holds the moves towards the nearest enemy drawn.
func _attack_fired_steering() -> bool:
	if multi_count(EnumMultiView.PROJECTILE) > 0 or multi_count(EnumMultiView.GEM) > 0:
		return true
	var players := views(EnumView.PLAYER)
	if players.is_empty():
		return false
	var from := (players[0] as Node3D).global_position
	var nearest := Vector3.INF
	for marker: Node in root.find_children("*", "UnifiedMultiView", true, false):
		if (marker as UnifiedMultiView).kind not in ["grunt", "runner", "brute"]:
			continue
		var instance := marker.get_parent() as MultiMeshInstance3D
		var mm := instance.multimesh
		var buffer := mm.buffer  # the dummy renderer (headless) keeps the buffer, not the instance transforms
		var stride := 12 + (4 if mm.use_colors else 0) + (4 if mm.use_custom_data else 0)
		for i in mini(mm.visible_instance_count, buffer.size() / stride):
			var at := i * stride
			var pos := instance.global_transform * Vector3(buffer[at + 3], buffer[at + 7], buffer[at + 11])
			if from.distance_squared_to(pos) < from.distance_squared_to(nearest):
				nearest = pos
	_release_moves()
	if nearest != Vector3.INF:
		var to := nearest - from  # move_right is +X, move_back +Z
		for move: Array in [[to.x, &"move_right", &"move_left"], [to.z, &"move_back", &"move_forward"]]:
			if absf(move[0]) > 0.5:
				Input.action_press(move[1] if move[0] > 0 else move[2])
	return false


func _release_moves() -> void:
	for action: StringName in [&"move_left", &"move_right", &"move_forward", &"move_back"]:
		Input.action_release(action)


## A HUD node by its path under HUD/Root.
func _hud(path: NodePath) -> Control:
	return find(current_scene, NodePath("HUD/Root/" + str(path))) as Control
