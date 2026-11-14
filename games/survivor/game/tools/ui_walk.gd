extends UnifiedUiWalk
## The shared UI walk (UnifiedUiWalk) plus survivor's own UI, on the mock session (uni passes `--mock`), whose
## debug calls force the states a walk can't reach quickly: the lobby -> walk out -> the match -> a level-up (key 1)
## -> the match over -> back to the lobby; online: host (a code, a bot friend joins, the session panel) -> a co-op
## match -> the connection lost (the reason on the menu).


func _run() -> void:
	if not game.is_mock:
		fail("the walk needs the mock session: pass -- --mock")
		return
	game.session.over_seconds = 0.6
	game.session.bot_join_seconds = 0.3
	if shots_dir == "":
		Engine.time_scale = 4.0  # the fake sim's waits (walking, connect delays) dominate; shots run in real time
	await super()


func _walk_play() -> void:
	var mock: Node = game.session
	await wait_for(func() -> bool: return game.hud.phase == "lobby" and views(&"player").size() == 1, 2.0,
		"the lobby with one player view")
	expect(_hud(^"Hint").visible, "the start hint shows in the lobby")
	expect((find(current_scene, ^"StartCircle") as Node3D).visible, "the start circle shows in the lobby")
	await frames(20)
	await shot("02_lobby_single")
	step("single player lobby")

	Input.action_press(&"move_right")
	await wait_for(func() -> bool: return game.hud.phase == "match", 3.0, "walking out starts the match")
	Input.action_release(&"move_right")
	step("walked out: the match started")
	mock.debug_spawn(40, 11.0)
	await wait_for(func() -> bool: return game.hud.enemies_alive > 0 and bulk_count(&"grunt") > 0, 2.0,
		"enemies spawn and render")
	expect(_hud(^"Top").visible, "the wave and time show in the match")
	await hold(&"move_left", 0.3)
	await wait_for(func() -> bool: return bulk_count(&"projectile") > 0 or bulk_count(&"gem") > 0, 3.0,
		"the auto-attack fires")
	await shot("03_match")
	step("match running (enemies, projectiles)")

	mock.debug_grant_levelup()
	await wait_for(func() -> bool: return _hud(^"LevelUp").visible, 1.0, "the level-up panel shows")
	await frames(10)
	await shot("04_levelup")
	await press_action(&"levelup_1")
	await wait_for(func() -> bool: return int(game.local_player_info().pending_levelups) == 0, 1.0,
		"key 1 takes the level-up")
	await wait_for(func() -> bool: return not _hud(^"LevelUp").visible, 1.0, "the level-up panel hides")
	step("level-up chosen with key 1")

	mock.debug_end_match()
	await wait_for(func() -> bool: return _hud(^"GameOver").visible, 1.0, "the match-over panel shows")
	await frames(12)
	await shot("05_game_over")
	await wait_for(func() -> bool: return game.hud.phase == "lobby", 3.0, "the sim returns to the lobby")
	await frames(2)
	expect(not _hud(^"GameOver").visible, "the match-over panel hides in the lobby")
	step("match over -> lobby")


func _walk_online() -> void:
	var mock: Node = game.session
	await frames(3)
	await click_menu("Host")
	await wait_for(func() -> bool: return game.lobby_code.length() == 6, 2.0, "the host gets a lobby code")
	await wait_for_scene("Arena", 3.0)
	expect(_hud(^"Session").visible, "the session panel shows when hosting")
	expect(_hud(^"Session/VBox/CodeRow/Code").text == game.lobby_code, "the session panel shows the code")
	await wait_for(func() -> bool: return views(&"player").size() == 2, 5.0, "the bot friend joins")
	if shots_dir != "":
		await seconds(0.6)
	await shot("06_lobby_hosting")
	step("hosted: code %s, friend joined" % game.lobby_code)
	Input.action_press(&"move_forward")
	await wait_for(func() -> bool: return game.hud.phase == "match", 3.0, "the host walks out: the match starts")
	Input.action_release(&"move_forward")
	mock.debug_spawn(60, 12.0)
	mock.debug_spawn(80)
	await wait_for(func() -> bool: return bulk_count(&"projectile") > 0, 3.0, "the co-op auto-attack fires")
	if shots_dir != "":
		await seconds(2.0)  # let the fight develop for the picture
	await _measure_frames("co-op match, %d enemies" % game.hud.enemies_alive)
	mock.debug_explode_nearest_barrel()
	await frames(4)
	await shot("07_match_coop")
	step("co-op match")

	mock.debug_disconnect()
	await wait_for(func() -> bool: return menu() != null and menu().visible_panel() == find(menu(), ^"%ErrorPanel"),
		3.0, "a disconnect shows the error on the menu")
	expect((find(menu(), ^"%ErrorMessage") as Label).text.begins_with("Disconnected"), "the error names the disconnect")
	await click_menu("ErrorOk")
	step("disconnect -> the menu with the reason")


## A HUD node by its path under HUD/Root.
func _hud(path: NodePath) -> Control:
	return find(current_scene, NodePath("HUD/Root/" + str(path))) as Control


## Wall time per frame and the mock session's own cost (fake sim, view and bulk writes) over 60 frames.
func _measure_frames(what: String) -> void:
	var frame_total := 0.0
	var frame_max := 0.0
	var mock_total := 0.0
	var t := Time.get_ticks_usec()
	for i in 60:
		await process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - t) / 1000.0
		t = now
		frame_total += ms
		frame_max = maxf(frame_max, ms)
		mock_total += game.session.cost_us / 1000.0
	print("  perf  %s: frame %.2f ms mean, %.2f ms max; mock session %.2f ms (means; time scale %.0f)" % [
		what, frame_total / 60.0, frame_max, mock_total / 60.0, Engine.time_scale])
