extends UnifiedUiWalk
## The shared UI walk (UnifiedUiWalk) plus survivor's own play scene, on the real session (single player): the lobby
## (the start circle and hint) -> walk out -> the match (enemies render, the auto-attack fires, a Pick command is
## accepted). The level-up choice and the match-over panel take a real match to reach: the full tour (`uni tool
## survivor tour`) and `play_check` walk them.


func _walk_play() -> void:
	await wait_for(func() -> bool: return game.hud.get("phase") == "lobby" and views(&"player").size() == 1, 5.0,
		"the lobby with one player view")
	expect(_hud(^"Hint").visible, "the start hint shows in the lobby")
	expect((find(current_scene, ^"StartCircle") as Node3D).visible, "the start circle shows in the lobby")
	await frames(20)
	await shot("02_lobby_single")
	step("single player lobby")

	Input.action_press(&"move_right")
	await wait_for(func() -> bool: return game.hud.get("phase") == "match", 6.0, "walking out starts the match")
	Input.action_release(&"move_right")
	step("walked out: the match started")
	await wait_for(func() -> bool: return int(game.hud.get("enemies_alive", 0)) > 0 and _enemies_drawn() > 0, 8.0,
		"enemies spawn and render")
	expect(_hud(^"Top").visible, "the wave and time show in the match")
	await wait_for(func() -> bool: return multi_count(&"projectile") > 0 or multi_count(&"gem") > 0, 15.0,
		"the auto-attack fires")
	await shot("03_match")
	step("match running (enemies, projectiles)")

	var pick: Object = ClassDB.instantiate(&"CommandPick")
	pick.set(&"upgrade", &"damage")
	expect(game.send_command(pick), "a Pick command is accepted (the sim ignores it without a level-up pending)")
	await frames(5)
	expect(not _hud(^"LevelUp").visible, "no level-up panel without a level-up pending")
	step("Pick command sent")


## The enemies the MultiMesh views draw.
func _enemies_drawn() -> int:
	return multi_count(&"grunt") + multi_count(&"runner") + multi_count(&"brute")


## A HUD node by its path under HUD/Root.
func _hud(path: NodePath) -> Control:
	return find(current_scene, NodePath("HUD/Root/" + str(path))) as Control
