extends UnifiedCoop
## survivor's co-op play (the flow is the shared one, UnifiedCoop): the host walks out of the start circle, which
## starts the match, and both fight for ~8 s; the joiner keeps moving until the host leaves.

const DIRS: Array[StringName] = [&"move_left", &"move_back", &"move_right", &"move_forward"]


func _host_play() -> void:
	Input.action_press(&"move_forward")
	await wait_for(_playing, 10.0, "the host walks out: the match starts")
	Input.action_release(&"move_forward")
	step("match started")
	for i in 32:
		await hold(DIRS[floori(i / 8.0) % DIRS.size()], 0.25)
	await shot("c03_coop_match")
	step("co-op match: %d enemies" % int(game.hud.get("enemies_alive", 0)))


func _join_play() -> void:
	await wait_for(_playing, 40.0, "the host starts the match")
	step("match started (seen by the joiner)")
	Input.action_press(&"move_back")  # keeps moving (and alive) while the host plays on


func _playing() -> bool:
	return game.hud.get("phase") == "match"
