extends UnifiedCoop
## drift's co-op play (the flow is the library's, UnifiedCoop): the host starts the match from the lobby (the
## `start` command) and both fly in it for a while.


func _host_play() -> void:
	await wait_for(func() -> bool: return _phase() == "lobby", 10.0, "the lobby")
	await click(current_scene.get_node(^"HUD").start_button)
	await wait_for(func() -> bool: return _phase() == "match", 5.0, "the match after Start")
	step("match started")
	await seconds(4.0)
	await shot("c03_coop_match")
	step("co-op match: wave %d" % int(game.hud.get("wave", 0)))


func _join_play() -> void:
	await wait_for(func() -> bool: return _phase() == "match", 40.0, "the host starts the match")
	step("match started (seen by the joiner)")


func _playing() -> bool:
	return _phase() == "match"


func _phase() -> String:
	return String(game.hud.get("phase", ""))
