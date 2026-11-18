extends UnifiedCoop
## drift's co-op play (the flow is the library's, UnifiedCoop): the host starts the match from the lobby (the
## `start` command) and both fly in it for a while.


func _host_play() -> void:
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.LOBBY, 10.0, "the lobby")
	await click(current_scene.get_node(^"HUD").start_button)
	await wait_for(_playing, 5.0, "the match after Start")
	step("match started")
	await seconds(4.0)
	await shot("c03_coop_match")
	step("co-op match: wave %d" % Unified.data.hud.wave)


func _join_play() -> void:
	await wait_for(_playing, 40.0, "the host starts the match")
	step("match started (seen by the joiner)")


func _playing() -> bool:
	return Unified.data.hud.phase == EnumPhase.MATCH


## The host left: the friend lands on the main menu, which says why.
func _host_left() -> void:
	await wait_for_scene("MainMenu", 10.0)
	var error := find(current_scene, ^"Menu/%ErrorMessage") as Label
	if failed():
		return
	step("on the menu: %s" % (error.text if error.is_visible_in_tree() else "(no error shown)"))
