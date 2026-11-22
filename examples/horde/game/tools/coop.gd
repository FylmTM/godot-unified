extends UnifiedCoop
## horde's co-op play (the flow is the library's, UnifiedCoop): a match runs from the start, so the host walks a
## square among the crowd for ~8 s while the joiner keeps moving, until the host leaves.

const DIRS: Array[StringName] = [&"move_left", &"move_back", &"move_right", &"move_forward"]


func _host_play() -> void:
	await wait_for(_playing, 10.0, "the match runs")
	for i in 32:
		await hold(DIRS[floori(i / 8.0) % DIRS.size()], 0.25)
	await shot("c03_coop_match")
	step("co-op match: wave %d, %d enemies" % [Unified.data.hud.wave, Unified.data.hud.enemies])


func _join_play() -> void:
	await wait_for(_playing, 40.0, "the match runs (seen by the joiner)")
	Input.action_press(&"move_back")  # keeps moving while the host plays on


func _playing() -> bool:
	return Unified.data.hud.phase == EnumPhase.MATCH and Unified.data.hud.enemies > 0


## The host left: the friend lands on the main menu, which says why.
func _host_left() -> void:
	await wait_for_scene("MainMenu", 10.0)
	var error := find(current_scene, ^"Menu/%ErrorMessage") as Label
	if failed():
		return
	step("on the menu: %s" % (error.text if error.is_visible_in_tree() else "(no error shown)"))
