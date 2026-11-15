extends UnifiedUiWalk
## The shared UI walk (UnifiedUiWalk) plus survivor's own play scene, on the real session (single player): the lobby
## (the start circle and hint) -> walk out -> the match (enemies render; it walks towards the nearest until the
## auto-attack fires; a Pick command is accepted). The level-up choice and the match-over panel take a real match to
## reach: the full tour (`uni tool survivor tour`) and `play_check` walk them.


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
	# The enemies spawn 27 m out and the auto-attack reaches 14 m: walk towards the nearest one rather than wait.
	await wait_for(func() -> bool: return _attack_fired_steering(), 15.0, "the auto-attack fires")
	_release_moves()
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


## Whether a projectile or a gem is drawn; until then, holds the moves towards the nearest enemy drawn.
func _attack_fired_steering() -> bool:
	if multi_count(&"projectile") > 0 or multi_count(&"gem") > 0:
		return true
	var players := views(&"player")
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
