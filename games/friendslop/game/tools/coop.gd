extends UnifiedCoop
## friendslop's co-op play (the flow is the library's, UnifiedCoop): the host walks over to the friend and picks
## them up; the friend mashes jump and breaks free.

const Steering := preload("res://game/tools/steering.gd")


func _host_play() -> void:
	var friend := _friend_player()
	await Steering.walk_to(self, func() -> Vector3: return Steering.player_view(self, friend).global_position, 15.0, 1.4)
	await Steering.face(self, Steering.player_view(self, friend).global_position, -0.1)
	for attempt in 5:
		await hold(&"grab", 0.08)
		if _held(friend):
			break
		await seconds(0.3)
	await wait_for(func() -> bool: return _held(friend), 5.0, "holding the friend")
	await shot("c03_holding_friend")
	step("holding the friend")
	await wait_for(func() -> bool: return not _held(friend), 20.0, "the friend breaks free")
	step("the friend broke free")


func _join_play() -> void:
	await wait_for(func() -> bool: return _held(session.local_player), 60.0, "the host picks us up")
	step("held by the host")
	await seconds(0.7)
	while _held(session.local_player) and not failed():
		await hold(&"jump", 0.08)
		await seconds(0.1)
	step("broke free")


## Someone holds this player (false while they hold no slot).
func _held(player: int) -> bool:
	var slot := session.get_player_slot(player)
	return slot >= 0 and (Unified.data.hud.players[slot] as DataHudPlayer).held


## The host left: the friend lands on the main menu, which says why.
func _host_left() -> void:
	await wait_for_scene("MainMenu", 10.0)
	var error := find(current_scene, ^"Menu/%ErrorMessage") as Label
	if failed():
		return
	step("on the menu: %s" % (error.text if error.is_visible_in_tree() else "(no error shown)"))
