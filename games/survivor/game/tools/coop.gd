extends UnifiedCoop
## survivor's co-op play (the flow is the library's, UnifiedCoop): the host walks out of the start circle, which
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
	step("co-op match: %d enemies" % Unified.data.hud.enemies_alive)


func _join_play() -> void:
	await wait_for(_playing, 40.0, "the host starts the match")
	step("match started (seen by the joiner)")
	Input.action_press(&"move_back")  # keeps moving (and alive) while the host plays on


func _playing() -> bool:
	return Unified.data.hud.phase == EnumPhase.MATCH


## The host left: the friend lands on the main menu, which says why.
func _host_left() -> void:
	await wait_for_scene("MainMenu", 10.0)
	var error := find(current_scene, ^"Menu/%ErrorMessage") as Label
	if failed():
		return
	step("on the menu: %s" % (error.text if error.is_visible_in_tree() else "(no error shown)"))
