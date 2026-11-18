extends UnifiedUiWalk
## The shared UI walk (UnifiedUiWalk) plus friendslop's own play scene, on the real session (single player), steered
## as a player would (turning the camera rig, holding forward): the hub (the player's view, the marker views) -> walk
## to a crate, grab it, charge and throw it (it flies at least 2 m). The jump pad and the rest of the route: the full
## tour (`uni tool friendslop tour`).

const Steering := preload("res://game/tools/steering.gd")


func _walk_play() -> void:
	await wait_for(func() -> bool: return _me() != null, 8.0, "the player's view")
	await wait_for(func() -> bool: return views(EnumView.MARKER).size() >= 10, 5.0, "marker views (items, platforms)")
	await shot("02_hub")
	step("hub: %d markers adopted" % views(EnumView.MARKER).size())

	var crate := _marker_view("Crate1")
	if crate == null:
		fail("no view for Crate1")
		return
	await Steering.walk_to(self, func() -> Vector3: return crate.global_position + Vector3(-1.1, 0, 0), 8.0, 0.35)
	await Steering.face(self, crate.global_position, -0.35)
	await hold(&"grab", 0.1)
	await wait_for(func() -> bool: return _holding() == EnumHeldKind.ITEM, 1.0, "holding the crate")
	await shot("02b_holding")
	step("grabbed a crate next to %s" % Steering.fmt(crate.global_position))

	var before := _marker_positions()
	await hold(&"throw", 0.4)
	await wait_for(func() -> bool: return _holding() == EnumHeldKind.NONE, 1.0, "the throw")
	await wait_for(func() -> bool: return _moved_most(before) >= 2.0, 2.0, "the thrown crate moves at least 2 m")
	await shot("02c_thrown")
	step("threw it %.1f m" % _moved_most(before))


## Marker views' positions by key (marker index).
func _marker_positions() -> Dictionary[int, Vector3]:
	var out: Dictionary[int, Vector3] = {}
	for v: Node in views(EnumView.MARKER):
		out[_key(v)] = (v as Node3D).global_position
	return out


## The farthest any marker view moved since `before`.
func _moved_most(before: Dictionary[int, Vector3]) -> float:
	var after := _marker_positions()
	var moved := 0.0
	for k: int in before:
		moved = maxf(moved, (after.get(k, before[k]) as Vector3).distance_to(before[k]))
	return moved


## The view of a level marker by its node name (a marker view's key is its marker index).
func _marker_view(marker_name: String) -> Node3D:
	var markers: Array[Node] = current_scene.markers
	for i in markers.size():
		if markers[i].name == marker_name:
			return session.get_view(EnumView.MARKER, i) as Node3D
	return null


## The local player's view, or null.
func _me() -> Node3D:
	return session.get_player_view(EnumView.PLAYER, session.local_player) as Node3D


## What the local player holds (NONE while they hold no slot).
func _holding() -> int:
	var me := game.local_player_info() as DataHudPlayer
	return me.holding if me != null else EnumHeldKind.NONE


## A view's key, from its UnifiedView marker.
static func _key(v: Node) -> int:
	return (v.get_node(^"UnifiedView") as UnifiedView).key
