extends UnifiedCoop
## friendslop's co-op play (the flow is the library's, UnifiedCoop): the host walks over to the friend and picks
## them up; the friend mashes jump and breaks free.

const Steering := preload("res://game/tools/steering.gd")


func _host_play() -> void:
	var friend: int = 1 - game.local_slot()
	var arena: Node3D = current_scene
	await Steering.walk_to(self, func() -> Vector3: return arena.player_view(friend).global_position, 15.0, 1.4)
	await Steering.face(self, arena.player_view(friend).global_position, -0.1)
	for attempt in 5:
		await hold(&"grab", 0.08)
		if game.player(friend).get("held", false):
			break
		await seconds(0.3)
	await wait_for(func() -> bool: return game.player(friend).get("held", false), 5.0, "holding the friend")
	await shot("c03_holding_friend")
	step("holding the friend")
	await wait_for(func() -> bool: return not game.player(friend).get("held", false), 20.0, "the friend breaks free")
	step("the friend broke free")


func _join_play() -> void:
	await wait_for(func() -> bool: return game.local_player().get("held", false), 60.0, "the host picks us up")
	step("held by the host")
	await seconds(0.7)
	while game.local_player().get("held", false) and not failed():
		await hold(&"jump", 0.08)
		await seconds(0.1)
	step("broke free")
