extends MenuTool
## A scripted walk through holdout's UI with real input events (clicks, pad buttons, keys, actions), the godot suite's
## `walk` step:
##   godot --headless --path examples/holdout -s res://game/tools/ui_walk.gd -- --no-settings [--shots=<dir>]
## menu -> settings (Show FPS toggles) -> pad navigation -> single player -> the play scene (the local player's view,
## the controls list labelled from the InputMap, Ready starts the countdown) -> the Esc menu pauses single player ->
## Leave to menu -> host on LAN (the session panel shows the address) -> leave -> join a code that fails (the error on
## the menu). With `--shots=<dir>` (a window) it saves PNGs at the key moments.


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
	await wait_for(func() -> bool: return local_view() != null, 8.0, "the local player's view")
	await frames(3)
	expect(not _session_panel().visible, "no session panel in single player")
	expect(_controls_panel().visible, "the controls list shows")
	var ready_keys := (_controls_panel().get_child(0).get_child(0) as Label).text  # its first row in the lobby: Ready
	expect(ready_keys == ("Y" if game.using_pad else "R / Enter"),
		"the controls list labels Ready with its bindings (InputMap): %s" % ready_keys)
	await shot("02_lobby")
	step("single player")
	await _walk_ready()
	await _walk_pause_menu()
	await press_action(&"menu")
	await click(find(find(current_scene, ^"PauseMenu"), ^"%Leave") as Control)
	await wait_for_scene("MainMenu", 5.0)
	await wait_for(func() -> bool: return game.flow == game.Flow.MENU and game.status in [UnifiedSession.STATUS_IDLE, UnifiedSession.STATUS_LEFT], 3.0,
		"the flow back to MENU, the session ended")
	step("left to the menu")

	await frames(3)
	await click_menu("JoinAddress")
	await click_menu("HostLan")
	await wait_for_scene("Arena", 5.0)
	await frames(3)
	var code := find(current_scene, ^"HUD/Root/Session/VBox/CodeRow/Code") as Label
	expect(code != null and code.text.ends_with(":%d" % game.lan_port), "the session panel shows host:port")
	await shot("05_lan_host")
	step("hosted on LAN: %s" % game.session.join_code)
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
	await shot("06_join_code")
	await click_menu("CodeJoin")
	if game.flow == game.Flow.CONNECTING:  # a session without online play fails at once
		await frames(3)
		await shot("07_connecting")
	await wait_for(func() -> bool: return menu() != null and menu().visible_panel() == find(menu(), ^"%ErrorPanel"),
		20.0, "a failed join shows the error on the menu")
	await frames(3)
	await shot("08_join_error")
	step("bad code -> the error on the menu")


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


## Ready in the lobby starts the countdown: the play scene's input reaches the sim.
func _walk_ready() -> void:
	if failed():
		return
	await press_action(&"ready")
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.COUNTDOWN, 3.0, "Ready starts the countdown")
	await frames(3)
	await shot("03_countdown")
	step("ready: the countdown")


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
	await shot("04_pause_menu")
	await press_action(&"menu")
	expect(not pause.visible, "Esc closes the menu")
	await seconds(0.3)
	expect(not session.paused and session.tick > held, "the ticks go on once it closes")
	await pad_button(JOY_BUTTON_START, 1)
	expect(pause.visible, "a second pad's Start opens the menu (the menu action hears every pad)")
	await pad_button(JOY_BUTTON_START, 1)
	expect(not pause.visible, "and closes it")
	step("Esc menu")


func _session_panel() -> Control:
	return find(current_scene, ^"HUD/Root/Session") as Control


func _controls_panel() -> Control:
	return find(current_scene, ^"HUD/Root/Controls") as Control
