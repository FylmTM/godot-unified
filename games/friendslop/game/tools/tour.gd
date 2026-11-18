extends UnifiedTool
## A tour of the real game, driven by input actions and the camera rig (it steers by turning the camera and holding
## forward, as a player would):
##   godot --path games/friendslop -s res://game/tools/tour.gd -- --no-settings [--shots=<dir>]
## menu -> single player -> hub: walk to a crate, grab it, charge and throw it, walk onto the jump pad and get
## launched onto the high ledge. The whole route, by hand (`uni tool friendslop tour`; the godot suite's walk covers
## the throw).

const Steering := preload("res://game/tools/steering.gd")


func _run() -> void:
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await wait_for_scene("MainMenu", 5.0)
	await seconds(0.5)
	await shot("r01_menu")
	step("menu")

	await click_menu("Single")
	await wait_for_scene("Arena", 5.0)
	var arena: Node3D = current_scene
	await wait_for(func() -> bool: return _me() != null, 8.0, "the player's view")
	await wait_for(func() -> bool: return views(&"marker").size() >= 10, 5.0, "marker views (items, platforms)")
	await seconds(1.0)
	await shot("r02_hub")
	step("hub: %d views, %d markers adopted" % [arena.get_node(^"Views").get_child_count(), views(&"marker").size()])

	var crate := _marker_view("Crate1")
	if crate == null:
		fail("no view for Crate1")
		return
	await Steering.walk_to(self, func() -> Vector3: return crate.global_position + Vector3(-1.1, 0, 0), 8.0, 0.35)
	await Steering.face(self, crate.global_position, -0.35)
	await hold(&"grab", 0.1)
	await wait_for(func() -> bool: return _holding() == EnumHeldKind.ITEM, 1.0, "holding the crate")
	await seconds(0.5)
	await shot("r03_holding")
	step("grabbed a crate next to %s" % Steering.fmt(crate.global_position))
	var before := _marker_positions()
	await hold(&"throw", 0.4)
	await wait_for(func() -> bool: return _holding() == EnumHeldKind.NONE, 1.0, "the throw")
	await seconds(0.5)
	await shot("r04_thrown")
	var after := _marker_positions()
	var moved := 0.0
	for k: int in before:
		moved = maxf(moved, (after.get(k, before[k]) as Vector3).distance_to(before[k]))
	step("threw it %.1f m" % moved)
	expect(moved >= 2.0, "the thrown crate moves at least 2 m (%.1f m)" % moved)

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


## Marker views' positions by entity.
func _marker_positions() -> Dictionary[int, Vector3]:
	var out: Dictionary[int, Vector3] = {}
	for v: Node in views(&"marker"):
		out[_entity(v)] = (v as Node3D).global_position
	return out


## The view of a level marker by its node name (a marker view's key is its marker index).
func _marker_view(marker_name: String) -> Node3D:
	var markers: Array[Node] = current_scene.markers
	for i in markers.size():
		if markers[i].name == marker_name:
			return session.get_view("marker", i) as Node3D
	return null


## The local player's view, or null.
func _me() -> Node3D:
	return session.get_player_view("player", session.local_player) as Node3D


## What the local player holds (NONE while they hold no slot).
func _holding() -> int:
	var me := game.local_player_info() as DataHudPlayer
	return me.holding if me != null else EnumHeldKind.NONE


## A view's entity, from its UnifiedView marker.
static func _entity(v: Node) -> int:
	return (v.get_node(^"UnifiedView") as UnifiedView).entity


## A level marker's position by its node name.
func _marker(marker_name: String) -> Vector3:
	for m: Node in current_scene.markers:
		if m.name == marker_name:
			return (m as Node3D).global_position
	fail("no marker " + marker_name)
	return Vector3.ZERO
