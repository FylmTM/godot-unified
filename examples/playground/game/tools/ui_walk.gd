extends MenuTool
## A scripted walk through playground's UI with real input events (clicks, pad buttons, keys, actions), the godot
## suite's `walk` step:
##   godot --headless --path examples/playground -s res://game/tools/ui_walk.gd -- --no-settings [--shots=<dir>]
## menu -> settings (Show FPS toggles) -> pad navigation -> single player -> the play scene (`_walk_play()`) -> Esc
## menu -> leave -> host on LAN (the session panel shows the address) -> leave -> join a code that fails (the error on
## the menu). With `--shots=<dir>` (a window) it saves PNGs at the key moments.
##
## Its play scene (`_walk_play()`), on the real session (single player): the first scene (the local camera, the
## pyramid's boxes drawn, the controls list) -> the next-scene key takes everyone to the next scene (its bodies drawn,
## the HUD names it) -> the shoot key fires a bullet there.


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
	await wait_for_scene("Main", 5.0)
	await wait_for(func() -> bool: return local_camera() != null, 5.0, "the local player's camera view")
	expect(not _session_panel().visible, "no session panel in single player")
	expect(_controls_panel().visible, "the controls list shows")
	var move_keys := (_controls_panel().get_child(0).get_child(0) as Label).text  # its first row: Fly
	expect(move_keys == "WASD", "the controls list labels Fly with its bindings (InputMap): %s" % move_keys)
	step("single player")
	await _walk_play()
	await _walk_pause_menu()
	await click(find(find(current_scene, ^"PauseMenu"), ^"%Leave") as Control)
	await wait_for_scene("MainMenu", 5.0)
	await wait_for(func() -> bool: return game.flow == game.Flow.MENU and game.status in [UnifiedSession.STATUS_IDLE, UnifiedSession.STATUS_LEFT], 3.0,
		"the flow back to MENU, the session ended")
	step("left to the menu")

	await frames(3)
	await click_menu("JoinAddress")
	await click_menu("HostLan")
	await wait_for_scene("Main", 5.0)
	await frames(3)
	var code := find(current_scene, ^"HUD/Root/Session/VBox/CodeRow/Code") as Label
	expect(code != null and code.text.ends_with(":%d" % game.lan_port), "the session panel shows host:port")
	expect(_session_panel().visible, "the session panel shows while hosting")
	await shot("06_lan_host")
	step("hosted on LAN: %s" % game.session.join_code)
	await press_action(&"menu")  # the mouse is free under the pause menu: Copy is clicked through it
	var code_row := find(current_scene, ^"HUD/Root/Session/VBox/CodeRow")
	var copy: Button = code_row.get_child(2) as Button if code_row != null else null  # after the label and the code
	await click(copy)
	expect(copy != null and copy.text == "Copied!", "Copy, clicked beside the open pause menu, copies the address")
	step("copied the address under the pause menu")
	game.leave_to_menu()
	await wait_for_scene("MainMenu", 5.0)

	await frames(3)
	await click_menu("Join")
	var edit := find(menu(), ^"%CodeEdit") as LineEdit
	if failed():
		return
	edit.clear()  # a windowed run may have prefilled it from the real clipboard
	await type_text("ab0o1l")  # 0, O, 1 and L look like other characters: the code alphabet has none of them
	await frames(2)
	expect(edit.text == "AB", "the code field keeps only the code's characters (got '%s')" % edit.text)
	edit.clear()
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
	var first: int = session.level
	await wait_for(func() -> bool: return multi_count(EnumMultiView.BOX) > 0, 5.0, "the first scene's bodies drawn")
	await frames(20)
	await shot("02_play")
	step("%s: %d boxes" % [EnumLevel.name(first), multi_count(EnumMultiView.BOX)])

	var next := (first + 1) % EnumLevel.names().size()
	await press_action(&"next_scene")
	await wait_for(func() -> bool: return session.level == next and Unified.data.hud.scene == next, 5.0,
		"the next-scene key takes everyone to the next scene")
	await wait_for(func() -> bool: return multi_count(EnumMultiView.BOX) > 0, 5.0, "the next scene's bodies drawn")
	var scene_label := find(current_scene, ^"HUD/Root/Top/Scene") as Label
	expect(scene_label != null and scene_label.text == String(EnumLevel.name(next)).capitalize(),
		"the HUD names the scene")
	step("next scene: %s" % EnumLevel.name(next))

	var spheres := multi_count(EnumMultiView.SPHERE)
	await press_action(&"shoot")
	await wait_for(func() -> bool: return multi_count(EnumMultiView.SPHERE) > spheres, 3.0, "the shoot key fires a bullet")
	await frames(10)
	await shot("02b_shot")
	step("shot a bullet")


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
	await pad_button(JOY_BUTTON_START, 1)
	expect(pause.visible, "a second pad's Start opens the menu (the menu action hears every pad)")
	await pad_button(JOY_BUTTON_START, 1)
	expect(not pause.visible, "and closes it")
	await press_action(&"menu")
	step("Esc menu")


func _session_panel() -> Control:
	return find(current_scene, ^"HUD/Root/Session") as Control


func _controls_panel() -> Control:
	return find(current_scene, ^"HUD/Root/Controls") as Control
