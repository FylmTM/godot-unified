extends MenuTool
## A scripted walk through friendslop's UI with real input events (clicks, pad buttons, keys, actions), the godot suite's
## `walk` step:
##   godot --headless --path games/friendslop -s res://game/tools/ui_walk.gd -- --no-settings [--shots=<dir>]
## menu -> settings (Show FPS toggles) -> pad navigation -> single player -> the play scene (`_walk_play()`) -> Esc
## menu -> leave -> online play (`_walk_online()`) -> host on LAN (the session panel shows the address) -> leave ->
## join a code that fails (the error on the menu). With `--shots=<dir>` (a window) it saves PNGs at the key moments.
##
## Its play scene (`_walk_play()`), on the real session (single player), steered
## as a player would (turning the camera rig, holding forward): the hub (the player's view, the marker views) -> walk
## to a crate, grab it, charge and throw it (it flies at least 2 m) -> travel to the route and back with the pause
## menu's "Back to hub" (`_walk_travel()`). The jump pad and the rest of the route: the full tour
## (`uni tool friendslop tour`).

const Steering := preload("res://game/tools/steering.gd")


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
	await _walk_travel()
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
	await wait_for(func() -> bool: return _me() != null, 8.0, "the player's view")
	await wait_for(func() -> bool: return views(EnumView.MARKER).size() >= 10, 5.0, "marker views (items, platforms)")
	await shot("02_hub")
	step("hub: %d markers adopted" % views(EnumView.MARKER).size())

	var crate := _marker_view("Crate1")
	if crate == null:
		fail("no view for Crate1")
		return
	await Steering.walk_to(self, func() -> Vector3: return crate.global_position + Vector3(-1.1, 0, 0), 8.0, 0.35)
	await Steering.face(self, crate.global_position, -0.35)
	await hold(&"grab", 0.1)
	await wait_for(func() -> bool: return _holding() == EnumHeldKind.ITEM, 1.0, "holding the crate")
	await shot("02b_holding")
	step("grabbed a crate next to %s" % Steering.fmt(crate.global_position))

	var before := _marker_positions()
	await hold(&"throw", 0.4)
	await wait_for(func() -> bool: return _holding() == EnumHeldKind.NONE, 1.0, "the throw")
	await wait_for(func() -> bool: return _moved_most(before) >= 2.0, 2.0, "the thrown crate moves at least 2 m")
	await shot("02c_thrown")
	step("threw it %.1f m" % _moved_most(before))


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


## The Esc menu opens over the play and closes; the sim keeps running under it.
## The level change: a travel command takes the team to the route (its scene swapped in under the arena's level root,
## the marker views the route's), then the pause menu's "Back to hub" brings it back.
func _walk_travel() -> void:
	if failed():
		return
	var travel := CommandTravel.new()
	travel.to = EnumLevelId.ROUTE
	expect(session.send_command(travel), "a travel command is taken")
	await wait_for(func() -> bool: return session.level == EnumLevelId.ROUTE, 8.0, "the route on screen")
	await wait_for(func() -> bool: return _marker_view("Trophy") != null, 5.0, "the route's marker views")
	await shot("02b_route")
	step("route: %d markers adopted" % views(EnumView.MARKER).size())
	var pause := find(current_scene, ^"PauseMenu") as CanvasLayer
	await press_action(&"menu")
	await click(find(pause, ^"%Hub") as Control)
	await wait_for(func() -> bool: return session.level == EnumLevelId.HUB, 8.0, "back in the hub")
	await wait_for(func() -> bool: return _marker_view("Crate1") != null, 5.0, "the hub's marker views")
	expect(not pause.visible, "Back to hub closes the menu")
	step("back to the hub")


func _walk_pause_menu() -> void:
	var pause := find(current_scene, ^"PauseMenu") as CanvasLayer
	if failed():
		return
	var tick0: int = session.tick
	await press_action(&"menu")
	expect(pause.visible, "Esc opens the menu")
	await seconds(0.3)
	expect(session.tick > tick0, "the sim keeps running under the menu")
	await shot("03_pause_menu")
	await press_action(&"menu")
	expect(not pause.visible, "Esc closes the menu")
	await press_action(&"menu")
	step("Esc menu")
	# open to friends: the single-player session hosts on the LAN port and keeps running
	var tick1: int = session.tick
	await click(find(pause, ^"%Invite") as Control)
	await wait_for(func() -> bool: return session.mode == UnifiedSession.MODE_HOST_DIRECT and session.join_code != "", 5.0,
		"the session opens to friends")
	if failed():
		return
	expect(session.tick > tick1 and session.status == UnifiedSession.STATUS_CONNECTED, "the session went on")
	expect(game.mode == game.Mode.HOST_LAN, "the flow follows: hosting on LAN")
	await press_action(&"menu")
	expect((find(pause, ^"%StopInviting") as Control).visible, "the menu offers to stop inviting")
	step("invited friends: %s" % session.join_code)


func _session_panel() -> Control:
	return find(current_scene, ^"HUD/Root/Session") as Control


func _controls_panel() -> Control:
	return find(current_scene, ^"HUD/Root/Controls") as Control


## Marker views' positions by key (marker index).
func _marker_positions() -> Dictionary[int, Vector3]:
	var out: Dictionary[int, Vector3] = {}
	for v: Node in views(EnumView.MARKER):
		out[_key(v)] = (v as Node3D).global_position
	return out


## The farthest any marker view moved since `before`.
func _moved_most(before: Dictionary[int, Vector3]) -> float:
	var after := _marker_positions()
	var moved := 0.0
	for k: int in before:
		moved = maxf(moved, (after.get(k, before[k]) as Vector3).distance_to(before[k]))
	return moved


## The view of a level marker by its node name (a marker view's key is its marker index).
func _marker_view(marker_name: String) -> Node3D:
	if session.level_scene == null:
		return null
	var markers: Array[Node] = Unified.level_markers(session.level_scene)
	for i in markers.size():
		if markers[i].name == marker_name:
			return session.get_view(EnumView.MARKER, i) as Node3D
	return null


## The local player's view, or null.
func _me() -> Node3D:
	return session.get_player_view(EnumView.PLAYER, session.local_player) as Node3D


## What the local player holds (NONE while they hold no slot).
func _holding() -> int:
	var me := local_row()
	return me.holding if me != null else EnumHeldKind.NONE


## A view's key, from its UnifiedView marker.
static func _key(v: Node) -> int:
	return (v.get_node(^"UnifiedView") as UnifiedView).key
