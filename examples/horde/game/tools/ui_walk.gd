extends MenuTool
## A scripted walk through horde's UI with real input events (clicks, pad buttons, keys, actions), the godot suite's
## `walk` step:
##   godot --headless --path examples/horde -s res://game/tools/ui_walk.gd -- --no-settings [--shots=<dir>]
## menu -> settings (Show FPS toggles) -> pad navigation -> single player -> the play scene (`_walk_play()`) -> Esc
## menu -> leave -> host on LAN (the session panel shows the address) -> leave -> join a code that fails (the error on
## the menu). With `--shots=<dir>` (a window) it saves PNGs at the key moments.
##
## Its play scene (`_walk_play()`), on the real session (single player): the match runs from the start (the crowds
## render, the hero's weapons fire and the effects show), a level-up's cards come up with the HUD's offers and a
## pick by key takes one.


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
	await wait_for(func() -> bool: return local_row() != null, 5.0, "the local hero in the HUD")
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

	await frames(3)
	await click_menu("JoinAddress")
	await click_menu("HostLan")
	await wait_for_scene("Arena", 5.0)
	await frames(3)
	var shown := _session_panel().find_children("*", "Label", true, false).filter(func(label: Label) -> bool:
		return label.is_visible_in_tree() and label.text.ends_with(":%d" % game.lan_port))
	expect(not shown.is_empty(), "the session panel shows host:port (no lobby: the match's small code line)")
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
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.MATCH and views(EnumView.HERO).size() == 1, 5.0,
		"the match with one hero view")
	await wait_for(func() -> bool: return multi_count(EnumMultiView.ENEMY) > 0, 5.0, "enemies spawn and render")
	# The bursts come on a ring well past every weapon's range: the hero stands and lets them come.
	await wait_for(func() -> bool: return multi_count(EnumMultiView.BOLT) > 0, 20.0, "the hero's bolts fire")
	await wait_for(func() -> bool: return Unified.data.hud.kills > 0, 10.0, "the weapons kill")
	await frames(10)
	await shot("03_match")
	step("match running (%d enemies, %d kills)" % [Unified.data.hud.enemies, Unified.data.hud.kills])

	# Gems fly to a hero within reach, and the first level takes a few: walk among the drops until a level-up is up.
	await wait_for(func() -> bool: return _walk_to_gems(), 30.0, "a level-up comes up")
	_release_moves()
	await wait_for(func() -> bool: return _hud(^"LevelUp").visible, 2.0, "the level-up cards show")
	var row := local_row()
	var first := find(_hud(^"LevelUp"), ^"VBox/Options/Option1") as Button
	var card: DataUpgradeCard = Unified.constants.upgrades[row.offers[0]]
	expect(first != null and first.text.begins_with(card.name), "the first card is the first offer (%s)" % card.name)
	await shot("04_levelup")
	var pending := row.pending_levelups
	await press_action(&"levelup_1")
	await wait_for(func() -> bool: return local_row().pending_levelups < pending, 2.0, "a pick by key takes the offer")
	step("level-up picked: %s" % card.name)


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
	await shot("05_pause_menu")
	await press_action(&"menu")
	expect(not pause.visible, "Esc closes the menu")
	await seconds(0.3)
	expect(not session.paused and session.tick > held, "the ticks go on once it closes")
	await press_action(&"menu")
	step("Esc menu")


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


## Whether a level-up is pending; until then, holds the moves towards the nearest gem drawn.
func _walk_to_gems() -> bool:
	var row := local_row()
	if row != null and row.pending_levelups > 0:
		return true
	var heroes := views(EnumView.HERO)
	if heroes.is_empty():
		return false
	var from := (heroes[0] as Node2D).global_position
	var nearest := Vector2.INF
	for marker: Node in root.find_children("*", "UnifiedMultiView", true, false):
		if (marker as UnifiedMultiView).kind != "gem":
			continue
		var instance := marker.get_parent() as MultiMeshInstance2D
		var instances := instance.multimesh
		var buffer := instances.buffer  # the dummy renderer (headless) keeps the buffer, not the instance transforms
		var stride := 8 + (4 if instances.use_colors else 0) + (4 if instances.use_custom_data else 0)
		for i in mini(instances.visible_instance_count, buffer.size() / stride):
			var at := i * stride
			var pos := instance.global_transform * Vector2(buffer[at + 3], buffer[at + 7])
			if from.distance_squared_to(pos) < from.distance_squared_to(nearest):
				nearest = pos
	_release_moves()
	if nearest != Vector2.INF:
		var to := nearest - from  # move_right is +x, move_back +y (down)
		for move: Array in [[to.x, &"move_right", &"move_left"], [to.y, &"move_back", &"move_forward"]]:
			if absf(move[0]) > 4.0:
				Input.action_press(move[1] if move[0] > 0 else move[2])
	return false


func _release_moves() -> void:
	for action: StringName in [&"move_left", &"move_right", &"move_forward", &"move_back"]:
		Input.action_release(action)


func _session_panel() -> Control:
	return find(current_scene, ^"HUD/Root/Session") as Control


func _controls_panel() -> Control:
	return find(current_scene, ^"HUD/Root/Controls") as Control


## A HUD node by its path under HUD/Root.
func _hud(path: NodePath) -> Control:
	return find(current_scene, NodePath("HUD/Root/" + str(path))) as Control
