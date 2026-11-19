extends RefCounted
## Steering for friendslop's tool scripts: they move the local player the way a player does, by turning the camera
## rig and holding forward.


## Turns the camera towards the target and holds forward until within `near` (xz) of it.
static func walk_to(tool: UnifiedTool, target: Callable, timeout_s: float, near: float) -> void:
	var arena: Node3D = tool.current_scene
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	Input.action_press(&"move_forward")
	while not tool.failed():
		var at := player_view(tool, tool.session.local_player).global_position
		var t: Vector3 = target.call()
		var d := Vector2(t.x - at.x, t.z - at.z)
		if d.length() < near:
			break
		if Time.get_ticks_msec() > end:
			tool.fail("timed out walking to %s (at %s)" % [fmt(t), fmt(at)])
			break
		arena.camera_rig.yaw = atan2(d.x, d.y)
		await tool.process_frame
	Input.action_release(&"move_forward")
	await tool.seconds(0.3)


## Turns the camera towards `at`, at `pitch`.
static func face(tool: UnifiedTool, at: Vector3, pitch: float) -> void:
	var arena: Node3D = tool.current_scene
	var me := player_view(tool, tool.session.local_player).global_position
	arena.camera_rig.yaw = atan2(at.x - me.x, at.z - me.z)
	arena.camera_rig.pitch = pitch
	await tool.seconds(0.3)


## A player's view (by key), or null while the sim shows none.
static func player_view(tool: UnifiedTool, player: int) -> Node3D:
	return tool.session.get_player_view(EnumView.PLAYER, player) as Node3D


static func fmt(p: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]
