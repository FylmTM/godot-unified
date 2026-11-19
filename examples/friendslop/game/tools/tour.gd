extends "res://game/tools/ui_walk.gd"
## A tour of the real game: the walk's hub (ui_walk.gd: walk to a crate, grab it, throw it; held, it is drawn at the
## hand), then onto the jump pad and up to the high ledge, steering as a player would (turning the camera rig, holding
## forward):
##   godot --path examples/friendslop -s res://game/tools/tour.gd -- --no-settings [--shots=<dir>]
## By hand (`uni tool friendslop tour`).


func _run() -> void:
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await wait_for_scene("MainMenu", 5.0)
	await seconds(0.5)
	await shot("r01_menu")
	step("menu")

	await click_menu("Single")
	await wait_for_scene("Arena", 5.0)
	if failed():
		return
	await _walk_play()
	if failed():
		return

	var jump_pad := _marker("Pad")
	await Steering.walk_to(self, func() -> Vector3: return jump_pad, 10.0, 0.3)
	var peak := 0.0
	var end := Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < end and not failed():
		peak = maxf(peak, _me().global_position.y)
		await process_frame
	await shot("r05_ledge")
	step("jump pad: peak %.1f m" % peak)
	expect(peak >= 4.0, "the jump pad launches the player (peak %.1f m)" % peak)


## What the local player holds is drawn at their hand (script-posed, marker_view.gd), not where its spring lags.
func _holding_crate() -> void:
	await seconds(0.5)
	await shot("r03_holding")
	var held: Node3D = null
	for v: Node in views(EnumView.MARKER):
		if v.get(&"held_by") as int == session.local_player:
			held = v as Node3D
	expect(held != null, "the held item's view knows its holder")
	if held != null:
		var me := _me()
		var facing := me.quaternion * Vector3.BACK
		var offset := held.global_position - me.global_position
		var along := Vector2(offset.x, offset.z).dot(Vector2(facing.x, facing.z))
		expect(
			absf(along - Unified.constants.hold_dist) < 0.02,
			"the held item is drawn at the hand (%.3f m ahead, hold_dist %.2f)" % [along, Unified.constants.hold_dist],
		)


## A level marker's position by its node name.
func _marker(marker_name: String) -> Vector3:
	for m: Node in Unified.level_markers(session.level_scene):
		if m.name == marker_name:
			return (m as Node3D).global_position
	fail("no marker " + marker_name)
	return Vector3.ZERO
